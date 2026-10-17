import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frpc_vnc/services/vnc/rfb/ard_auth.dart';

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('MD5（RFC 1321 向量）', () {
    test('空字符串', () {
      expect(hex(md5(utf8.encode(''))), 'd41d8cd98f00b204e9800998ecf8427e');
    });
    test('"abc"', () {
      expect(hex(md5(utf8.encode('abc'))), '900150983cd24fb0d6963f7d28e17f72');
    });
    test('"The quick brown fox jumps over the lazy dog"', () {
      expect(
        hex(md5(utf8.encode('The quick brown fox jumps over the lazy dog'))),
        '9e107d9d372bb6826bd81d3542a419d6',
      );
    });
    test('长消息（>64 字节跨块）', () {
      // MD5("abcdefghijklmnopqrstuvwxyz") = c3fcd3d76192e4007dfb496cca67e13b
      expect(
        hex(md5(utf8.encode('abcdefghijklmnopqrstuvwxyz'))),
        'c3fcd3d76192e4007dfb496cca67e13b',
      );
    });
  });

  group('HMAC-MD5（RFC 2202 向量）', () {
    test('用例 2：key="Jefe"', () {
      final r = hmacMd5(
        utf8.encode('Jefe'),
        utf8.encode('what do ya want for nothing?'),
      );
      expect(hex(r), '750c783e6ab0b503eaa86e310a5db738');
    });
    test('用例 3：key=0xaa*16, msg=0xdd*50', () {
      final r = hmacMd5(
        List.filled(16, 0xAA),
        List.filled(50, 0xDD),
      );
      expect(hex(r), '56be34521d144c88dbb8c733f0e8b3f6');
    });
  });

  group('ARD 认证（独立 Python 参考实现生成的期望值）', () {
    test('密码 test、挑战全 0', () {
      final r = ardEncryptPassword('test', Uint8List.fromList(List.filled(16, 0)));
      expect(hex(r), 'd4a2965af915df01bd3c8788628b228d');
    });
    test('密码 secret、挑战 00..0f', () {
      final r = ardEncryptPassword('secret', Uint8List.fromList(List.generate(16, (i) => i)));
      expect(hex(r), '190436a8749b04ea2b05642533f2291b');
    });
    test('超长密码截断到 64 字节', () {
      final long = 'a' * 100;
      final truncated = 'a' * 32; // UTF-16LE: 32 字符 = 64 字节
      expect(
        ardEncryptPassword(long, Uint8List.fromList(List.filled(16, 1))),
        ardEncryptPassword(truncated, Uint8List.fromList(List.filled(16, 1))),
      );
    });
  });
}
