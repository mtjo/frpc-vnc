library;

/// FBU 矩形解码器：Raw / CopyRect / Hextile / Zlib。
///
/// 所有解码器输出 RGBA8888 像素并直接写入 framebuffer（强制不透明）。
/// 前提：客户端协商的像素格式为 32bpp RGBA（wire 小端），此时
/// 服务端发送的像素值即为 RGBA 字节序，可按字节直接使用。
///
/// 网络读取为异步（[AsyncByteReader]），解码器内部逐段 await。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'protocol.dart';

/// 从底层流异步精确读取 n 字节（带内部缓冲）。
class AsyncByteReader {
  AsyncByteReader(this._stream);

  final Stream<Uint8List> _stream;
  StreamIterator<Uint8List>? _it;

  Uint8List _buf = Uint8List(64 * 1024);
  int _start = 0;
  int _end = 0;
  bool _eof = false;

  /// 取消底层流订阅（连接销毁时调用，避免悬挂的错误无人处理）。
  Future<void> cancel() async {
    final it = _it;
    _it = null;
    _eof = true;
    if (it != null) {
      try {
        await it.cancel();
      } catch (_) {}
    }
  }

  Future<Uint8List> read(int n) async {
    if (n < 0) throw ArgumentError('read($n)');
    // 确保缓冲容量。
    final needed = _end - _start + n;
    if (needed > _buf.length) {
      var cap = _buf.length;
      while (cap < needed) {
        cap *= 2;
      }
      final nb = Uint8List(cap);
      nb.setRange(0, _end - _start, _buf, _start);
      _buf = nb;
      _end -= _start;
      _start = 0;
    }
    while (_end - _start < n) {
      if (_eof) {
        throw const VncConnectionClosed('连接已关闭（数据不足）');
      }
      _it ??= StreamIterator(_stream);
      Uint8List? chunk;
      try {
        final has = await _it!.moveNext();
        chunk = has ? _it!.current : null;
      } catch (e) {
        _eof = true;
        throw VncConnectionClosed('读取失败：$e');
      }
      if (chunk == null || chunk.isEmpty) {
        _eof = true;
        if (_end - _start >= n) break;
        throw const VncConnectionClosed('连接已关闭（数据不足）');
      }
      // 追加（必要时先压缩空隙）。
      if (_end + chunk.length > _buf.length) {
        // 已在上面保证容量足够容纳现有数据 + n，这里只需整理。
        final remaining = _end - _start;
        _buf.setRange(0, remaining, _buf, _start);
        _start = 0;
        _end = remaining;
      }
      _buf.setRange(_end, _end + chunk.length, chunk);
      _end += chunk.length;
    }
    final out = Uint8List(n);
    out.setRange(0, n, _buf, _start);
    _start += n;
    if (_start == _end) {
      _start = _end = 0;
    }
    return out;
  }
}

class VncConnectionClosed implements Exception {
  const VncConnectionClosed(this.message);
  final String message;

  @override
  String toString() => message;
}

/// framebuffer 状态（矩形解码目标）。
class Framebuffer {
  Framebuffer(this.width, this.height) : pixels = Uint8List(width * height * 4);

  int width;
  int height;
  Uint8List pixels; // RGBA8888

  void resize(int w, int h) {
    width = w;
    height = h;
    pixels = Uint8List(w * h * 4);
  }
}

class Rect {
  Rect(this.x, this.y, this.w, this.h);
  final int x;
  final int y;
  final int w;
  final int h;
}

Future<void> decodeRaw(Rect rect, Framebuffer fb, AsyncByteReader r) async {
  final bytes = await r.read(rect.w * rect.h * 4);
  _blitRgba(bytes, 0, rect, fb);
}

/// 将 RGBA 数据按矩形行拷贝进 framebuffer，并强制 alpha=255
/// （depth 24 时线上第 4 字节未定义）。
void _blitRgba(Uint8List src, int srcOffset, Rect rect, Framebuffer fb) {
  final rowBytes = rect.w * 4;
  for (var row = 0; row < rect.h; row++) {
    final dstStart = ((rect.y + row) * fb.width + rect.x) * 4;
    final srcStart = srcOffset + row * rowBytes;
    fb.pixels.setRange(dstStart, dstStart + rowBytes, src, srcStart);
    for (var i = dstStart + 3; i < dstStart + rowBytes; i += 4) {
      fb.pixels[i] = 255;
    }
  }
}

Future<void> decodeCopyRect(Rect rect, Framebuffer fb, AsyncByteReader r) async {
  final head = ByteReader(await r.read(4));
  final srcX = head.u16();
  final srcY = head.u16();
  final rowBytes = rect.w * 4;
  // 同向移动自底向上拷贝以处理重叠区域。
  final downward = srcY <= rect.y;
  if (downward) {
    for (var row = rect.h - 1; row >= 0; row--) {
      final dstStart = ((rect.y + row) * fb.width + rect.x) * 4;
      final srcStart = ((srcY + row) * fb.width + srcX) * 4;
      if (srcStart < dstStart && srcStart + rowBytes > dstStart) {
        for (var i = rowBytes - 1; i >= 0; i--) {
          fb.pixels[dstStart + i] = fb.pixels[srcStart + i];
        }
      } else {
        fb.pixels.setRange(dstStart, dstStart + rowBytes, fb.pixels, srcStart);
      }
    }
  } else {
    for (var row = 0; row < rect.h; row++) {
      final dstStart = ((rect.y + row) * fb.width + rect.x) * 4;
      final srcStart = ((srcY + row) * fb.width + srcX) * 4;
      fb.pixels.setRange(dstStart, dstStart + rowBytes, fb.pixels, srcStart);
    }
  }
}

Future<void> decodeHextile(Rect rect, Framebuffer fb, AsyncByteReader r) async {
  const bpp = 4;
  final bg = Uint8List(bpp);
  final fg = Uint8List(bpp);
  final tile = Uint8List(16 * 16 * bpp);

  for (var ty = 0; ty < rect.h; ty += 16) {
    for (var tx = 0; tx < rect.w; tx += 16) {
      final tw = (rect.w - tx).clamp(1, 16);
      final th = (rect.h - ty).clamp(1, 16);

      // 透明黑初始化（含 padding 区域），alpha 全部置 255。
      tile.fillRange(0, tile.length, 0);
      for (var i = 3; i < tile.length; i += 4) {
        tile[i] = 255;
      }

      final mask = (await r.read(1))[0];
      if (mask & hexRaw != 0) {
        final raw = await r.read(tw * th * bpp);
        for (var y = 0; y < th; y++) {
          tile.setRange(y * 16 * bpp, y * 16 * bpp + tw * bpp, raw, y * tw * bpp);
        }
        for (var y = 0; y < th; y++) {
          for (var x = 0; x < tw; x++) {
            tile[(y * 16 + x) * bpp + 3] = 255;
          }
        }
      } else {
        if (mask & hexBackgroundSpecified != 0) {
          bg.setAll(0, await r.read(bpp));
          bg[3] = 255;
        }
        for (var i = 0; i < 256; i++) {
          tile.setRange(i * bpp, i * bpp + bpp, bg);
        }
        if (mask & hexForegroundSpecified != 0) {
          fg.setAll(0, await r.read(bpp));
          fg[3] = 255;
        }
        if (mask & hexAnySubrects != 0) {
          final count = (await r.read(1))[0];
          for (var s = 0; s < count; s++) {
            var color = fg;
            if (mask & hexSubrectsColoured != 0) {
              color = await r.read(bpp);
              color[3] = 255;
            }
            final head = ByteReader(await r.read(4));
            final sx = head.u8();
            final sy = head.u8();
            final sw = head.u8();
            final sh = head.u8();
            for (var y = sy; y < sy + sh; y++) {
              for (var x = sx; x < sx + sw; x++) {
                if (x < tw && y < th) {
                  final o = (y * 16 + x) * bpp;
                  tile.setRange(o, o + bpp, color);
                }
              }
            }
          }
        }
      }
      // 拷贝 tile 到 fb。
      for (var y = 0; y < th; y++) {
        final dstStart = ((rect.y + ty + y) * fb.width + rect.x + tx) * 4;
        fb.pixels.setRange(dstStart, dstStart + tw * bpp, tile, y * 16 * bpp);
      }
    }
  }
}

Future<void> decodeZlib(Rect rect, Framebuffer fb, AsyncByteReader r) async {
  final head = ByteReader(await r.read(4));
  final compressedLen = head.u32();
  final compressed = await r.read(compressedLen);
  final inflated = Uint8List.fromList(ZLibCodec().decoder.convert(compressed));
  _blitRgba(inflated, 0, rect, fb);
}
