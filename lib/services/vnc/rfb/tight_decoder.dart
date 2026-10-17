library;

/// Tight 编码解码器（与 TigerVNC TightDecoder 逻辑一致）。
///
/// 控制字节布局：
/// - bits 0-3：对应 zlib 流 0-3 的重置标志（bit i 置位则重置流 i）
/// - bits 4-7：压缩类型——0x00~0x03 = zlib 压缩（流号 = 类型值）、
///   0x08 = 纯色填充、0x09 = JPEG、含 0x04 位 = 基本压缩 + 显式过滤器
/// - 长度采用紧凑编码（1 字节或 3 字节，TigerVNC writeCompact 格式）
/// - 数据 < 12 字节时不压缩，直接传输
///
/// 仅支持 32bpp / depth 24 真彩色客户端格式（本客户端固定协商），
/// 此模式下 Tight 使用 3 字节/像素 RGB。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'decoders.dart';
import 'dart:async';

const int _typeFill = 0x08;
const int _typeJpeg = 0x09;
const int _typeExplicitFilter = 0x04;
const int _maxSubencoding = 0x09;

const int _filterCopy = 0x00;
const int _filterPalette = 0x01;
const int _filterGradient = 0x02;

const int _minToCompress = 12;
const int _maxWidth = 2048;

class TightDecoder {
  // Tight 的 4 个独立 zlib 流，跨矩形持续有效。
  final List<_TightZlibStream?> _streams = List.filled(4, null);

  void _resetStream(int i) {
    _streams[i]?.close();
    _streams[i] = null;
  }

  void dispose() {
    for (var i = 0; i < 4; i++) {
      _resetStream(i);
    }
  }

  Future<void> decode(Rect rect, Framebuffer fb, AsyncByteReader r) async {
    if (rect.w > _maxWidth) {
      throw UnsupportedError('Tight 矩形宽度过大：${rect.w}');
    }

    var ctrl = (await r.read(1))[0];

    // bits 0-3：逐流重置标志。
    for (var i = 0; i < 4; i++) {
      if (ctrl & 1 != 0) _resetStream(i);
      ctrl >>= 1;
    }
    // ctrl 现在为高 4 位类型。
    final type = ctrl;

    if (type == _typeFill) {
      final c = await r.read(3);
      _fillRect(rect, fb, c[0], c[1], c[2]);
      return;
    }

    if (type == _typeJpeg) {
      final len = await _readCompact(r);
      final jpeg = await r.read(len);
      _decodeJpeg(rect, fb, jpeg);
      return;
    }

    if (type > _maxSubencoding) {
      throw UnsupportedError('不支持的 Tight 压缩类型 0x${type.toRadixString(16)}');
    }

    // 基本压缩。
    var palSize = 0;
    var filter = _filterCopy;
    List<int>? palette;

    if (type & _typeExplicitFilter != 0) {
      filter = (await r.read(1))[0];
      switch (filter) {
        case _filterPalette:
          palSize = (await r.read(1))[0] + 1;
          final palBytes = await r.read(palSize * 3);
          palette = List<int>.generate(
              palSize,
              (i) => (palBytes[i * 3] << 16) |
                  (palBytes[i * 3 + 1] << 8) |
                  palBytes[i * 3 + 2]);
        case _filterGradient:
        case _filterCopy:
          break;
        default:
          throw UnsupportedError('未知 Tight 过滤器 $filter');
      }
    }

    // 行大小与总数据量。
    final int rowSize;
    if (palSize != 0) {
      rowSize = palSize <= 2 ? (rect.w + 7) >> 3 : rect.w;
    } else {
      rowSize = rect.w * 3;
    }
    final dataSize = rect.h * rowSize;

    final Uint8List data;
    if (dataSize < _minToCompress) {
      data = await r.read(dataSize);
    } else {
      final len = await _readCompact(r);
      data = _decompress(type & 0x03, await r.read(len));
    }

    switch (filter) {
      case _filterCopy:
        _blitRgb(data, rect, fb);
      case _filterPalette:
        if (palSize <= 2) {
          _blitPalette1bpp(data, rect, fb, palette!);
        } else {
          _blitPalette8bpp(data, rect, fb, palette!);
        }
      case _filterGradient:
        _blitGradient(data, rect, fb);
    }
  }

  Uint8List _decompress(int streamId, Uint8List compressed) {
    if (streamId > 3) throw UnsupportedError('非法 Tight 流号 $streamId');
    _streams[streamId] ??= _TightZlibStream();
    return _streams[streamId]!.decompress(compressed);
  }

  void _fillRect(Rect rect, Framebuffer fb, int r, int g, int b) {
    for (var y = 0; y < rect.h; y++) {
      var off = ((rect.y + y) * fb.width + rect.x) * 4;
      for (var x = 0; x < rect.w; x++) {
        fb.pixels[off] = r;
        fb.pixels[off + 1] = g;
        fb.pixels[off + 2] = b;
        fb.pixels[off + 3] = 255;
        off += 4;
      }
    }
  }

  void _blitRgb(Uint8List data, Rect rect, Framebuffer fb) {
    var src = 0;
    for (var y = 0; y < rect.h; y++) {
      var dst = ((rect.y + y) * fb.width + rect.x) * 4;
      for (var x = 0; x < rect.w; x++) {
        fb.pixels[dst] = data[src];
        fb.pixels[dst + 1] = data[src + 1];
        fb.pixels[dst + 2] = data[src + 2];
        fb.pixels[dst + 3] = 255;
        src += 3;
        dst += 4;
      }
    }
  }

  void _blitPalette1bpp(Uint8List packed, Rect rect, Framebuffer fb, List<int> palette) {
    final rowBytes = (rect.w + 7) >> 3;
    for (var y = 0; y < rect.h; y++) {
      var dst = ((rect.y + y) * fb.width + rect.x) * 4;
      for (var x = 0; x < rect.w; x++) {
        final bit = (packed[y * rowBytes + (x >> 3)] >> (7 - (x & 7))) & 1;
        final c = palette[bit];
        fb.pixels[dst] = (c >> 16) & 0xFF;
        fb.pixels[dst + 1] = (c >> 8) & 0xFF;
        fb.pixels[dst + 2] = c & 0xFF;
        fb.pixels[dst + 3] = 255;
        dst += 4;
      }
    }
  }

  void _blitPalette8bpp(Uint8List indexed, Rect rect, Framebuffer fb, List<int> palette) {
    var src = 0;
    for (var y = 0; y < rect.h; y++) {
      var dst = ((rect.y + y) * fb.width + rect.x) * 4;
      for (var x = 0; x < rect.w; x++) {
        final c = palette[indexed[src++]];
        fb.pixels[dst] = (c >> 16) & 0xFF;
        fb.pixels[dst + 1] = (c >> 8) & 0xFF;
        fb.pixels[dst + 2] = c & 0xFF;
        fb.pixels[dst + 3] = 255;
        dst += 4;
      }
    }
  }

  /// 24 位梯度过滤解码（每像素 3 字节差分 → RGB）。
  void _blitGradient(Uint8List diffs, Rect rect, Framebuffer fb) {
    final w = rect.w;
    final prev = List<int>.filled(w * 3, 0);
    final cur = List<int>.filled(w * 3, 0);
    var d = 0;
    for (var y = 0; y < rect.h; y++) {
      for (var x = 0; x < w; x++) {
        for (var c = 0; c < 3; c++) {
          final left = x > 0 ? cur[(x - 1) * 3 + c] : 0;
          final upper = y > 0 ? prev[x * 3 + c] : 0;
          final upperLeft = (x > 0 && y > 0) ? prev[(x - 1) * 3 + c] : 0;
          var predict = left + upper - upperLeft;
          if (predict < 0) predict = 0;
          if (predict > 255) predict = 255;
          final b = diffs[d++];
          final delta = b < 128 ? b : b - 256;
          cur[x * 3 + c] = (predict + delta) & 0xFF;
        }
      }
      // 写入本行。
      var dst = ((rect.y + y) * fb.width + rect.x) * 4;
      var src = 0;
      for (var x = 0; x < w; x++) {
        fb.pixels[dst] = cur[src];
        fb.pixels[dst + 1] = cur[src + 1];
        fb.pixels[dst + 2] = cur[src + 2];
        fb.pixels[dst + 3] = 255;
        src += 3;
        dst += 4;
      }
      prev.setAll(0, cur);
    }
  }

  void _decodeJpeg(Rect rect, Framebuffer fb, Uint8List jpeg) {
    img.Image? image;
    try {
      image = img.decodeJpg(jpeg);
    } catch (_) {
      image = null;
    }
    if (image == null) {
      _fillRect(rect, fb, 128, 128, 128);
      return;
    }
    for (var y = 0; y < rect.h && y < image.height; y++) {
      var off = ((rect.y + y) * fb.width + rect.x) * 4;
      for (var x = 0; x < rect.w && x < image.width; x++) {
        final p = image.getPixel(x, y);
        fb.pixels[off] = p.r.toInt();
        fb.pixels[off + 1] = p.g.toInt();
        fb.pixels[off + 2] = p.b.toInt();
        fb.pixels[off + 3] = 255;
        off += 4;
      }
    }
  }
}

/// 紧凑长度编码（TigerVNC writeCompact）：1 或 3 字节。
Future<int> _readCompact(AsyncByteReader r) async {
  var b = (await r.read(1))[0];
  if (b & 0x80 == 0) return b;
  var value = b & 0x7F;
  b = (await r.read(1))[0];
  value |= (b & 0x7F) << 7;
  if (b & 0x80 == 0) return value;
  b = (await r.read(1))[0];
  return value | (b << 14);
}

/// 持续增量的 zlib 解压流（基于 dart:io chunked conversion）。
class _TightZlibStream {
  final _CollectSink _sink = _CollectSink();
  late final ByteConversionSink _input;

  _TightZlibStream() {
    _input = ZLibDecoder().startChunkedConversion(_sink);
  }

  Uint8List decompress(Uint8List compressed) {
    _input.add(compressed);
    return _sink.take();
  }

  void close() {
    _input.close();
  }
}

class _CollectSink implements Sink<List<int>> {
  final _builder = BytesBuilder(copy: false);

  @override
  void add(List<int> chunk) => _builder.add(chunk);

  @override
  void close() {}

  Uint8List take() => _builder.takeBytes();
}
