import 'dart:async';
import 'dart:io';

import 'package:frpc_vnc/services/vnc/rfb/connection.dart';

/// 反复连接/断开测试：验证优雅关闭不留下悬挂会话。
Future<void> main(List<String> args) async {
  final host = args[0];
  final port = int.parse(args[1]);
  final username = args[2];
  final password = args[3];
  final cycles = args.length > 4 ? int.parse(args[4]) : 6;

  for (var i = 1; i <= cycles; i++) {
    final sw = Stopwatch()..start();
    final ready = Completer<void>();
    final closed = Completer<void>();
    var frames = 0;

    final cmds = StreamController<Map<String, Object?>>();
    final conn = VncConnection(
      VncOptions(host: host, port: port, username: username, password: password),
      (ev) {
        switch (ev['ev']) {
          case 'ready':
            ready.complete();
          case 'fb':
            frames++;
            if (frames >= 2 && !ready.isCompleted) ready.complete();
          case 'closed':
            if (!closed.isCompleted) closed.complete();
          case 'error':
            if (!closed.isCompleted) {
              // ignore: avoid_print
              print('  轮次 $i 错误: ${ev['message']}');
              closed.complete();
            }
        }
      },
    );
    final run = conn.run(cmds.stream);

    try {
      await ready.future.timeout(const Duration(seconds: 15));
      // 收到画面后主动优雅断开。
      await conn.close();
      await closed.future.timeout(const Duration(seconds: 3));
      final elapsed = sw.elapsedMilliseconds;
      // ignore: avoid_print
      print('轮次 $i: OK（就绪+收帧 ${elapsed}ms，收到 $frames 帧，已优雅关闭）');
    } catch (e) {
      // ignore: avoid_print
      print('轮次 $i: 失败 — $e');
      await conn.close();
      // 失败后等待目标机恢复。
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    await run.catchError((Object e) {});
    cmds.close();
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  // ignore: avoid_print
  print('测试完成');
  exit(0);
}
