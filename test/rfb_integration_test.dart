library;

/// 端到端 RFB 集成测试：内存中真实 Socket 上的模拟 VNC 服务器。
///
/// 覆盖：版本协商、None 与 VNC 密码认证、ServerInit、SetPixelFormat、
/// SetEncodings、FBU（Raw 矩形）、输入事件、剪贴板。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frpc_vnc/services/vnc/rfb/connection.dart';
import 'package:frpc_vnc/services/vnc/rfb/des.dart';

class FakeVncServer {
  FakeVncServer(this._password);

  final String? _password;
  late ServerSocket _server;
  late int port;

  final List<Map<String, Object?>> events = [];

  static const w = 4, h = 4;
  Uint8List get framePixels {
    final px = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final o = (y * w + x) * 4;
        final red = x < 2;
        final green = y < 2;
        px[o] = red ? 255 : 0;
        px[o + 1] = green ? 255 : 0;
        px[o + 2] = (red && green) ? 0 : 255;
        px[o + 3] = 255;
      }
    }
    return px;
  }

  Future<void> start() async {
    _server = await ServerSocket.bind('127.0.0.1', 0);
    port = _server.port;
    runZonedGuarded(() {
      _server.listen((sock) {
        runZonedGuarded(() async {
          try {
            await _handle(sock);
          } catch (_) {}
        }, (_, __) {});
      });
    }, (e, st) {
      // 连接关闭竞态产生的 RST 错误：静默。
    });
  }

  Future<void> stop() => _server.close();

  Future<void> _handle(Socket sock) async {
    final pending = <int>[];

    sock.listen(
      (chunk) => pending.addAll(chunk),
      onError: (_) {},
      onDone: () {},
      cancelOnError: true,
    );

    Future<Uint8List> read(int n) async {
      while (pending.length < n) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      final out = Uint8List.fromList(pending.sublist(0, n));
      pending.removeRange(0, n);
      return out;
    }

    void send(List<int> bytes) => sock.add(bytes);

    // 1. 版本：服务器先发，客户端不回显。
    send(utf8.encode('RFB 003.008\n'));

    // 2. 安全类型。
    final hasAuth = _password != null;
    send([1, hasAuth ? 2 : 1]);
    await read(1); // chosen 安全类型（None/VNC 均按预期选择）

    if (hasAuth) {
      final challenge = Uint8List.fromList(List.generate(16, (i) => i * 17 & 0xFF));
      send(challenge);
      final response = await read(16);
      final expected = desEcbEncrypt(vncAuthKey(_password), challenge);
      var ok = response.length == expected.length;
      for (var i = 0; ok && i < expected.length; i++) {
        if (response[i] != expected[i]) ok = false;
      }
      if (!ok) {
        send([0, 0, 0, 1, 0, 0, 0, 4, ...utf8.encode('bad')]);
        await sock.close();
        return;
      }
      send([0, 0, 0, 0]); // 成功
    } else {
      send([0, 0, 0, 0]);
    }

    // 3. ClientInit。
    final shared = (await read(1))[0];
    events.add({'type': 'shared', 'shared': shared});

    // 4. ServerInit。
    final init = BytesBuilder()
      ..addByte(0)..addByte(w)
      ..addByte(0)..addByte(h)
      ..add(_pixelFormat())
      ..addByte(0)..addByte(0)..addByte(0)..addByte(6)
      ..add(utf8.encode('TestFB'));
    send(init.takeBytes());

    // 5. SetPixelFormat（20 字节）。
    await read(20);

    // 6. SetEncodings ×2。
    for (var i = 0; i < 2; i++) {
      final head = await read(4);
      final count = (head[2] << 8) | head[3];
      await read(count * 4);
    }

    // 7. 初始 FBU 请求。
    await read(10);

    // 8. Raw FBU。
    _sendRawFbu(send);

    // 9. 消息循环（限时）。
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(deadline)) {
      if (pending.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        continue;
      }
      final msgType = pending.removeAt(0);
      switch (msgType) {
        case 4: // KeyEvent：down(1) pad(2) keysym(4)
          final body = await read(7);
          events.add({
            'type': 'key',
            'down': body[0] == 1,
            'keysym': (body[3] << 24) | (body[4] << 16) | (body[5] << 8) | body[6],
          });
        case 5: // PointerEvent：mask(1) x(2) y(2)
          final body = await read(5);
          events.add({
            'type': 'pointer',
            'mask': body[0],
            'x': (body[1] << 8) | body[2],
            'y': (body[3] << 8) | body[4],
          });
        case 6: // ClientCutText：pad(3) len(4) text
          final head = await read(7);
          final len = (head[3] << 24) | (head[4] << 16) | (head[5] << 8) | head[6];
          final text = await read(len);
          events.add({'type': 'cut', 'text': utf8.decode(text)});
        case 3: // FBU 请求 → 空更新
          await read(9);
          send([0, 0]);
        default:
          await sock.close();
          return;
      }
    }
    await sock.close();
  }

  Uint8List _pixelFormat() {
    final b = BytesBuilder()
      ..addByte(32)
      ..addByte(24)
      ..addByte(0)
      ..addByte(1)
      ..addByte(0)..addByte(255)
      ..addByte(0)..addByte(255)
      ..addByte(0)..addByte(255)
      ..addByte(16)
      ..addByte(8)
      ..addByte(0)
      ..addByte(0)..addByte(0)..addByte(0); // padding ×3
    return b.takeBytes();
  }

  void _sendRawFbu(void Function(List<int>) send) {
    final b = BytesBuilder()
      ..addByte(0)
      ..addByte(1)
      ..addByte(0)..addByte(0)
      ..addByte(0)..addByte(0)
      ..addByte(0)..addByte(w)
      ..addByte(0)..addByte(h)
      ..addByte(0)..addByte(0)..addByte(0)..addByte(0) // enc = Raw
      ..add(framePixels);
    send(b.takeBytes());
  }
}

class _Collector {
  final events = <Map<String, Object?>>[];
  final completer = Completer<Map<String, Object?>>();

  void add(Map<String, Object?> ev) {
    events.add(ev);
    if (!completer.isCompleted &&
        (ev['ev'] == 'fb' || ev['ev'] == 'error' || ev['ev'] == 'closed')) {
      completer.complete(ev);
    }
  }
}

void main() {
  group('RFB 端到端（None 认证）', () {
    late FakeVncServer server;

    setUp(() async {
      server = FakeVncServer(null);
      await server.start();
    });

    tearDown(() async {
      await server.stop();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });

    test('握手 → ServerInit → Raw FBU 像素正确', () async {
      final collector = _Collector();
      final cmds = StreamController<Map<String, Object?>>();
      final conn = VncConnection(
        VncOptions(host: '127.0.0.1', port: server.port),
        collector.add,
      );
      final runFuture = conn.run(cmds.stream);
      final done = await collector.completer.future.timeout(const Duration(seconds: 5));

      expect(done['ev'], 'fb');
      final ready = collector.events.firstWhere((e) => e['ev'] == 'ready');
      expect(ready['width'], FakeVncServer.w);
      expect(ready['height'], FakeVncServer.h);
      expect(ready['name'], 'TestFB');

      final frame = (done['frame'] as TransferableTypedData).materialize().asUint8List();
      expect(frame.length, 4 * 4 * 4);
      // (0,0): 红+绿 → (255,255,0)。
      expect(frame.sublist(0, 4), [255, 255, 0, 255]);
      // (3,0): x=3 非红、y=0 绿 → (0,255,255)。
      expect(frame.sublist(3 * 4, 3 * 4 + 4), [0, 255, 255, 255]);
      // (0,3): x=0 红、y=3 非绿 → (255,0,255)。
      expect(frame.sublist(3 * 4 * 4, 3 * 4 * 4 + 4), [255, 0, 255, 255]);

      cmds.close();
      conn.close();
      await runFuture.catchError((_) {});
    });

    test('输入事件与剪贴板到达服务器', () async {
      final collector = _Collector();
      final cmds = StreamController<Map<String, Object?>>();
      final conn = VncConnection(
        VncOptions(host: '127.0.0.1', port: server.port),
        collector.add,
      );
      final runFuture = conn.run(cmds.stream);
      await collector.completer.future.timeout(const Duration(seconds: 5));

      cmds.add({'cmd': 'pointer', 'x': 2, 'y': 3, 'mask': 1});
      cmds.add({'cmd': 'key', 'keysym': 0x41, 'down': true});
      cmds.add({'cmd': 'cutText', 'text': 'hello'});

      bool got(String t) => server.events.any((e) => e['type'] == t);
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (DateTime.now().isBefore(deadline) &&
          !(got('pointer') && got('key') && got('cut'))) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(server.events.any((e) => e['type'] == 'pointer'), isTrue);
      expect(server.events.any((e) => e['type'] == 'key'), isTrue);
      expect(server.events.any((e) => e['type'] == 'cut'), isTrue);
      expect(
        server.events.firstWhere((e) => e['type'] == 'cut')['text'],
        'hello',
      );

      cmds.close();
      conn.close();
      await runFuture.catchError((_) {});
    });
  });

  group('RFB 端到端（VNC 密码认证）', () {
    late FakeVncServer server;

    setUp(() async {
      server = FakeVncServer('secret');
      await server.start();
    });

    tearDown(() async {
      await server.stop();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });

    test('正确密码通过认证', () async {
      final collector = _Collector();
      final cmds = StreamController<Map<String, Object?>>();
      final conn = VncConnection(
        VncOptions(host: '127.0.0.1', port: server.port, password: 'secret'),
        collector.add,
      );
      final runFuture = conn.run(cmds.stream);
      final done = await collector.completer.future.timeout(const Duration(seconds: 5));
      expect(done['ev'], 'fb');
      cmds.close();
      conn.close();
      await runFuture.catchError((_) {});
    });

    test('错误密码得到认证失败错误', () async {
      final collector = _Collector();
      final cmds = StreamController<Map<String, Object?>>();
      final conn = VncConnection(
        VncOptions(host: '127.0.0.1', port: server.port, password: 'wrong'),
        collector.add,
      );
      final runFuture = conn.run(cmds.stream);
      final ev = await collector.completer.future.timeout(const Duration(seconds: 5));
      expect(ev['ev'], anyOf('error', 'closed'));
      cmds.close();
      conn.close();
      await runFuture.catchError((_) {});
    });

    test('未提供密码时明确报错', () async {
      final collector = _Collector();
      final cmds = StreamController<Map<String, Object?>>();
      final conn = VncConnection(
        VncOptions(host: '127.0.0.1', port: server.port),
        collector.add,
      );
      final runFuture = conn.run(cmds.stream);
      final ev = await collector.completer.future.timeout(const Duration(seconds: 5));
      expect(ev['ev'], 'error');
      expect(ev['message'] as String, contains('密码'));
      cmds.close();
      conn.close();
      await runFuture.catchError((_) {});
    });
  });
}
