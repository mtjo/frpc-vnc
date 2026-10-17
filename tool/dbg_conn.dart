import 'dart:async';
import 'dart:io';
import 'package:frpc_vnc/services/vnc/rfb/connection.dart';

Future<void> main() async {
  print('启动');
  final cmds = StreamController<Map<String, Object?>>();
  final conn = VncConnection(
    VncOptions(host: '10.13.6.118', port: 5901, connectTimeout: const Duration(seconds: 5)),
    (ev) => print('事件: $ev'),
  );
  final run = conn.run(cmds.stream);
  await Future<void>.delayed(const Duration(seconds: 8));
  print('结束前 run 状态');
  conn.close();
  try {
    await run.timeout(const Duration(seconds: 3));
  } catch (e) {
    print('run 异常: $e');
  }
  exit(0);
}
