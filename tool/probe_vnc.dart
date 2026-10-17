import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:frpc_vnc/services/vnc/rfb/connection.dart';

Future<void> main(List<String> args) async {
  final host = args[0];
  print('probe 开始 host=' + host + ':' + args[1]);
  final port = int.parse(args[1]);
  final password = args.length > 3 ? args[3] : null;
  final username = args.length > 2 ? args[2] : null;

  final events = <Map<String, Object?>>[];
  final ready = Completer<Map<String, Object?>>();
  final cmds = StreamController<Map<String, Object?>>();

  final conn = VncConnection(
    VncOptions(host: host, port: port, username: username, password: password),
    (ev) {
      events.add(ev);
      print('[event] ${ev['ev']} ${ev.containsKey('message') ? ev['message'] : ''}');
      if ((ev['ev'] == 'fb' || ev['ev'] == 'error' || ev['ev'] == 'closed') && !ready.isCompleted) {
        ready.complete(ev);
      }
    },
  );
  final run = conn.run(cmds.stream);
  final result = await ready.future.timeout(const Duration(seconds: 12), onTimeout: () {
    return {'ev': 'timeout'};
  });

  print('结果: ' + result['ev'].toString());
  if (result['ev'] == 'fb') {
    final r = events.firstWhere((e) => e['ev'] == 'ready');
    print('=== 连接成功 ===');
    print('桌面: ${r['name']}  分辨率: ${r['width']}x${r['height']}');
    final frame = (result['frame'] as TransferableTypedData).materialize().asUint8List();
    print('首帧: ${frame.length ~/ 4} 像素 RGBA');
    // 统计非零像素占比（验证画面非全黑）。
    var nonBlack = 0;
    for (var i = 0; i < frame.length; i += 4) {
      if (frame[i] != 0 || frame[i + 1] != 0 || frame[i + 2] != 0) nonBlack++;
    }
    print('非黑像素: $nonBlack');
  }
  conn.close();
  await run.catchError((Object e) {});
  exit(0);
}
