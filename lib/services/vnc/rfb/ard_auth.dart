/// Apple Remote Desktop / macOS 屏幕共享认证（RFB 安全类型 30）。
///
/// 移植自 TigerVNC `CSecurityDH`（common/rfb/CSecurityDH.cxx），即该未公开
/// 协议的参考实现（https://github.com/TigerVNC/tigervnc）。
///
/// 选择该安全类型后的握手：
///   server -> client: generator(u16), key_len(u16), p(key_len 字节), A(key_len 字节)
///   client -> server: AES-128-ECB(username[64] + password[64]) 共 128 字节，
///                     然后 B(key_len 字节)
/// 其中 A = g^a mod p（服务器私钥 a），B = g^b mod p（客户端私钥 b），
/// 共享密钥 k = A^b mod p，AES 密钥 = MD5(k)（定长 BE 编码后的共享值）。

import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;

import 'md5.dart';

/// 服务器 DH 参数（握手前半段）。
class AppleDhParams {
  AppleDhParams._(this.generator, this.keyLen, this.prime, this.serverPublic);

  final BigInt generator;
  final int keyLen;
  final BigInt prime;
  final BigInt serverPublic;

  static const minKeyLen = 128;
  static const maxKeyLen = 1024;

  /// 从服务器发送的原始字节解析：gen(2) + keyLen(2) + p + A。
  static AppleDhParams parse(Uint8List data) {
    if (data.length < 4) {
      throw FormatException('Apple DH 参数不完整');
    }
    final bd = ByteData.sublistView(data);
    final generator = bd.getUint16(0);
    final keyLen = bd.getUint16(2);
    if (keyLen < minKeyLen || keyLen > maxKeyLen) {
      throw FormatException('Apple DH 密钥长度非法: $keyLen');
    }
    if (data.length != 4 + keyLen * 2) {
      throw FormatException('Apple DH 参数长度不匹配: ${data.length}');
    }
    final prime = _be(data, 4, keyLen);
    final serverPublic = _be(data, 4 + keyLen, keyLen);
    if (prime == BigInt.zero) {
      throw FormatException('Apple DH 模数非法');
    }
    return AppleDhParams._(BigInt.from(generator), keyLen, prime, serverPublic);
  }

  /// 读取需要的总字节数：4 + keyLen*2（keyLen 在前 4 字节中）。
  static int expectedLength(Uint8List header) {
    final keyLen = ByteData.sublistView(header).getUint16(2);
    return 4 + keyLen * 2;
  }

  static BigInt _be(Uint8List data, int offset, int len) => BigInt.parse(
        data.sublist(offset, offset + len).map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        radix: 16,
      );
}

/// 客户端响应：加密凭据（128 字节）+ 客户端公钥（keyLen 字节）。
class AppleDhResponse {
  AppleDhResponse(this.encryptedCredentials, this.clientPublic);

  final Uint8List encryptedCredentials;
  final Uint8List clientPublic;
}

/// 定长 BE 编码（左填充零，对齐 nettle_mpz_get_str_256 行为）。
Uint8List toFixedBe(BigInt n, int len) {
  var hex = n.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  final bytes = <int>[
    for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
  ];
  if (bytes.length > len) {
    throw ArgumentError('大数超出 $len 字节');
  }
  final out = Uint8List(len);
  out.setRange(len - bytes.length, len, bytes);
  return out;
}

/// 执行 DH 计算并生成客户端响应。
///
/// [username]/[password] 均须短于 64 字节。客户端私钥为 keyLen 字节随机数。
AppleDhResponse appleDhAuth(AppleDhParams params, String username, String password) {
  if (username.isEmpty) {
    throw ArgumentError('ARD 认证需要用户名（macOS 登录用户名）');
  }
  if (username.length >= 64) throw ArgumentError('用户名过长（<64 字节）');
  if (password.length >= 64) throw ArgumentError('密码过长（<64 字节）');

  final rng = Random.secure();
  final secretBytes = Uint8List(params.keyLen);
  for (var i = 0; i < params.keyLen; i++) {
    secretBytes[i] = rng.nextInt(256);
  }
  final secret = _beToBigInt(secretBytes);

  final shared = params.serverPublic.modPow(secret, params.prime);
  final clientPublic = params.generator.modPow(secret, params.prime);

  // AES-128 密钥 = MD5(定长 BE 共享值)。
  final sharedBytes = toFixedBe(shared, params.keyLen);
  final aesKey = Uint8List.fromList(md5(sharedBytes));

  // 凭据缓冲：随机填充，username@0 NUL 结尾，password@64 NUL 结尾。
  final buf = Uint8List(128);
  for (var i = 0; i < 128; i++) {
    buf[i] = rng.nextInt(256);
  }
  buf.setRange(0, username.length, username.codeUnits);
  buf[username.length] = 0;
  buf.setRange(64, 64 + password.length, password.codeUnits);
  buf[64 + password.length] = 0;

  // AES-128-ECB 无填充加密。
  final cipher = pc.ECBBlockCipher(pc.AESEngine())..init(true, pc.KeyParameter(aesKey));
  final encrypted = Uint8List(128);
  var offset = 0;
  for (var block = 0; block < 8; block++) {
    offset += cipher.processBlock(buf, offset, encrypted, block * 16);
  }

  return AppleDhResponse(encrypted, toFixedBe(clientPublic, params.keyLen));
}

BigInt _beToBigInt(Uint8List bytes) => BigInt.parse(
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      radix: 16,
    );
