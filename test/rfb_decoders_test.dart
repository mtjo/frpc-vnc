import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frpc_vnc/services/vnc/rfb/decoders.dart';
import 'package:frpc_vnc/services/vnc/rfb/protocol.dart';

/// 直接以内存构造的 AsyncByteReader（覆盖 read 语义）。
class FakeReader implements AsyncByteReader {
  FakeReader(this.data) : _pos = 0;
  final Uint8List data;
  int _pos;

  @override
  Future<void> cancel() async {}

  @override
  Future<Uint8List> read(int n) async {
    if (_pos + n > data.length) throw StateError('测试数据不足');
    final out = Uint8List.sublistView(data, _pos, _pos + n);
    _pos += n;
    return out;
  }
}

Framebuffer fb8x8() => Framebuffer(8, 8);

void main() {
  group('AsyncByteReader（真实流）', () {
    test('跨 chunk 精确读取', () async {
      // 构造分块流。
      final chunks = <Uint8List>[
        Uint8List.fromList([1, 2, 3]),
        Uint8List.fromList([4, 5, 6, 7]),
        Uint8List.fromList([8]),
      ];
      final reader = AsyncByteReader(Stream.fromIterable(chunks));
      expect(await reader.read(2), [1, 2]);
      expect(await reader.read(5), [3, 4, 5, 6, 7]);
      expect(await reader.read(1), [8]);
      await expectLater(reader.read(1), throwsA(isA<VncConnectionClosed>()));
    });
  });

  group('Raw 解码', () {
    test('像素拷贝与 alpha 强制', () async {
      final fb = fb8x8();
      final data = Uint8List(8 * 2 * 4);
      for (var i = 0; i < 8 * 2; i++) {
        data[i * 4] = i;
        data[i * 4 + 1] = 10;
        data[i * 4 + 2] = 20;
        data[i * 4 + 3] = 0; // 线上未定义，应被强制为 255
      }
      await decodeRaw(Rect(0, 0, 8, 2), fb, FakeReader(data));
      expect(fb.pixels[0], 0);
      expect(fb.pixels[3], 255);
      // 第二行第 4 像素（序号 11）：R=11。
      expect(fb.pixels[(8 + 3) * 4], 11);
      expect(fb.pixels[(8 + 0) * 4], 8);
    });
  });

  group('CopyRect 解码', () {
    test('区域拷贝', () async {
      final fb = fb8x8();
      // 先填充左上 4x4 区域为红色。
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          final o = (y * 8 + x) * 4;
          fb.pixels[o] = 200;
          fb.pixels[o + 3] = 255;
        }
      }
      // 模拟服务端 CopyRect：源 (0,0) 4x4 → 目标 (4,4)。
      final reader = FakeReader(Uint8List.fromList([0, 0, 0, 0]));
      await decodeCopyRect(Rect(4, 4, 4, 4), fb, reader);
      expect(fb.pixels[(4 * 8 + 4) * 4], 200);
      expect(fb.pixels[(7 * 8 + 7) * 4], 200);
    });
  });

  group('Hextile 解码', () {
    test('背景 + 前景子矩形', () async {
      final fb = fb8x8();
      final data = BytesBuilder();
      // 一个 8x8 = 单 tile。
      // mask: backgroundSpecified | foregroundSpecified | anySubrects | subrectsColoured
      const mask = hexBackgroundSpecified | hexForegroundSpecified |
          hexAnySubrects | hexSubrectsColoured;
      data.addByte(mask);
      data.add(Uint8List.fromList([1, 2, 3, 255])); // bg 蓝
      data.add(Uint8List.fromList([200, 0, 0, 255])); // fg 红
      data.addByte(1); // 1 个子矩形
      data.add(Uint8List.fromList([200, 0, 0, 255])); // 子矩形颜色
      data.addByte(0); // sx
      data.addByte(0); // sy
      data.addByte(2); // sw
      data.addByte(2); // sh

      await decodeHextile(Rect(0, 0, 8, 8), fb, FakeReader(data.toBytes()));
      // 子矩形区域为红（(0,0) 被覆盖）。
      expect(fb.pixels[(0 * 8 + 0) * 4], 200);
      expect(fb.pixels[(0 * 8 + 0) * 4 + 1], 0);
      expect(fb.pixels[(0 * 8 + 0) * 4 + 2], 0);
      // (2,2) 仍是背景。
      expect(fb.pixels[(2 * 8 + 2) * 4], 1);
    });
  });

  group('Zlib 解码', () {
    test('压缩矩形展开', () async {
      final fb = fb8x8();
      final raw = Uint8List(8 * 8 * 4);
      for (var i = 0; i < 64; i++) {
        raw[i * 4] = i & 0xFF;
        raw[i * 4 + 3] = 255;
      }
      final compressed = ZLibCodec().encoder.convert(raw);
      final data = BytesBuilder()
        ..addByte(0)
        ..addByte(0)
        ..addByte(0)
        ..addByte(compressed.length) // 大端 U32 长度
        ..add(compressed);
      await decodeZlib(Rect(0, 0, 8, 8), fb, FakeReader(data.toBytes()));
      expect(fb.pixels[0], 0);
      expect(fb.pixels[(8 * 7 + 3) * 4], 59);
      expect(fb.pixels[3], 255);
    });
  });

  group('像素格式转换', () {
    test('convertPixelToRgba 16bpp', () {
      final f = PixelFormat()
        ..bitsPerPixel = 16
        ..depth = 16
        ..redMax = 31
        ..greenMax = 63
        ..blueMax = 31
        ..redShift = 11
        ..greenShift = 5
        ..blueShift = 0;
      final src = Uint8List.fromList([0, 0]); // 小端 0x0000
      final dst = Uint8List(4);
      convertPixelToRgba(src, 0, dst, 0, f);
      expect(dst, [0, 0, 0, 255]);
      // 红色最大：0xF800 → little-endian bytes [0x00, 0xF8]。
      src[0] = 0x00;
      src[1] = 0xF8;
      convertPixelToRgba(src, 0, dst, 0, f);
      expect(dst[0], 255);
      expect(dst[1], 0);
    });
  });
}
