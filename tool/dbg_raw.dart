import 'dart:io';
import 'dart:typed_data';

Future<void> main() async {
  final sock = await Socket.connect('10.13.6.118', 5901, timeout: const Duration(seconds: 5));
  print('已连接');
  final buf = BytesBuilder();
  final sub = sock.listen((chunk) {
    buf.add(chunk);
    print('收到 ${chunk.length} 字节: ${chunk.take(24).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
    final s = String.fromCharCodes(chunk.where((c) => c >= 32 && c < 127));
    print('  文本: $s');
  }, onDone: () => print('连接关闭'), onError: (Object e) => print('错误: $e'));
  await Future<void>.delayed(const Duration(seconds: 5));
  // 回应版本并继续
  sock.add('RFB 003.008\n'.codeUnits);
  await Future<void>.delayed(const Duration(seconds: 4));
  sub.cancel();
  sock.destroy();
  exit(0);
}
