import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frpc_vnc/services/vnc/rfb/ard_auth.dart';
import 'package:frpc_vnc/services/vnc/rfb/md5.dart';
import 'package:pointycastle/export.dart' as pc;

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// RFC 2409 第二 Oakley 群（1024-bit MODP），与真实服务器一致。
const pHex =
    'FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B'
    '139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485'
    'B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1F'
    'E649286651ECE65381FFFFFFFFFFFFFFFF';

BigInt be(Uint8List bytes) => BigInt.parse(
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      radix: 16,
    );

void main() {
  group('MD5（RFC 1321 向量）', () {
    test('空字符串', () {
      expect(hex(md5(utf8.encode(''))), 'd41d8cd98f00b204e9800998ecf8427e');
    });
    test('"abc"', () {
      expect(hex(md5(utf8.encode('abc'))), '900150983cd24fb0d6963f7d28e17f72');
    });
    test('长消息（跨块）', () {
      expect(
        hex(md5(utf8.encode('abcdefghijklmnopqrstuvwxyz'))),
        'c3fcd3d76192e4007dfb496cca67e13b',
      );
    });
  });

  group('Apple DH 认证（TigerVNC CSecurityDH 语义，服务器侧往返验证）', () {
    test('服务器可解密出用户名与密码', () {
      final p = BigInt.parse(pHex, radix: 16);
      final g = BigInt.two;
      final keyLen = 128;

      // "服务器"侧：选定私钥，计算 A = g^a mod p。
      final serverSecret = BigInt.from(123456789);
      final serverPub = g.modPow(serverSecret, p);

      // 组装服务器参数字节流。
      final paramsBytes = BytesBuilder();
      final genBytes = ByteData(2)..setUint16(0, 2);
      final lenBytes = ByteData(2)..setUint16(0, keyLen);
      paramsBytes.add(genBytes.buffer.asUint8List());
      paramsBytes.add(lenBytes.buffer.asUint8List());
      paramsBytes.add(toFixedBe(p, keyLen));
      paramsBytes.add(toFixedBe(serverPub, keyLen));

      final params = AppleDhParams.parse(paramsBytes.toBytes());

      // 客户端计算响应。
      final resp = appleDhAuth(params, 'alice', 'hunter2');

      // "服务器"侧：读 B，算共享密钥，解密凭据。
      final clientPub = be(resp.clientPublic);
      final shared = clientPub.modPow(serverSecret, p);
      final aesKey = Uint8List.fromList(md5(toFixedBe(shared, keyLen)));

      final cipher = pc.ECBBlockCipher(pc.AESEngine())..init(false, pc.KeyParameter(aesKey));
      final creds = Uint8List(128);
      var off = 0;
      for (var block = 0; block < 8; block++) {
        off += cipher.processBlock(resp.encryptedCredentials, off, creds, block * 16);
      }

      // username@0 NUL 结尾，password@64 NUL 结尾。
      final username = creds.sublist(0, 64).takeWhile((b) => b != 0).toList();
      final password = creds.sublist(64).takeWhile((b) => b != 0).toList();
      expect(utf8.decode(username), 'alice');
      expect(utf8.decode(password), 'hunter2');
    });

    test('真实服务器参数（10.13.6.118 抓包的 1024-bit 模数）可解析', () {
      // gen=2, keyLen=128, p=Oakley group 2, A=服务器公钥（此处用假值）。
      final b = BytesBuilder();
      b.add([0, 2, 0, 128]);
      b.add(toFixedBe(BigInt.parse(pHex, radix: 16), 128));
      b.add(toFixedBe(BigInt.from(0x1234), 128));
      final params = AppleDhParams.parse(b.toBytes());
      expect(params.generator, BigInt.two);
      expect(params.keyLen, 128);
      expect(params.prime, BigInt.parse(pHex, radix: 16));
      expect(params.serverPublic, BigInt.from(0x1234));
    });

    test('客户端公钥为 keyLen 字节且小于 p', () {
      final p = BigInt.parse(pHex, radix: 16);
      final paramsBytes = BytesBuilder()
        ..add([0, 2, 0, 128])
        ..add(toFixedBe(p, 128))
        ..add(toFixedBe(BigInt.from(0x99), 128));
      final params = AppleDhParams.parse(paramsBytes.toBytes());
      final resp = appleDhAuth(params, 'u', 'p');
      expect(resp.clientPublic, hasLength(128));
      expect(resp.encryptedCredentials, hasLength(128));
      expect(be(resp.clientPublic) < p, isTrue);
    });

    test('缺用户名时报错', () {
      final p = BigInt.parse(pHex, radix: 16);
      final paramsBytes = BytesBuilder()
        ..add([0, 2, 0, 128])
        ..add(toFixedBe(p, 128))
        ..add(toFixedBe(BigInt.one, 128));
      final params = AppleDhParams.parse(paramsBytes.toBytes());
      expect(() => appleDhAuth(params, '', 'pw'), throwsArgumentError);
    });
  });
}
