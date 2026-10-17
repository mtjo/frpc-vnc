import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frpc_vnc/services/vnc/rfb/des.dart';

void main() {
  group('DES-ECB', () {
    test('标准测试向量', () {
      // FIPS 81 经典向量：key 133457799BBCDFF1, 明文 0123456789ABCDEF
      // 密文 85E813540F0AB405。
      final key = Uint8List.fromList([0x13, 0x34, 0x57, 0x79, 0x9B, 0xBC, 0xDF, 0xF1]);
      final plain = Uint8List.fromList([0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF]);
      final cipher = desEcbEncrypt(key, plain);
      expect(cipher, [0x85, 0xE8, 0x13, 0x54, 0x0F, 0x0A, 0xB4, 0x05]);
    });

    test('VNC 密钥按位反转', () {
      // 'A' = 0x41 = 01000001 → 反转 10000010 = 0x82。
      final key = vncAuthKey('A');
      expect(key[0], 0x82);
      expect(key.length, 8);
      // 不足 8 字节补零。
      final key2 = vncAuthKey('');
      expect(key2.every((b) => b == 0), isTrue);
    });

    test('超长密码截断到 8 字节', () {
      final key = vncAuthKey('1234567890');
      final key8 = vncAuthKey('12345678');
      expect(key, key8);
    });
  });
}
