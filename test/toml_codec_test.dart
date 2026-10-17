import 'package:flutter_test/flutter_test.dart';
import 'package:frpc_vnc/models/frpc_profile.dart';
import 'package:frpc_vnc/services/frpc/toml_codec.dart';

void main() {
  group('profileToToml / tomlToProfile 往返', () {
    test('完整 TCP 配置往返无损', () {
      final p = FrpcProfile(
        id: 'x',
        name: '测试',
        server: ServerConfig(
          serverAddr: 'frps.example.com',
          serverPort: 7000,
          token: 'abc123',
          tlsEnable: true,
          tlsDisableCustomVerify: true,
          transportProtocol: 'kcp',
          bandwidthLimit: '1MB',
          user: 'u1',
        ),
        proxies: [
          TcpProxy(name: 'vnc', localIp: '127.0.0.1', localPort: 5900, remotePort: 6000),
        ],
      );
      final toml = profileToToml(p);
      expect(toml, contains('serverAddr = "frps.example.com"'));
      expect(toml, contains('serverPort = 7000'));
      expect(toml, contains('token = "abc123"'));
      expect(toml, contains('[[proxies]]'));

      final back = tomlToProfile(toml, id: 'x');
      expect(back.server.serverAddr, 'frps.example.com');
      expect(back.server.serverPort, 7000);
      expect(back.server.token, 'abc123');
      expect(back.server.transportProtocol, 'kcp');
      expect(back.server.tlsEnable, true);
      expect(back.server.tlsDisableCustomVerify, true);
      expect(back.server.bandwidthLimit, '1MB');
      expect(back.server.user, 'u1');
      expect(back.proxies, hasLength(1));
      final proxy = back.proxies.first as TcpProxy;
      expect(proxy.name, 'vnc');
      expect(proxy.localPort, 5900);
      expect(proxy.remotePort, 6000);
      expect(proxy.localIp, '127.0.0.1');
    });

    test('全部代理类型往返', () {
      final p = FrpcProfile(
        id: 'x',
        name: 'all',
        server: ServerConfig(serverAddr: 'a', serverPort: 7000),
        proxies: [
          TcpProxy(name: 't', localPort: 1, remotePort: 2),
          UdpProxy(name: 'u', localPort: 3, remotePort: 4),
          HttpProxy(
            name: 'h',
            localPort: 5,
            customDomains: ['a.com', 'b.com'],
            subdomain: 'sd',
            locations: ['/x'],
          ),
          HttpsProxy(name: 'hs', localPort: 6, customDomains: ['c.com']),
          StcpProxy(name: 's', localPort: 7, secretKey: 'sk'),
          XtcpProxy(name: 'x', localPort: 8, secretKey: 'sk2'),
        ],
      );
      final back = tomlToProfile(profileToToml(p), id: 'x');
      expect(back.proxies, hasLength(6));
      expect((back.proxies[0] as TcpProxy).remotePort, 2);
      expect((back.proxies[1] as UdpProxy).remotePort, 4);
      final h = back.proxies[2] as HttpProxy;
      expect(h.customDomains, ['a.com', 'b.com']);
      expect(h.subdomain, 'sd');
      expect(h.locations, ['/x']);
      expect((back.proxies[3] as HttpsProxy).customDomains, ['c.com']);
      expect((back.proxies[4] as StcpProxy).secretKey, 'sk');
      expect((back.proxies[5] as XtcpProxy).secretKey, 'sk2');
    });

    test('未识别字段原样保留', () {
      const source = '''
serverAddr = "s"
serverPort = 7000

[log]
level = "debug"
maxDays = 3

[[proxies]]
name = "p"
type = "tcp"
localPort = 80
remotePort = 8080
customMetricsTags = "abc"
''';
      final p = tomlToProfile(source, id: 'x');
      expect(p.extra['log'], isA<Map>());
      expect((p.extra['log'] as Map)['level'], 'debug');
      final proxy = p.proxies.first as TcpProxy;
      expect(proxy.extra['customMetricsTags'], 'abc');
      // 再导出仍包含这些字段。
      final toml = profileToToml(p);
      expect(toml, contains('level = "debug"'));
      expect(toml, contains('customMetricsTags = "abc"'));
    });

    test('官方 frpc.toml 样例可解析', () {
      const sample = '''
serverAddr = "x.frp.com"
serverPort = 7000
auth.token = "public"

[[proxies]]
name = "ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = 6000

[[proxies]]
name = "web"
type = "http"
localPort = 80
customDomains = ["www.yourdomain.com"]
''';
      final p = tomlToProfile(sample, id: 'x');
      expect(p.server.serverAddr, 'x.frp.com');
      expect(p.server.token, 'public');
      expect(p.proxies, hasLength(2));
      expect((p.proxies[1] as HttpProxy).customDomains, ['www.yourdomain.com']);
    });
  });

  group('TOML 解析器', () {
    test('多行数组与注释', () {
      final m = parseToml('''
# 注释
a = [1, 2,
     3]
b = "x # not comment"
''');
      expect(m['a'], [1, 2, 3]);
      expect(m['b'], 'x # not comment');
    });

    test('数字格式', () {
      final m = parseToml('a = 0x10\nb = 1_000\nc = 1.5\nd = true');
      expect(m['a'], 16);
      expect(m['b'], 1000);
      expect(m['c'], 1.5);
      expect(m['d'], true);
    });

    test('数组表连续元素', () {
      final m = parseToml('''
[[ps]]
n = 1
[[ps]]
n = 2
''');
      expect((m['ps'] as List).length, 2);
      expect(((m['ps'] as List)[1] as Map)['n'], 2);
    });

    test('解析错误带行号', () {
      expect(
        () => parseToml('a = 1\nb c'),
        throwsA(isA<TomlParseException>().having(
          (e) => e.line,
          'line',
          2,
        )),
      );
    });

    test('字符串转义', () {
      final m = parseToml(r'a = "x\ny\tz\"q"');
      expect(m['a'], 'x\ny\tz"q');
    });
  });
}
