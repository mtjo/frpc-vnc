import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:frpc_vnc/services/vnc/rfb/connection.dart';

Future<void> main() async {
  final server = ServerSocket.bind('127.0.0.1', 0);
  final srv = await server;
  print('server port: ${srv.port}');

  srv.listen((sock) {
    print('[server] client connected');
    final pending = <int>[];
    sock.listen((chunk) {
      print('[server] got ${chunk.length} bytes');
      pending.addAll(chunk);
    });
    Future<Uint8List> read(int n) async {
      while (pending.length < n) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      final out = pending.sublist(0, n);
      pending.removeRange(0, n);
      return Uint8List.fromList(out);
    }

    () async {
      try {
        sock.add('RFB 003.008\n'.codeUnits); // 服务器先发版本
        final cv = await read(12); // 客户端按规范回显版本
        print('[server] client version: ${String.fromCharCodes(cv).trim()}');
        sock.add([1, 1]); // 1 security type: None
        final chosen = await read(1);
        print('[server] chosen: ${chosen[0]}');
        sock.add([0, 0, 0, 0]);
        final ci = await read(1);
        print('[server] clientInit shared=${ci[0]}');
        final init = [
          0, 4, 0, 4, // 4x4
          32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0,
          0, 0, 0, 4, ...'Test'.codeUnits,
        ];
        sock.add(init);
        print('[server] serverInit sent');
        final spf = await read(20);
        print('[server] setPixelFormat ${spf.length}');
        final seh = await read(4);
        final count = (seh[2] << 8) | seh[3];
        await read(count * 4);
        print('[server] setEncodings count=$count');
        await read(10);
        print('[server] fbUpdateRequest received; sending FBU');
        final fbu = [0, 1, 0, 0, 0, 0, 0, 4, 0, 4, 0, 0, 0, 0];
        sock.add(fbu);
        sock.add(List.filled(4 * 4 * 4, 128));
        print('[server] FBU sent');
        await Future<void>.delayed(const Duration(seconds: 2));
      } catch (e, st) {
        print('[server] error: $e\n$st');
      }
    }();
  });

  final events = <Map<String, Object?>>[];
  final cmds = StreamController<Map<String, Object?>>();
  final conn = VncConnection(
    VncOptions(host: '127.0.0.1', port: srv.port),
    (ev) {
      print('[client] event: ${ev['ev']} ${ev.containsKey('message') ? ev['message'] : ''}');
      if (ev['stack'] != null) print(ev['stack']);
      events.add(ev);
    },
  );
  final run = conn.run(cmds.stream);
  await Future<void>.delayed(const Duration(seconds: 3));
  conn.close();
  await run.catchError((Object e) => print('run error: $e'));
  srv.close();
  exit(0);
}
