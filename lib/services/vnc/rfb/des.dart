library;

/// DES-ECB 实现，专用于 RFB VNC 认证（RFC 6143 §7.2.2）。
///
/// VNC 认证中 DES 的位序与常规实现不同：密钥每个字节按位反转
/// （LSB-first）。`vncAuthKey` 已处理该转换。

import 'dart:typed_data';

// 初始置换表（标准 DES IP）。
const List<int> _ip = [
  58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4, //
  62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8,
  57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3,
  61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7,
];

// 逆初始置换（IP^-1）。
const List<int> _fp = [
  40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31, //
  38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29,
  36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27,
  34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25,
];

// 扩展置换 E。
const List<int> _e = [
  32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11, 12, 13, 12, 13, 14, 15, 16, 17, //
  16, 17, 18, 19, 20, 21, 20, 21, 22, 23, 24, 25, 24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1,
];

// P 置换。
const List<int> _p = [
  16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10, //
  2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25,
];

// S 盒。
const List<List<int>> _sbox = [
  [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8, 4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
  [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5, 0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
  [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1, 13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
  [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9, 10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
  [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6, 4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
  [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8, 9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
  [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6, 1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
  [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2, 7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11],
];

// 子密钥左移位数。
const List<int> _shifts = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1];

// PC1 / PC2 置换表。
const List<int> _pc1 = [
  57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35, 27, 19, 11, 3, 60, 52, 44, 36, //
  63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 28, 20, 12, 4,
];

const List<int> _pc2 = [
  14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10, 23, 19, 12, 4, 26, 8, 16, 7, 27, 20, 13, 2, //
  41, 52, 31, 37, 47, 55, 30, 40, 51, 45, 33, 48, 44, 49, 39, 56, 34, 53, 46, 42, 50, 36, 29, 32,
];

/// 将 VNC 密码（≤8 字符）转换为 DES 密钥字节（按位反转）。
Uint8List vncAuthKey(String password) {
  final pw = password.substring(0, password.length.clamp(0, 8)).codeUnits;
  final key = Uint8List(8);
  for (var i = 0; i < 8; i++) {
    final ch = i < pw.length ? pw[i] : 0;
    // 按位反转（VNC 规范要求 LSB-first 读取密钥）。
    var reversed = 0;
    for (var b = 0; b < 8; b++) {
      if (ch & (1 << b) != 0) reversed |= 1 << (7 - b);
    }
    key[i] = reversed;
  }
  return key;
}

/// DES-ECB 加密 [data]（长度须为 8 的倍数），返回新字节列表。
Uint8List desEcbEncrypt(List<int> key, List<int> data) {
  if (key.length != 8) throw ArgumentError('DES 密钥须为 8 字节');
  if (data.length % 8 != 0) throw ArgumentError('DES 数据长度须为 8 的倍数');
  final subkeys = _deriveSubkeys(key);
  final out = Uint8List(data.length);
  for (var off = 0; off < data.length; off += 8) {
    final block = _encryptBlock(subkeys, data.sublist(off, off + 8));
    out.setRange(off, off + 8, block);
  }
  return out;
}

List<List<int>> _deriveSubkeys(List<int> key) {
  // PC1：56 位。
  final k56 = List<int>.filled(56, 0);
  for (var i = 0; i < 56; i++) {
    k56[i] = _bitAt(key, _pc1[i] - 1);
  }
  final c = k56.sublist(0, 28);
  final d = k56.sublist(28);
  final subkeys = <List<int>>[];
  for (var round = 0; round < 16; round++) {
    for (var s = 0; s < _shifts[round]; s++) {
      c.add(c.removeAt(0));
      d.add(d.removeAt(0));
    }
    final cd = [...c, ...d];
    final sk = List<int>.filled(48, 0);
    for (var i = 0; i < 48; i++) {
      sk[i] = cd[_pc2[i] - 1];
    }
    subkeys.add(sk);
  }
  return subkeys;
}

List<int> _encryptBlock(List<List<int>> subkeys, List<int> block) {
  final pre = List<int>.filled(64, 0);
  for (var i = 0; i < 64; i++) {
    pre[i] = _bitAt(block, _ip[i] - 1);
  }
  var l = pre.sublist(0, 32);
  var r = pre.sublist(32);
  for (var round = 0; round < 16; round++) {
    final expanded = List<int>.filled(48, 0);
    for (var i = 0; i < 48; i++) {
      expanded[i] = r[_e[i] - 1];
    }
    final xored = List<int>.generate(48, (i) => expanded[i] ^ subkeys[round][i]);
    final sOut = List<int>.filled(32, 0);
    for (var box = 0; box < 8; box++) {
      final b = xored.sublist(box * 6, box * 6 + 6);
      final row = (b[0] << 1) | b[5];
      final col = (b[1] << 3) | (b[2] << 2) | (b[3] << 1) | b[4];
      final val = _sbox[box][row * 16 + col];
      for (var bit = 0; bit < 4; bit++) {
        sOut[box * 4 + bit] = (val >> (3 - bit)) & 1;
      }
    }
    final pOut = List<int>.filled(32, 0);
    for (var i = 0; i < 32; i++) {
      pOut[i] = sOut[_p[i] - 1];
    }
    final newR = List<int>.generate(32, (i) => l[i] ^ pOut[i]);
    l = r;
    r = newR;
  }
  final combined = [...r, ...l]; // 注意最终交换
  final out = List<int>.filled(8, 0);
  for (var i = 0; i < 64; i++) {
    if (combined[_fp[i] - 1] == 1) {
      out[i >> 3] |= 1 << (7 - (i & 7));
    }
  }
  return out;
}

/// 取 [data] 第 [bitIndex] 位（MSB-first 字节序）。
int _bitAt(List<int> data, int bitIndex) {
  final byte = data[bitIndex >> 3];
  return (byte >> (7 - (bitIndex & 7))) & 1;
}
