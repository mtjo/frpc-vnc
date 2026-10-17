library;

/// RFB 协议常量与基础类型（RFC 6143）。

import 'dart:typed_data';

// --- 安全类型 ---
const int secInvalid = 0;
const int secNone = 1;
const int secVncAuthentication = 2;
const int secTight = 16;
const int secUltra = 17;
const int secArdAuthentication = 30; // Apple Remote Desktop（macOS 屏幕共享默认）
const int secTls = 18; // TigerVNC/RealVNC 扩展：先 TLS 握手再重新走 RFB 握手
const int secVeNCrypt = 19;

// --- 编码类型 ---
const int encRaw = 0;
const int encCopyRect = 1;
const int encHextile = 5;
const int encZlib = 6;
const int encTight = 7;
const int encPseudoCursor = -239;
const int encPseudoDesktopSize = -223;

// --- 客户端消息类型 ---
const int msgSetPixelFormat = 0;
const int msgSetEncodings = 2;
const int msgFramebufferUpdateRequest = 3;
const int msgKeyEvent = 4;
const int msgPointerEvent = 5;
const int msgClientCutText = 6;
// TightVNC 扩展
const int msgFileTransfer = 130;

// --- 服务器消息类型 ---
const int msgFramebufferUpdate = 0;
const int msgSetColourMapEntries = 1;
const int msgBell = 2;
const int msgServerCutText = 3;

// --- Hextile 子编码 ---
const int hexRaw = 1;
const int hexBackgroundSpecified = 2;
const int hexForegroundSpecified = 4;
const int hexAnySubrects = 8;
const int hexSubrectsColoured = 16;

/// 客户端像素格式：32bpp RGBA（wire 上按字节序传输）。
class PixelFormat {
  PixelFormat({
    this.bitsPerPixel = 32,
    this.depth = 24,
    this.bigEndian = false,
    this.trueColour = true,
    this.redMax = 255,
    this.greenMax = 255,
    this.blueMax = 255,
    this.redShift = 16,
    this.greenShift = 8,
    this.blueShift = 0,
  });

  int bitsPerPixel;
  int depth;
  bool bigEndian;
  bool trueColour;
  int redMax;
  int greenMax;
  int blueMax;
  int redShift;
  int greenShift;
  int blueShift;

  int get bytesPerPixel => bitsPerPixel ~/ 8;

  void writeTo(BytesSink sink) {
    sink.u8(bitsPerPixel);
    sink.u8(depth);
    sink.u8(bigEndian ? 1 : 0);
    sink.u8(trueColour ? 1 : 0);
    sink.u16(redMax);
    sink.u16(greenMax);
    sink.u16(blueMax);
    sink.u8(redShift);
    sink.u8(greenShift);
    sink.u8(blueShift);
    sink.u8(0); // padding ×3（RFB 规定像素格式共 16 字节）
    sink.u8(0);
    sink.u8(0);
  }

  static PixelFormat read(ByteReader r) {
    final f = PixelFormat();
    f.bitsPerPixel = r.u8();
    f.depth = r.u8();
    f.bigEndian = r.u8() == 1;
    f.trueColour = r.u8() == 1;
    f.redMax = r.u16();
    f.greenMax = r.u16();
    f.blueMax = r.u16();
    f.redShift = r.u8();
    f.greenShift = r.u8();
    f.blueShift = r.u8();
    r.u8(); // padding ×3
    r.u8();
    r.u8();
    return f;
  }
}

/// 大端字节读取游标。
class ByteReader {
  ByteReader(this.data, [this.offset = 0]);
  final Uint8List data;
  int offset;

  int get remaining => data.length - offset;

  int u8() => data[offset++];

  int u16() {
    final v = (data[offset] << 8) | data[offset + 1];
    offset += 2;
    return v;
  }

  int u32() {
    final v = (data[offset] << 24) | (data[offset + 1] << 16) | (data[offset + 2] << 8) | data[offset + 3];
    offset += 4;
    return v;
  }

  Uint8List bytes(int n) {
    final r = Uint8List.sublistView(data, offset, offset + n);
    offset += n;
    return r;
  }

  String latinString(int n) => String.fromCharCodes(bytes(n));
}

/// 小端/大端可写的字节收集器。
class BytesSink {
  final b = BytesBuilder(copy: false);

  void u8(int v) => b.addByte(v & 0xFF);

  void u16(int v) => b
    ..addByte((v >> 8) & 0xFF)
    ..addByte(v & 0xFF);

  void u32(int v) => b
    ..addByte((v >> 24) & 0xFF)
    ..addByte((v >> 16) & 0xFF)
    ..addByte((v >> 8) & 0xFF)
    ..addByte(v & 0xFF);

  void raw(List<int> bytes) => b.add(bytes);

  void latinString(String s) => raw(s.codeUnits);

  Uint8List take() => b.takeBytes();
}

/// 把服务端像素值（按请求的 32bpp 格式，wire 为小端）转换为 RGBA8888。
///
/// 我们协商的像素格式固定为 r16/g8/b0 (RGBA)，大多数情况下像素值
/// 可直接 4 字节拷贝；此函数用于非标准格式回退。
void convertPixelToRgba(
  Uint8List src,
  int srcOffset,
  Uint8List dst,
  int dstOffset,
  PixelFormat f,
) {
  final bpp = f.bytesPerPixel;
  int pixel;
  if (bpp == 4) {
    pixel = f.bigEndian
        ? (src[srcOffset] << 24) | (src[srcOffset + 1] << 16) | (src[srcOffset + 2] << 8) | src[srcOffset + 3]
        : Uint8List.sublistView(src, srcOffset, srcOffset + 4).buffer.asByteData().getUint32(0, Endian.little);
  } else if (bpp == 2) {
    pixel = f.bigEndian
        ? (src[srcOffset] << 8) | src[srcOffset + 1]
        : (src[srcOffset + 1] << 8) | src[srcOffset];
  } else if (bpp == 1) {
    pixel = src[srcOffset];
  } else {
    throw UnsupportedError('bpp=$bpp');
  }
  final r = ((pixel >> f.redShift) & f.redMax) * 255 ~/ f.redMax;
  final g = ((pixel >> f.greenShift) & f.greenMax) * 255 ~/ f.greenMax;
  final bl = ((pixel >> f.blueShift) & f.blueMax) * 255 ~/ f.blueMax;
  dst[dstOffset] = r;
  dst[dstOffset + 1] = g;
  dst[dstOffset + 2] = bl;
  dst[dstOffset + 3] = 255;
}
