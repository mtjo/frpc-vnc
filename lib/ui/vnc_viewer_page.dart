import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/vnc/keysyms.dart';
import '../services/vnc/rfb/connection.dart';
import '../services/vnc/vnc_session.dart';
import 'widgets/file_transfer_sheet.dart';

/// VNC 查看器。
///
/// - 单指拖动 = 鼠标移动，单击 = 左键点击，长按拖动 = 按住左键拖动
/// - 双指捏合缩放 / 双指拖动平移
/// - 工具栏：修饰键、软键盘、剪贴板、文件传输、全屏刷新、断开
class VncViewerPage extends StatefulWidget {
  const VncViewerPage({
    super.key,
    required this.host,
    required this.port,
    this.username,
    this.password,
    this.tlsVerify = false,
    required this.title,
  });

  final String host;
  final int port;
  final String? username;
  final String? password;
  final bool tlsVerify;
  final String title;

  @override
  State<VncViewerPage> createState() => _VncViewerPageState();
}

class _VncViewerPageState extends State<VncViewerPage> {
  VncSession? _session;
  ui.Image? _image;
  int _fbWidth = 0;
  int _fbHeight = 0;

  String? _connectingError;
  bool _connecting = true;
  String _statusText = '连接中…';

  // 修饰键状态（粘滞切换）。
  final Set<int> _activeModifiers = {};

  // 鼠标按钮状态。
  int _buttonMask = 0;

  final TransformationController _transform = TransformationController();
  StreamSubscription? _evSub;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    _evSub?.cancel();
    _session?.close();
    _transform.dispose();
    _image?.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    try {
      final session = await VncSession.connect(VncOptions(
        host: widget.host,
        port: widget.port,
        username: widget.username,
        password: widget.password,
        tlsVerify: widget.tlsVerify,
      ));
      if (!mounted) {
        session.close();
        return;
      }
      _session = session;
      _statusText = '已连接 ${session.desktopName ?? ''}';
      _evSub = session.events.listen(_onEvent);
      _checkFrame();
    } catch (e) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _connectingError = e.toString();
        });
      }
    }
  }

  void _onEvent(Map<String, Object?> ev) {
    switch (ev['ev']) {
      case 'ready':
        setState(() {
          _statusText = '已连接 ${ev['name'] ?? ''}';
        });
        _checkFrame();
      case 'fb':
        _checkFrame();
      case 'clipboard':
        final text = ev['text'] as String? ?? '';
        Clipboard.setData(ClipboardData(text: text));
        if (mounted && text.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('收到远端剪贴板内容'), duration: Duration(seconds: 1)),
          );
        }
      case 'closed':
        if (mounted) {
          setState(() {
            _connecting = false;
            _connectingError = '连接已关闭：${ev['reason'] ?? ''}';
          });
        }
      case 'error':
        if (mounted) {
          setState(() {
            _connecting = false;
            _connectingError = ev['message'] as String?;
          });
        }
    }
  }

  /// 检查新帧并异步转换为 ui.Image。
  Future<void> _checkFrame() async {
    final session = _session;
    if (session == null) return;
    final frame = session.latestFrame;
    if (frame == null || session.width == 0) return;

    final w = session.width;
    final h = session.height;
    try {
      final image = await _decodeFrame(frame, w, h);
      if (!mounted) {
        image.dispose();
        return;
      }
      final old = _image;
      setState(() {
        _image = image;
        _fbWidth = w;
        _fbHeight = h;
        _connecting = false;
      });
      old?.dispose();
    } catch (_) {}
  }

  static Future<ui.Image> _decodeFrame(Uint8List rgba, int w, int h) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      w,
      h,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  // ---- 输入 ----------------------------------------------------------------

  void _sendPointer(double fx, double fy, {int? buttonOverride, bool release = false}) {
    final session = _session;
    if (session == null || _fbWidth == 0) return;
    final x = (fx.clamp(0, _fbWidth.toDouble())).toInt();
    final y = (fy.clamp(0, _fbHeight.toDouble())).toInt();
    var mask = _buttonMask;
    if (buttonOverride != null) {
      mask = buttonOverride;
    }
    if (release) mask = 0;
    session.sendPointer(x, y, mask);
  }

  /// 由屏幕坐标换算 framebuffer 坐标。
  (double, double) _toFb(Offset local, Size viewSize) {
    if (_fbWidth == 0 || _fbHeight == 0) return (0, 0);
    final scale = _fitScale(viewSize);
    final ox = (viewSize.width - _fbWidth * scale) / 2;
    final oy = (viewSize.height - _fbHeight * scale) / 2;
    return ((local.dx - ox) / scale, (local.dy - oy) / scale);
  }

  double _fitScale(Size viewSize) {
    if (_fbWidth == 0 || _fbHeight == 0) return 1;
    return (viewSize.width / _fbWidth).clamp(0.0, viewSize.height / _fbHeight);
  }

  void _sendKeysym(int keysym, bool down) {
    _session?.sendKey(keysym, down: down);
  }

  void _toggleModifier(int keysym) {
    setState(() {
      if (_activeModifiers.contains(keysym)) {
        _activeModifiers.remove(keysym);
        _sendKeysym(keysym, false);
      } else {
        _activeModifiers.add(keysym);
        _sendKeysym(keysym, true);
      }
    });
  }

  void _sendSpecialKey(_SpecialKey k) {
    switch (k) {
      case _SpecialKey.escape:
        _sendKeysym(Keysyms.escape, true);
        _sendKeysym(Keysyms.escape, false);
      case _SpecialKey.tab:
        _sendKeysym(Keysyms.tab, true);
        _sendKeysym(Keysyms.tab, false);
      case _SpecialKey.ctrlAltDel:
        _sendKeysym(Keysyms.controlL, true);
        _sendKeysym(Keysyms.altL, true);
        _sendKeysym(Keysyms.delete, true);
        _sendKeysym(Keysyms.delete, false);
        _sendKeysym(Keysyms.altL, false);
        _sendKeysym(Keysyms.controlL, false);
    }
  }

  void _sendText(String text) {
    final session = _session;
    if (session == null) return;
    for (final ch in text.runes) {
      final keysym = _keysymForRune(ch);
      if (keysym != null) {
        _sendKeysym(keysym, true);
        _sendKeysym(keysym, false);
      }
    }
  }

  int? _keysymForRune(int rune) {
    if (rune >= 0x20 && rune <= 0x7E) return rune;
    if (rune == 0x0A) return Keysyms.enter;
    if (rune == 0x09) return Keysyms.tab;
    // 非 ASCII 字符无法直接映射 keysym，多数服务器忽略。
    return null;
  }

  Future<void> _disconnect() async {
    await _session?.close();
    if (mounted) Navigator.of(context).pop();
  }

  // ---- UI ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black54,
        foregroundColor: Colors.white,
        title: Text('${widget.title} · $_statusText', style: const TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            icon: const Icon(Icons.keyboard_alt_outlined),
            tooltip: '键盘',
            onPressed: _showKeyboardPanel,
          ),
          IconButton(
            icon: const Icon(Icons.content_paste),
            tooltip: '剪贴板',
            onPressed: _showClipboardPanel,
          ),
          IconButton(
            icon: const Icon(Icons.folder_copy_outlined),
            tooltip: '文件传输',
            onPressed: _showFileTransfer,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '全量刷新',
            onPressed: () => _session?.requestFullRefresh(),
          ),
          IconButton(
            icon: const Icon(Icons.link_off),
            tooltip: '断开',
            onPressed: _disconnect,
          ),
        ],
      ),
      body: _connecting
          ? const Center(child: CircularProgressIndicator())
          : _connectingError != null
              ? _buildError()
              : _buildViewer(),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 56, color: Colors.redAccent),
            const SizedBox(height: 16),
            Text(
              _connectingError ?? '未知错误',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('返回')),
          ],
        ),
      ),
    );
  }

  Widget _buildViewer() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) {
            final (fx, fy) = _toFb(d.localPosition, constraints.biggest);
            _sendPointer(fx, fy, buttonOverride: 1);
            Future<void>.delayed(const Duration(milliseconds: 60),
                () => _sendPointer(fx, fy, release: true));
          },
          onLongPressStart: (d) {
            final (fx, fy) = _toFb(d.localPosition, constraints.biggest);
            _buttonMask = 1;
            _sendPointer(fx, fy, buttonOverride: 1);
          },
          onLongPressMoveUpdate: (d) {
            final (fx, fy) = _toFb(d.localPosition, constraints.biggest);
            _sendPointer(fx, fy);
          },
          onLongPressEnd: (d) {
            _buttonMask = 0;
            final (fx, fy) = _toFb(d.localPosition, constraints.biggest);
            _sendPointer(fx, fy, release: true);
          },
          onDoubleTapDown: (d) {
            final (fx, fy) = _toFb(d.localPosition, constraints.biggest);
            // 双击 = 快速两次左键。
            _sendPointer(fx, fy, buttonOverride: 1);
            Future<void>.delayed(const Duration(milliseconds: 40),
                () => _sendPointer(fx, fy, release: true));
            Future<void>.delayed(const Duration(milliseconds: 120), () {
              _sendPointer(fx, fy, buttonOverride: 1);
              Future<void>.delayed(const Duration(milliseconds: 60),
                  () => _sendPointer(fx, fy, release: true));
            });
          },
          // 右键：双指轻点。
          onSecondaryTapUp: _fbWidth == 0
              ? null
              : (d) {
                  final (fx, fy) = _toFb(d.localPosition, constraints.biggest);
                  _sendPointer(fx, fy, buttonOverride: 4);
                  Future<void>.delayed(const Duration(milliseconds: 60),
                      () => _sendPointer(fx, fy, release: true));
                },
          child: InteractiveViewer(
            transformationController: _transform,
            maxScale: 8,
            panEnabled: true,
            scaleEnabled: true,
            child: Center(
              child: _image == null
                  ? const Text('等待画面…', style: TextStyle(color: Colors.white54))
                  : RawImage(
                      image: _image,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.low,
                    ),
            ),
          ),
        );
      },
    );
  }

  // ---- 面板 ----------------------------------------------------------------

  void _showKeyboardPanel() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => _KeyboardPanel(
        activeModifiers: _activeModifiers,
        onToggleModifier: _toggleModifier,
        onSendText: (t) {
          Navigator.pop(ctx);
          _sendText(t);
        },
        onSpecialKey: (k) {
          Navigator.pop(ctx);
          _sendSpecialKey(k);
        },
      ),
    );
  }

  void _showClipboardPanel() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => _ClipboardPanel(
        onSend: (text) {
          _session?.sendCutText(text);
          Navigator.pop(ctx);
        },
      ),
    );
  }

  void _showFileTransfer() {
    final session = _session;
    if (session == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => FileTransferSheet(session: session),
    );
  }
}

enum _SpecialKey { escape, tab, ctrlAltDel }

// ---------------------------------------------------------------------------
// 键盘面板
// ---------------------------------------------------------------------------

class _KeyboardPanel extends StatelessWidget {
  _KeyboardPanel({
    required this.activeModifiers,
    required this.onToggleModifier,
    required this.onSendText,
    required this.onSpecialKey,
  });

  final Set<int> activeModifiers;
  final void Function(int) onToggleModifier;
  final void Function(String) onSendText;
  final void Function(_SpecialKey) onSpecialKey;

  final _textCtrl = TextEditingController();

  @override
  Widget build(BuildContext context) {
    Widget modBtn(String label, int keysym) {
      final active = activeModifiers.contains(keysym);
      return Padding(
        padding: const EdgeInsets.all(4),
        child: FilledButton.tonal(
          style: FilledButton.styleFrom(
            backgroundColor: active ? Theme.of(context).colorScheme.primary : null,
            foregroundColor: active ? Colors.white : null,
            minimumSize: const Size(64, 48),
          ),
          onPressed: () => onToggleModifier(keysym),
          child: Text(label),
        ),
      );
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              children: [
                modBtn('Ctrl', Keysyms.controlL),
                modBtn('Alt', Keysyms.altL),
                modBtn('Win', Keysyms.metaL),
                modBtn('Shift', Keysyms.shiftL),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textCtrl,
                    decoration: const InputDecoration(
                      labelText: '输入并发送到远端（回车=Enter）',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: onSendText,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => onSendText(_textCtrl.text),
                  child: const Text('发送'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () => onSpecialKey(_SpecialKey.escape),
                  child: const Text('Esc'),
                ),
                OutlinedButton(
                  onPressed: () => onSpecialKey(_SpecialKey.tab),
                  child: const Text('Tab'),
                ),
                OutlinedButton(
                  onPressed: () => onSpecialKey(_SpecialKey.ctrlAltDel),
                  child: const Text('Ctrl+Alt+Del'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 剪贴板面板
// ---------------------------------------------------------------------------

class _ClipboardPanel extends StatefulWidget {
  const _ClipboardPanel({required this.onSend});

  final void Function(String) onSend;

  @override
  State<_ClipboardPanel> createState() => _ClipboardPanelState();
}

class _ClipboardPanelState extends State<_ClipboardPanel> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _ctrl,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: '发送到远端剪贴板',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      final data = await Clipboard.getData(Clipboard.kTextPlain);
                      if (data?.text != null) {
                        setState(() => _ctrl.text = data!.text!);
                      }
                    },
                    child: const Text('读取本地剪贴板'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: () => widget.onSend(_ctrl.text),
                    child: const Text('发送到远端'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
