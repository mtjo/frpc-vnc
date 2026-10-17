library;

/// RFB 连接核心：握手、认证、FBU 消息循环、输入、剪贴板、光标、
/// TightVNC 文件传输扩展。
///
/// 本类设计为运行在独立 isolate 中（由 [VncSession] 启动），
/// 通过 SendPort 与主 isolate 交换事件与命令。

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';
import 'dart:typed_data';

import 'decoders.dart';
import 'ard_auth.dart';
import 'des.dart';
import 'protocol.dart';
import 'tight_decoder.dart';

/// 连接选项。
class VncOptions {
  VncOptions({
    required this.host,
    required this.port,
    this.username,
    this.password,
    this.tlsVerify = false,
    this.shared = true,
    this.compressLevel = 6,
    this.jpegQuality = 80,
    this.connectTimeout = const Duration(seconds: 10),
  });

  final String host;
  final int port;

  /// macOS ARD 认证（安全类型 30）所需的登录用户名。
  final String? username;
  final String? password;
  final bool tlsVerify;
  final bool shared;
  final int compressLevel;
  final int jpegQuality;
  final Duration connectTimeout;
}

/// 事件回调（isolate 内部使用，直接函数引用）。
typedef VncEventSink = void Function(Map<String, Object?> event);

/// 连接入口：完成握手后进入消息循环，直到关闭或出错。
/// [commands] 为命令流（主 isolate 转发）。
class VncConnection {
  VncConnection(this._options, this._sendEvent);

  final VncOptions _options;
  final VncEventSink _sendEvent;

  Socket? _socket;
  late AsyncByteReader _reader;
  final _tight = TightDecoder();
  final _fb = Framebuffer(0, 0);

  String? _serverName;
  int get width => _fb.width;
  int get height => _fb.height;

  bool _closed = false;
  final bool _fileTransferCapable = true;

  // ---- 生命周期 -----------------------------------------------------------

  Future<void> run(Stream<Map<String, Object?>> commands) async {
    try {
      _socket = await _connectWithTls();
      _reader = AsyncByteReader(_socket!);
      await _handshake();
      await _initialise();
      _sendEvent({
        'ev': 'ready',
        'width': width,
        'height': height,
        'name': _serverName,
        'fileTransfer': _fileTransferCapable,
      });

      // 命令处理与消息循环并行。
      final cmdSub = commands.listen(_handleCommand, cancelOnError: false);
      try {
        await _messageLoop();
      } finally {
        await cmdSub.cancel();
      }
    } on VncConnectionClosed catch (e) {
      if (!_closed) _sendEvent({'ev': 'closed', 'reason': e.message});
    } catch (e, st) {
      if (!_closed) {
        _sendEvent({'ev': 'error', 'message': e.toString(), 'stack': st.toString()});
      }
    } finally {
      _dispose();
    }
  }

  Future<void> close() async {
    _closed = true;
    await _dispose();
  }

  Future<void> _dispose() async {
    _tight.dispose();
    await _reader.cancel();
    try {
      _socket?.destroy();
    } catch (_) {}
    _socket = null;
  }

  /// 建立连接，安全类型 18（TLS）时升级并重新握手。
  Future<Socket> _connectWithTls() async {
    var socket = await Socket.connect(
      _options.host,
      _options.port,
      timeout: _options.connectTimeout,
    );
    socket.setOption(SocketOption.tcpNoDelay, true);
    // 预读协议版本：若随后选择 TLS 则需要重新读取，因此先窥探。
    return socket;
  }

  // ---- 握手与认证 ---------------------------------------------------------

  Future<void> _handshake() async {
    var restarts = 0;
    while (true) {
      final proto = await _reader.read(12);
      final version = _parseVersion(proto);
      if (version == null) {
        throw Exception('不是 RFB 服务器（版本串: ${String.fromCharCodes(proto)}）');
      }

      // 按规范回应客户端版本：选双方都支持的最高版本
      //（客户端支持到 3.8，不超过服务器的 minor 版本）。
      // 3.889 等 RealVNC 扩展版本按 3.8 流程处理。
      final minor = version % 1000;
      final replyMinor = minor >= 8 ? '008' : (minor == 7 ? '007' : '003');
      _socket!.add(('RFB 003.' + replyMinor + '\n').codeUnits);
      await _socket!.flush();

      // 3.3 服务器单方面指定安全类型；其余按 3.7+ 流程处理。
      final List<int> offered;
      if (version <= 3003) {
        final r = ByteReader(await _reader.read(4));
        final t = r.u32();
        if (t == 0) {
          // 失败：跟随原因字符串。
          final reasonLen = ByteReader(await _reader.read(4)).u32();
          final reason = await _reader.read(reasonLen);
          throw Exception('服务器拒绝连接：${String.fromCharCodes(reason)}');
        }
        offered = [t];
      } else {
        final n = (await _reader.read(1))[0];
        offered = [...await _reader.read(n)];
      }

      // 安全类型优先级：TLS > ARD(macOS 屏幕共享) > VNC 认证 > None。
      // Tight(16) 等复杂类型跳过，依赖服务器同时提供基础类型
      // （TightVNC/x11vnc 均如此）。
      int chosen = 0;
      if (offered.contains(secTls)) {
        chosen = secTls;
      } else if (offered.contains(secArdAuthentication)) {
        chosen = secArdAuthentication;
      } else if (offered.contains(secVncAuthentication)) {
        chosen = secVncAuthentication;
      } else if (offered.contains(secNone)) {
        chosen = secNone;
      } else {
        throw Exception(
          '服务器不支持的安全类型: $offered'
          '（若目标是 macOS：系统设置→通用→共享→屏幕共享→(i)→'
          '开启"VNC 观看器可以用密码控制屏幕"）',
        );
      }

      if (chosen == secTls) {
        if (++restarts > 2) throw Exception('TLS 重握手次数过多');
        // 升级为 TLS 后重新走版本/安全协商。
        final raw = _socket!;
        final secure = await SecureSocket.secure(
          raw,
          onBadCertificate: _options.tlsVerify ? null : (_) => true,
        );
        raw.destroy();
        _socket = secure;
        _reader = AsyncByteReader(secure);
        continue;
      }

      // 3.7/3.8 需要回应选择；3.3 服务器单方面决定。
      if (version != 3003) {
        _socket!.add([chosen]);
          }

      if (chosen == secVncAuthentication) {
        final challenge = await _reader.read(16);
        if (_options.password == null || _options.password!.isEmpty) {
          throw Exception('服务器要求 VNC 密码认证，但未提供密码');
        }
        final response = _desEncryptPassword(_options.password!, challenge);
        _socket!.add(response);
      } else if (chosen == secArdAuthentication) {
        // Apple Remote Desktop / macOS 屏幕共享（TigerVNC CSecurityDH）：
        // 读 DH 参数 → 发送 AES-128-ECB 加密的用户名+密码 + 客户端公钥。
        final header = await _reader.read(4);
        final total = AppleDhParams.expectedLength(header);
        final rest = await _reader.read(total - 4);
        final params = AppleDhParams.parse(Uint8List.fromList([...header, ...rest]));
        final response = appleDhAuth(
          params,
          _options.username ?? '',
          _options.password ?? '',
        );
        _socket!.add(response.encryptedCredentials);
        _socket!.add(response.clientPublic);
        await _socket!.flush();
      }

      // 安全结果（3.8 起必有；3.3 在安全类型中已表达；3.7 无此字段）。
      if (version >= 3008) {
        final result = ByteReader(await _reader.read(4)).u32();
        if (result != 0) {
          final reasonLen = ByteReader(await _reader.read(4)).u32();
          final reason = await _reader.read(reasonLen);
          throw Exception('认证失败：${String.fromCharCodes(reason)}');
        }
      }
      return;
    }
  }

  /// 解析版本串为整数（如 3008 表示 RFB 3.8）。
  int? _parseVersion(Uint8List proto) {
    final s = String.fromCharCodes(proto);
    final m = RegExp(r'^RFB 003\.(\d{3})\n$').firstMatch(s);
    if (m == null) return null;
    return int.parse('3${m.group(1)}');
  }

  Future<void> _initialise() async {
    final sink = BytesSink();
    sink.u8(_options.shared ? 1 : 0);
    _socket!.add(sink.take());

    final init = ByteReader(await _reader.read(24));
    final w = init.u16();
    final h = init.u16();
    PixelFormat.read(init); // 服务端像素格式（仅参考，随后我们覆盖）
    final nameLen = init.u32();
    final nameBytes = await _reader.read(nameLen);
    _serverName = _decodeText(nameBytes);


    // 协商客户端像素格式：32bpp RGBA。
    final s1 = BytesSink()
      ..u8(msgSetPixelFormat)
      ..u8(0)
      ..u8(0)
      ..u8(0); // padding ×3
    PixelFormat().writeTo(s1);
    _socket!.add(s1.take());

    // 请求编码。
    final encs = <int>[
      encTight,
      encHextile,
      encZlib,
      encCopyRect,
      encRaw,
      encPseudoCursor,
      encPseudoDesktopSize,
      -224, // LastRect
      -312, // CompressLevel0 + compressLevel
      -412, // QualityLevel0 + jpegQuality (伪编码基值为 -412)
    ];
    final s2 = BytesSink()..u8(msgSetEncodings)..u8(0)..u16(encs.length);
    for (final e in encs) {
      s2.u32(e);
    }
    _socket!.add(s2.take());
    // CompressLevel / QualityLevel 实际值通过专用伪编码发送。
    final s3 = BytesSink()..u8(msgSetEncodings)..u8(0)..u16(2);
    s3.u32(-312 - _options.compressLevel.clamp(0, 9));
    s3.u32(-412 - _options.jpegQuality.clamp(0, 9));
    _socket!.add(s3.take());

    _fb.resize(w, h);
  }

  // ---- 消息循环 -----------------------------------------------------------

  Future<void> _messageLoop() async {
    // 初始全量请求。
    _requestUpdate(incremental: false);

    while (!_closed) {
      final type = (await _reader.read(1))[0];
      switch (type) {
        case msgFramebufferUpdate:
          await _readFramebufferUpdate();
        case msgSetColourMapEntries:
          final head = ByteReader(await _reader.read(5));
          head.u8();
          final n = head.u16();
          await _reader.read(n * 6);
        case msgBell:
          _sendEvent({'ev': 'bell'});
        case msgServerCutText:
          final head = ByteReader(await _reader.read(7));
          head.u8();
          head.u8();
          head.u8();
          final len = head.u32();
          if (len > 16 * 1024 * 1024) throw Exception('剪贴板数据过大');
          final text = await _reader.read(len);
          _sendEvent({'ev': 'clipboard', 'text': _decodeText(text)});
        default:
          // TightVNC 文件传输回复（130-136）。
          if (type >= 130 && type <= 136) {
            await _readFileTransferReply(type);
          } else {
            throw UnsupportedError('未知服务器消息类型 $type');
          }
      }
    }
  }

  void _requestUpdate({required bool incremental}) {
    if (_closed) return;
    final s = BytesSink()
      ..u8(msgFramebufferUpdateRequest)
      ..u8(incremental ? 1 : 0)
      ..u16(0)
      ..u16(0)
      ..u16(width)
      ..u16(height);
    _socket!.add(s.take());
  }

  Future<void> _readFramebufferUpdate() async {
    final nRects = (await _reader.read(1))[0];
    final dirty = <Rect>[];
    var fbResized = false;

    for (var i = 0; i < nRects; i++) {
      final head = ByteReader(await _reader.read(12));
      final x = head.u16();
      final y = head.u16();
      final w = head.u16();
      final h = head.u16();
      final enc = head.u32().toSigned(32);
      final rect = Rect(x, y, w, h);

      switch (enc) {
        case encRaw:
          await decodeRaw(rect, _fb, _reader);
          dirty.add(rect);
        case encCopyRect:
          await decodeCopyRect(rect, _fb, _reader);
          dirty.add(rect);
        case encHextile:
          await decodeHextile(rect, _fb, _reader);
          dirty.add(rect);
        case encZlib:
          await decodeZlib(rect, _fb, _reader);
          dirty.add(rect);
        case encTight:
          await _tight.decode(rect, _fb, _reader);
          dirty.add(rect);
        case encPseudoCursor:
          await _readCursorShape(rect);
        case encPseudoDesktopSize:
          _fb.resize(w, h);
          fbResized = true;
        case -224: // LastRect
          i = nRects; // 结束循环
        default:
          throw UnsupportedError('未协商的编码 $enc（矩形 $x,$y ${w}x$h）');
      }
    }

    if (_closed) return;

    final payload = TransferableTypedData.fromList([Uint8List.fromList(_fb.pixels)]);
    _sendEvent({
      'ev': 'fb',
      'frame': payload,
      'width': _fb.width,
      'height': _fb.height,
      'dirty': [
        for (final r in dirty)
          {'x': r.x, 'y': r.y, 'w': r.w, 'h': r.h}
      ],
      if (fbResized) 'resized': true,
    });
    _requestUpdate(incremental: true);
  }

  Future<void> _readCursorShape(Rect rect) async {
    final w = rect.w;
    final h = rect.h;
    if (w == 0 || h == 0) {
      _sendEvent({'ev': 'cursor', 'w': 0, 'h': 0});
      return;
    }
    final pix = await _reader.read(w * h * 4);
    final maskRow = (w + 7) >> 3;
    final mask = await _reader.read(maskRow * h);
    _sendEvent({
      'ev': 'cursor',
      'w': w,
      'h': h,
      'hotX': rect.x,
      'hotY': rect.y,
      'pixels': TransferableTypedData.fromList([Uint8List.fromList(pix)]),
      'mask': TransferableTypedData.fromList([Uint8List.fromList(mask)]),
    });
  }

  // ---- 命令处理 -----------------------------------------------------------

  void _handleCommand(Map<String, Object?> cmd) {
    if (_closed) return;
    try {
      _dispatchCommand(cmd);
    } catch (_) {
      // socket 已关闭等情况：静默忽略。
    }
  }

  void _dispatchCommand(Map<String, Object?> cmd) {
    switch (cmd['cmd']) {
      case 'close':
        close();
      case 'pointer':
        final s = BytesSink()
          ..u8(msgPointerEvent)
          ..u8((cmd['mask'] as int?) ?? 0)
          ..u16((cmd['x'] as num).toInt())
          ..u16((cmd['y'] as num).toInt());
        _socket!.add(s.take());
          case 'key':
        final s = BytesSink()
          ..u8(msgKeyEvent)
          ..u8((cmd['down'] as bool?) == false ? 0 : 1)
          ..u16(0)
          ..u32((cmd['keysym'] as num).toInt());
        _socket!.add(s.take());
          case 'cutText':
        final text = (cmd['text'] as String?) ?? '';
        final bytes = _encodeText(text);
        final s = BytesSink()
          ..u8(msgClientCutText)
          ..u8(0)
          ..u8(0)
          ..u8(0)
          ..u32(bytes.length)
          ..raw(bytes);
        _socket!.add(s.take());
          case 'refresh':
        _requestUpdate(incremental: false);
      case 'fileList':
        _ftList((cmd['path'] as String?) ?? '/');
      case 'fileDownload':
        _ftDownload(cmd['remotePath'] as String, cmd['localPath'] as String,
            cmd['id'] as int);
      case 'fileUpload':
        _ftUpload(cmd['localPath'] as String, cmd['remotePath'] as String,
            cmd['id'] as int);
      case 'fileCancelDownload':
        _ftDownloadCancel((cmd['reason'] as String?) ?? 'user cancel');
      case 'fileCancelUpload':
        _ftUploadFailed((cmd['reason'] as String?) ?? 'user cancel');
      case 'fileMkdir':
        _ftCreateDir((cmd['path'] as String?) ?? '/');
    }
  }

  // ---- TightVNC 文件传输 ---------------------------------------------------

  void _sendFt(List<int> bytes) {
    _socket!.add(bytes);
  }

  void _ftList(String path) {
    final name = _encodeText(path);
    final s = BytesSink()
      ..u8(130) // FileListRequest
      ..u8(0) // flags: 全部条目
      ..u16(name.length)
      ..raw(name);
    _sendFt(s.take());
  }

  void _ftDownload(String remotePath, String localPath, int id) {
    _ftDownloadState = _DownloadState(remotePath, localPath, id);
    final name = _encodeText(remotePath);
    final s = BytesSink()
      ..u8(131) // FileDownloadRequest
      ..u8(0) // compressedLevel: 0（x11vnc 不支持压缩传输）
      ..u16(name.length)
      ..u32(0) // position
      ..raw(name);
    _sendFt(s.take());
  }

  void _ftDownloadCancel(String reason) {
    final st = _ftDownloadState;
    st?.file.closeSync();
    _ftDownloadState = null;
    final r = _encodeText(reason);
    final s = BytesSink()
      ..u8(134) // FileDownloadCancel
      ..u8(0)
      ..u16(r.length)
      ..raw(r);
    _sendFt(s.take());
    if (st != null) {
      _sendEvent({'ev': 'fileError', 'id': st.id, 'op': 'download', 'error': reason});
    }
  }

  void _ftUpload(String localPath, String remotePath, int id) {
    final f = File(localPath);
    if (!f.existsSync()) {
      _sendEvent({'ev': 'fileError', 'id': id, 'op': 'upload', 'error': '本地文件不存在'});
      return;
    }
    _ftUploadState = _UploadState(remotePath, f.openSync(), id, f.lengthSync());
    final name = _encodeText(remotePath);
    final s = BytesSink()
      ..u8(132) // FileUploadRequest
      ..u8(0)
      ..u16(name.length)
      ..u32(0)
      ..raw(name);
    _sendFt(s.take());
    // x11vnc/TightVNC 在上传请求成功后不回复，直接开始发送数据块；
    // 失败时会回复 FileUploadCancel(132)。
    _ftUploadChunk();
  }

  /// 发送上传数据块。
  void _ftUploadChunk() {
    final st = _ftUploadState;
    if (st == null || st.done) return;
    const blockSize = 8192;
    final data = st.file.readSync(blockSize);
    final s = BytesSink()
      ..u8(133) // FileUploadData
      ..u8(0)
      ..u16(data.length)
      ..u16(data.length)
      ..raw(data);
    _sendFt(s.take());
    st.sent += data.length;
    _sendEvent({
      'ev': 'fileProgress',
      'id': st.id,
      'op': 'upload',
      'sent': st.sent,
      'total': st.total,
    });
    if (data.length < blockSize) {
      // 结束标记：0/0 + mTime。
      final end = BytesSink()
        ..u8(133)
        ..u8(0)
        ..u16(0)
        ..u16(0)
        ..u32((DateTime.now().millisecondsSinceEpoch ~/ 1000));
      _sendFt(end.take());
      st.done = true;
      _sendEvent({'ev': 'fileDone', 'id': st.id, 'op': 'upload'});
      st.file.closeSync();
      _ftUploadState = null;
    }
  }

  void _ftUploadFailed(String reason) {
    final st = _ftUploadState;
    st?.file.closeSync();
    _ftUploadState = null;
    final r = _encodeText(reason);
    final s = BytesSink()
      ..u8(135) // FileUploadFailed
      ..u8(0)
      ..u16(r.length)
      ..raw(r);
    _sendFt(s.take());
    if (st != null) {
      _sendEvent({'ev': 'fileError', 'id': st.id, 'op': 'upload', 'error': reason});
    }
  }

  void _ftCreateDir(String path) {
    final name = _encodeText(path);
    final s = BytesSink()
      ..u8(136) // FileCreateDirRequest
      ..u8(0)
      ..u16(name.length)
      ..raw(name);
    _sendFt(s.take());
  }

  _DownloadState? _ftDownloadState;
  _UploadState? _ftUploadState;

  Future<void> _readFileTransferReply(int type) async {
    switch (type) {
      case 130: // FileListData
        final head = ByteReader(await _reader.read(7));
        final flags = head.u8();
        final numFiles = head.u16();
        head.u16(); // dataSize（未压缩名总长）
        final compressedSize = head.u16();
        final sizes = ByteReader(await _reader.read(numFiles * 8));
        final namesRaw = await _reader.read(compressedSize);
        final entries = <Map<String, Object?>>[];
        // 名称为 NUL 分隔。
        final names = String.fromCharCodes(namesRaw).split('\x00');
        for (var i = 0; i < numFiles; i++) {
          final size = sizes.u32().toSigned(32);
          final mtime = sizes.u32();
          final name = i < names.length ? names[i] : '';
          entries.add({
            'name': name,
            'size': size,
            'isDir': size == -1,
            'mtime': mtime,
          });
        }
        if (flags & 0x80 != 0) {
          // 错误标志（服务器无法列目录）。
          _sendEvent({'ev': 'fileError', 'op': 'list', 'error': '服务器无法列出目录'});
        } else {
          _sendEvent({'ev': 'fileList', 'entries': entries});
        }
      case 131: // FileDownloadData
        final st = _ftDownloadState;
        if (st == null) {
          // 无法处理的下载数据：读取并丢弃。
          final head = ByteReader(await _reader.read(5));
          final sz = head.u16(); // realSize
          final csz = head.u16(); // compressedSize
          await _reader.read(sz == 0 && csz == 0 ? 4 : csz);
          return;
        }
        final head = ByteReader(await _reader.read(5));
        head.u8(); // compressLevel
        final realSize = head.u16();
        final compressedSize = head.u16();
        if (realSize == 0 && compressedSize == 0) {
          // 结束：modTime。
          await _reader.read(4);
          st.file.closeSync();
          _ftDownloadState = null;
          _sendEvent({'ev': 'fileDone', 'id': st.id, 'op': 'download'});
          return;
        }
        final data = await _reader.read(compressedSize);
        st.file.writeFromSync(data, 0, realSize);
        st.received += realSize;
        _sendEvent({
          'ev': 'fileProgress',
          'id': st.id,
          'op': 'download',
          'sent': st.received,
          'total': -1,
        });
      case 132: // FileUploadCancel
        final head = ByteReader(await _reader.read(3));
        head.u8();
        final reasonLen = head.u16();
        final reason = await _reader.read(reasonLen);
        final st = _ftUploadState;
        st?.file.closeSync();
        _ftUploadState = null;
        _sendEvent({
          'ev': 'fileError',
          'op': 'upload',
          'id': st?.id ?? -1,
          'error': _decodeText(reason),
        });
      case 133: // FileDownloadFailed
        final head = ByteReader(await _reader.read(3));
        head.u8();
        final reasonLen = head.u16();
        final reason = await _reader.read(reasonLen);
        final st = _ftDownloadState;
        st?.file.closeSync();
        _ftDownloadState = null;
        _sendEvent({
          'ev': 'fileError',
          'op': 'download',
          'id': st?.id ?? -1,
          'error': _decodeText(reason),
        });
      default:
        throw UnsupportedError('未处理的文件传输回复 $type');
    }
  }

  // ---- 工具 ---------------------------------------------------------------

  Uint8List _desEncryptPassword(String password, Uint8List challenge) =>
      desEcbEncrypt(vncAuthKey(password), challenge);

  String _decodeText(Uint8List bytes) {
    try {
      return utf8WithFallback(bytes);
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }

  Uint8List _encodeText(String text) => Uint8List.fromList(text.codeUnits);
}

class _DownloadState {
  _DownloadState(this.remotePath, this.localPath, this.id)
      : file = File(localPath).openSync(mode: FileMode.write);

  final String remotePath;
  final String localPath;
  final int id;
  final RandomAccessFile file;
  int received = 0;
}

class _UploadState {
  _UploadState(this.remotePath, this.file, this.id, this.total)
      : sent = 0,
        done = false;

  final String remotePath;
  final RandomAccessFile file;
  final int id;
  final int total;
  int sent = 0;
  bool done = true;
}

/// UTF-8 解码，失败时回退 Latin-1。
String utf8WithFallback(Uint8List bytes) {
  try {
    return utf8.decode(bytes, allowMalformed: false);
  } catch (_) {
    return String.fromCharCodes(bytes);
  }
}
