import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frpc_vnc/services/vnc/rfb/decoders.dart';
import 'package:frpc_vnc/services/vnc/rfb/tight_decoder.dart';

class FakeReader implements AsyncByteReader {
  FakeReader(this.data) : _pos = 0;
  final Uint8List data;
  int _pos;

  @override
  Future<void> cancel() async {}

  @override
  Future<Uint8List> read(int n) async {
    if (_pos + n > data.length) throw StateError('测试数据不足: 请求 $n, 剩余 ${data.length - _pos}');
    final out = Uint8List.sublistView(data, _pos, _pos + n);
    _pos += n;
    return out;
  }
}

Uint8List zlib(List<int> data) => Uint8List.fromList(ZLibCodec().encoder.convert(data));

/// 紧凑长度编码。
Uint8List compactLen(int v) {
  if (v <= 0x7F) return Uint8List.fromList([v]);
  final b1 = (v & 0x7F) | 0x80;
  if (v <= 0x3FFF) {
    return Uint8List.fromList([b1, (v >> 7) & 0x7F]);
  }
  return Uint8List.fromList([b1, ((v >> 7) & 0x7F) | 0x80, (v >> 14) & 0xFF]);
}

void main() {
  test('纯色填充', () async {
    final fb = Framebuffer(4, 4);
    final d = TightDecoder();
    final data = Uint8List.fromList([
      0x80, // 高 4 位 0x08 = fill（低 4 位无重置标志）
      0xAA, 0xBB, 0xCC, // RGB
    ]);
    await d.decode(Rect(0, 0, 4, 4), fb, FakeReader(data));
    expect(fb.pixels[0], 0xAA);
    expect(fb.pixels[1], 0xBB);
    expect(fb.pixels[2], 0xCC);
    expect(fb.pixels[3], 255);
    expect(fb.pixels[15 * 4], 0xAA); // 最后像素 (3,3) R
  });

  test('Copy 过滤 zlib 压缩矩形', () async {
    final fb = Framebuffer(4, 2);
    final d = TightDecoder();
    // 4x2x3 = 24 字节原始数据。
    final raw = Uint8List(24);
    for (var i = 0; i < 24; i++) {
      raw[i] = i * 7 & 0xFF;
    }
    final compressed = zlib(raw);
    final data = BytesBuilder()
      ..addByte(0x00) // 类型 0 = zlib 流 0（无显式过滤器）
      ..add(compactLen(compressed.length))
      ..add(compressed);
    await d.decode(Rect(0, 0, 4, 2), fb, FakeReader(data.toBytes()));
    expect(fb.pixels[0], 0);
    expect(fb.pixels[1], 7);
    expect(fb.pixels[2], 14);
    expect(fb.pixels[3], 255);
    // 最后一像素 (3,1)。
    final lastOff = (1 * 4 + 3) * 4;
    expect(fb.pixels[lastOff], raw[21]);
  });

  test('未压缩小矩形（<12 字节）', () async {
    final fb = Framebuffer(2, 1);
    final d = TightDecoder();
    final data = Uint8List.fromList([
      0x00, // 类型 0
      0x10, 0x20, 0x30, // 像素 0
      0x40, 0x50, 0x60, // 像素 1
    ]);
    await d.decode(Rect(0, 0, 2, 1), fb, FakeReader(data));
    expect(fb.pixels[0], 0x10);
    expect(fb.pixels[1], 0x20);
    expect(fb.pixels[2], 0x30);
    expect(fb.pixels[3], 255); // alpha
    expect(fb.pixels[4], 0x40);
    expect(fb.pixels[6], 0x60);
  });

  test('Palette 过滤（2 色 1bpp）', () async {
    final fb = Framebuffer(8, 1);
    final d = TightDecoder();
    // 8 像素 1bpp → 1 字节行数据（8 位正好）。
    // 数据 8 字节 < 12 → 不压缩直传。
    final data = BytesBuilder()
      ..addByte(0x40) // 高 4 位含显式过滤器位
      ..addByte(0x01) // palette
      ..addByte(0x01) // paletteSize-1 = 1 → 2 色
      ..add([0xFF, 0x00, 0x00]) // palette[0] 红
      ..add([0x00, 0x00, 0xFF]) // palette[1] 蓝
      ..add([170]); // 0b10101010
    await d.decode(Rect(0, 0, 8, 1), fb, FakeReader(data.toBytes()));
    // bit=1 → 蓝。
    expect(fb.pixels[0], 0);
    expect(fb.pixels[2], 0xFF);
    expect(fb.pixels[4], 255);
    // bit=0 → 红。
    expect(fb.pixels[1 * 4], 0xFF);
    expect(fb.pixels[1 * 4 + 2], 0);
  });

  test('Gradient 过滤', () async {
    final fb = Framebuffer(4, 2);
    final d = TightDecoder();
    // 构造梯度数据：从纯灰度图反推。
    // 直接编码目标图像：预测为 left+upper-upperLeft。
    // 目标 (x,y) = [x*50, x*50, x*50]（行间无变化 → delta 预测精确）。
    // 目标图像两行相同 [0,50,100,150]。
    // 行 0：predict = left；行 1：predict = left + upper - upperLeft
    // （行 1 各值等于行 0，upper - upperLeft = left → delta = 0）。
    final diffs = BytesBuilder();
    for (var x = 0; x < 4; x++) {
      final delta0 = x == 0 ? 0 : 50;
      for (var c = 0; c < 3; c++) {
        diffs.addByte(delta0);
      }
    }
    for (var x = 0; x < 4; x++) {
      for (var c = 0; c < 3; c++) {
        diffs.addByte(0);
      }
    }
    final compressed = zlib(diffs.toBytes());
    final data = BytesBuilder()
      ..addByte(0x40) // 高 4 位含显式过滤器位
      ..addByte(0x02) // gradient
      ..add(compactLen(compressed.length))
      ..add(compressed);
    await d.decode(Rect(0, 0, 4, 2), fb, FakeReader(data.toBytes()));
    expect(fb.pixels[0], 0);
    expect(fb.pixels[4], 50);
    expect(fb.pixels[8], 100);
    expect(fb.pixels[12], 150);
    // 第二行与第一行相同。
    expect(fb.pixels[(1 * 4 + 2) * 4], 100);
  });

  test('JPEG 矩形（长度紧凑编码后跳过像素断言，仅验证不抛异常且填充）', () async {
    final fb = Framebuffer(4, 4);
    final d = TightDecoder();
    // 这里验证非法 JPEG 回退为灰色填充。
    const jpeg = [0xFF, 0xD8, 0xFF, 0xD9]; // 非法内容
    final data = BytesBuilder()
      ..addByte(0x90) // 高 4 位 0x09 = JPEG
      ..add(compactLen(jpeg.length))
      ..add(jpeg);
    await d.decode(Rect(0, 0, 4, 4), fb, FakeReader(data.toBytes()));
    expect(fb.pixels[0], 128); // 灰色回退
    expect(fb.pixels[3], 255);
  });

  test('流重置标志', () async {
    final fb = Framebuffer(2, 1);
    final d = TightDecoder();
    // 6 字节 < 12 → 不压缩直传；ctrl=0x00 无重置、类型 0（copy）。
    final data1 = Uint8List.fromList([
      0x00, 1, 2, 3, 4, 5, 6, //
    ]);
    await d.decode(Rect(0, 0, 2, 1), fb, FakeReader(data1));
    expect(fb.pixels[0], 1);

    // 重置标志(bit0)置位 + 类型 0：数据仍为直传（重置只影响 zlib 流状态）。
    d.dispose();
    final data2 = Uint8List.fromList(const [
      0x01, 9, 9, 9, 9, 9, 9, //
    ]);
    await d.decode(Rect(0, 0, 2, 1), fb, FakeReader(data2));
    expect(fb.pixels[0], 9);
  });
}
