library;

/// VNC 会话（主 isolate 侧）。
///
/// 管理 worker isolate 的生命周期、命令发送与事件接收；
/// 持有最新一帧 RGBA 数据供 UI 渲染。
///
/// 端口方向约定：
/// - 主 → worker 事件流：worker 启动后首先回传 `{'ev':'port', port}`，
///   主 isolate 之后所有命令都发往该端口。
/// - worker → 主：`cfg.toMain` 端口，承载 fb/clipboard/file 等事件。

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'rfb/connection.dart';

class VncSessionException implements Exception {
  VncSessionException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 连接会话状态。
enum VncState { idle, connecting, connected, closed, error }

class VncSession {
  VncSession._();

  VncState state = VncState.idle;
  int width = 0;
  int height = 0;
  String? desktopName;

  /// 最新一帧（RGBA8888），由 'fb' 事件更新。
  Uint8List? latestFrame;

  final _events = StreamController<Map<String, Object?>>.broadcast();
  Stream<Map<String, Object?>> get events => _events.stream;

  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  ReceivePort? _errors;
  bool _tornDown = false;

  /// worker 确认 socket 已优雅关闭（FIN 已发出）。
  final _workerClosed = Completer<void>();

  /// 建立连接并等待就绪；失败时抛出 [VncSessionException]。
  static Future<VncSession> connect(VncOptions options) async {
    final s = VncSession._();
    s.state = VncState.connecting;

    final fromWorker = ReceivePort();
    final errors = ReceivePort();
    s._fromWorker = fromWorker;
    s._errors = errors;

    final ready = Completer<VncSession>();

    void fail(Object e) {
      if (!ready.isCompleted) {
        ready.completeError(e is VncSessionException ? e : VncSessionException(e.toString()));
      }
      s._teardown();
    }

    late final StreamSubscription<dynamic> sub;
    sub = fromWorker.listen((msg) {
      final m = (msg as Map).cast<String, Object?>();
      switch (m['ev']) {
        case 'port':
          s._toWorker = m['port'] as SendPort;
        case 'ready':
          if (!ready.isCompleted) {
            s.width = m['width'] as int;
            s.height = m['height'] as int;
            s.desktopName = m['name'] as String?;
            s.state = VncState.connected;
            ready.complete(s);
          }
          s._events.add(m);
        case 'fb':
          final payload = m['frame'] as TransferableTypedData;
          s.latestFrame = payload.materialize().asUint8List();
          s._events.add(m);
        case 'error':
          if (!ready.isCompleted) {
            sub.cancel();
            fail(VncSessionException(m['message'] as String));
            return;
          }
          s.state = VncState.error;
          s._events.add(m);
        case 'closed':
          if (!s._workerClosed.isCompleted) s._workerClosed.complete();
          if (!ready.isCompleted) {
            sub.cancel();
            fail(VncSessionException((m['reason'] as String?) ?? '连接已关闭'));
            return;
          }
          s.state = VncState.closed;
          s._events.add(m);
          s._teardown();
        default:
          s._events.add(m);
      }
    }, onError: (Object e) => fail(e));

    errors.listen((msg) => fail(msg is Exception ? msg : Exception(msg)));

    try {
      s._isolate = await Isolate.spawn(
        _workerMain,
        _WorkerConfig(options: options, toMain: fromWorker.sendPort),
        errorsAreFatal: false,
        onError: errors.sendPort,
      );
    } catch (e) {
      fail(e);
      return ready.future;
    }

    return ready.future;
  }

  void _teardown() {
    if (_tornDown) return;
    _tornDown = true;
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _fromWorker?.close();
    _errors?.close();
    if (state == VncState.connecting || state == VncState.connected) {
      state = VncState.closed;
    }
  }

  void _send(Map<String, Object?> cmd) {
    final p = _toWorker;
    if (p == null) throw VncSessionException('连接未就绪');
    p.send(cmd);
  }

  // ---- 命令 ---------------------------------------------------------------

  void sendPointer(int x, int y, int buttonMask) =>
      _send({'cmd': 'pointer', 'x': x, 'y': y, 'mask': buttonMask});

  void sendKey(int keysym, {required bool down}) =>
      _send({'cmd': 'key', 'keysym': keysym, 'down': down});

  void sendCutText(String text) => _send({'cmd': 'cutText', 'text': text});

  void requestFullRefresh() => _send({'cmd': 'refresh'});

  /// 优雅关闭：通知 worker 主动关闭 socket（发 FIN），确认后再回收
  /// isolate。直接杀 isolate 会让 TCP 以 RST 断开，服务端会话状态
  /// 依赖超时回收，反复连接/断开会在目标机上留下悬挂会话。
  Future<void> close() async {
    if (state == VncState.closed) return;
    state = VncState.closed;
    try {
      _send({'cmd': 'close'});
    } catch (_) {}
    try {
      await _workerClosed.future.timeout(const Duration(seconds: 2));
    } catch (_) {}
    _teardown();
  }

  // ---- 文件传输 -----------------------------------------------------------

  void listFiles(String path) => _send({'cmd': 'fileList', 'path': path});

  void downloadFile(String remotePath, String localPath, {int id = 0}) =>
      _send({'cmd': 'fileDownload', 'remotePath': remotePath, 'localPath': localPath, 'id': id});

  void uploadFile(String localPath, String remotePath, {int id = 0}) =>
      _send({'cmd': 'fileUpload', 'localPath': localPath, 'remotePath': remotePath, 'id': id});

  void cancelDownload([String reason = 'user cancel']) =>
      _send({'cmd': 'fileCancelDownload', 'reason': reason});

  void cancelUpload([String reason = 'user cancel']) =>
      _send({'cmd': 'fileCancelUpload', 'reason': reason});

  void createRemoteDir(String path) => _send({'cmd': 'fileMkdir', 'path': path});
}

class _WorkerConfig {
  _WorkerConfig({required this.options, required this.toMain});

  final VncOptions options;
  final SendPort toMain;
}

/// worker isolate 入口。
Future<void> _workerMain(_WorkerConfig cfg) async {
  final cmdRecv = ReceivePort();
  cfg.toMain.send({'ev': 'port', 'port': cmdRecv.sendPort});

  final commandCtrl = StreamController<Map<String, Object?>>();
  cmdRecv.listen((msg) {
    if (msg is Map) {
      commandCtrl.add(msg.cast<String, Object?>());
    }
  }, onDone: commandCtrl.close);

  final conn = VncConnection(cfg.options, cfg.toMain.send);
  await conn.run(commandCtrl.stream);
}
