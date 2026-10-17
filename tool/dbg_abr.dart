import 'dart:async';
import 'dart:io';
import 'package:frpc_vnc/services/vnc/rfb/decoders.dart';

Future<void> main() async {
  print('连接...');
  final sock = await Socket.connect('10.13.6.118', 5901, timeout: const Duration(seconds: 5));
  print('已连接');
  final reader = AsyncByteReader(sock);
  final v = await reader.read(12).timeout(const Duration(seconds: 4), onTimeout: () {
    print('read(12) 超时！');
    throw StateError('timeout');
  });
  print('版本: ${String.fromCharCodes(v)}');
  sock.destroy();
  exit(0);
}
