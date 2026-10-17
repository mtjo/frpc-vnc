/// Apple Remote Desktop VNC 认证（RFB 安全类型 30）。
///
/// macOS「屏幕共享」默认只提供 ARD 认证（30/33/35/36）。类型 30 的
/// 算法（公开逆向资料）：
/// 1. 密码按 UTF-16LE 编码，零填充到 64 字节作为 HMAC 密钥；
/// 2. 服务端发 16 字节挑战；
/// 3. 回应 = HMAC-MD5(key, HMAC-MD5(key, challenge))，共 16 字节。

import 'dart:typed_data';

// RFC 2104 HMAC-MD5。
List<int> hmacMd5(List<int> key, List<int> message) {
  const blockSize = 64;

  var k = List<int>.of(key);
  if (k.length > blockSize) {
    k = md5(k);
  }
  while (k.length < blockSize) {
    k.add(0);
  }

  final inner = <int>[for (var i = 0; i < blockSize; i++) 0x36 ^ k[i], ...message];
  final outer = <int>[for (var i = 0; i < blockSize; i++) 0x5C ^ k[i], ...md5(inner)];
  return md5(outer);
}

Uint8List ardEncryptPassword(String password, Uint8List challenge) {
  // UTF-16LE 编码。
  var key = <int>[
    for (final rune in password.codeUnits) ...[rune & 0xFF, (rune >> 8) & 0xFF],
  ];
  // 零填充到 64 字节。
  if (key.length > 64) {
    key = key.sublist(0, 64);
  } else {
    while (key.length < 64) {
      key.add(0);
    }
  }
  final round1 = hmacMd5(key, challenge);
  final round2 = hmacMd5(key, round1);
  return Uint8List.fromList(round2);
}

// ---------------------------------------------------------------------------
// MD5 纯 Dart 实现（dart:crypto 无此包；自实现避免额外依赖）。
// ---------------------------------------------------------------------------

const int _a0 = 0x67452301;
const int _b0 = 0xefcdab89;
const int _c0 = 0x98badcfe;
const int _d0 = 0x10325476;

const List<int> _shifts = [
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, //
  5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
  4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
  6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
];

/// K[i] = floor(abs(sin(i + 1)) * 2^32)，预计算表。
const List<int> _kTable = [
  0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
  0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
  0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
  0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
  0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
  0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
  0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
  0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
];

int _rotl(int x, int c) => ((x << c) | (x >> (32 - c))) & 0xFFFFFFFF;

/// MD5 摘要（公开供测试与内部使用）。
List<int> md5(List<int> message) {
  // 填充。
  final msg = List<int>.of(message);
  final bitLen = message.length * 8;
  msg.add(0x80);
  while (msg.length % 64 != 56) {
    msg.add(0);
  }
  for (var i = 0; i < 8; i++) {
    msg.add((bitLen >> (8 * i)) & 0xFF);
  }

  var a0 = _a0, b0 = _b0, c0 = _c0, d0 = _d0;

  for (var chunk = 0; chunk < msg.length; chunk += 64) {
    final m = List<int>.filled(16, 0);
    for (var i = 0; i < 16; i++) {
      m[i] = msg[chunk + i * 4] |
          (msg[chunk + i * 4 + 1] << 8) |
          (msg[chunk + i * 4 + 2] << 16) |
          (msg[chunk + i * 4 + 3] << 24);
    }
    var a = a0, b = b0, c = c0, d = d0;
    for (var i = 0; i < 64; i++) {
      int f, g;
      if (i < 16) {
        f = (b & c) | (~b & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | (~d & c);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = b ^ c ^ d;
        g = (3 * i + 5) % 16;
      } else {
        f = c ^ (b | ~d);
        g = (7 * i) % 16;
      }
      f = (f + a + _kTable[i] + m[g]) & 0xFFFFFFFF;
      a = d;
      d = c;
      c = b;
      b = (b + _rotl(f, _shifts[i])) & 0xFFFFFFFF;
    }
    a0 = (a0 + a) & 0xFFFFFFFF;
    b0 = (b0 + b) & 0xFFFFFFFF;
    c0 = (c0 + c) & 0xFFFFFFFF;
    d0 = (d0 + d) & 0xFFFFFFFF;
  }

  final out = <int>[];
  for (final v in [a0, b0, c0, d0]) {
    out
      ..add(v & 0xFF)
      ..add((v >> 8) & 0xFF)
      ..add((v >> 16) & 0xFF)
      ..add((v >> 24) & 0xFF);
  }
  return out;
}
