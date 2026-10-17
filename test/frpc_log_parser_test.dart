import 'package:flutter_test/flutter_test.dart';
import 'package:frpc_vnc/services/frpc/frpc_log_parser.dart';

void main() {
  test('解析登录成功', () {
    final r = parseFrpcLog(
        '2024/01/02 15:04:05 [I] [root.go:139] login to server success, get run id [abc]');
    expect(r.isLoginSuccess, isTrue);
    expect(r.level, 'I');
  });

  test('解析代理启动成功', () {
    final r = parseFrpcLog(
        '2024/01/02 15:04:05 [I] [proxy_manager.go:173] [abcdef123456] [tcp_vnc] start proxy success');
    expect(r.isProxySuccess, isTrue);
    expect(r.proxyName, 'tcp_vnc');
  });

  test('解析登录失败', () {
    final r = parseFrpcLog(
        '2024/01/02 15:04:05 [E] [client.go:261] login to server error: token is incorrect');
    expect(r.isLoginFailed, isTrue);
    expect(r.level, 'E');
  });

  test('无时间戳行按原样返回', () {
    final r = parseFrpcLog('frpc started');
    expect(r.text, 'frpc started');
    expect(r.isLoginSuccess, isFalse);
  });
}
