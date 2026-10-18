import 'dart:async';
import 'dart:math' as math;
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

  // 硬件键盘直通（桌面端/移动端外接键盘）。
  final FocusNode _keyboardFocus = FocusNode();
  final Map<LogicalKeyboardKey, int> _pressedKeys = {};


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
    _keyboardFocus.dispose();
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

  /// 硬件键盘事件 → RFB 按键事件（直通模式）。
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final session = _session;
    if (session == null || session.state != VncState.connected) {
      return KeyEventResult.ignored;
    }
    final keysym = Keysyms.fromKeyEvent(event);
    if (keysym == null) return KeyEventResult.ignored;

    final down = event is KeyDownEvent || event is KeyRepeatEvent;
    if (down) {
      _pressedKeys[event.logicalKey] = keysym;
      // Ctrl+V：先把本地剪贴板同步到远端再发送 V，实现跨端粘贴。
      if (event.logicalKey == LogicalKeyboardKey.keyV &&
          HardwareKeyboard.instance.isControlPressed) {
        Clipboard.getData(Clipboard.kTextPlain).then((d) {
          final text = d?.text;
          if (text != null && text.isNotEmpty) {
            session.sendCutText(text);
          }
        });
      }
      session.sendKey(keysym, down: true);
    } else {
      _pressedKeys.remove(event.logicalKey);
      session.sendKey(keysym, down: false);
    }
    return KeyEventResult.handled;
  }

  void _sendSpecialKey(_SpecialKey k) {
    switch (k.kind) {
      case _SpecialKind.escape:
        _sendKeysym(Keysyms.escape, true);
        _sendKeysym(Keysyms.escape, false);
      case _SpecialKind.tab:
        _sendKeysym(Keysyms.tab, true);
        _sendKeysym(Keysyms.tab, false);
      case _SpecialKind.enter:
        _sendKeysym(Keysyms.enter, true);
        _sendKeysym(Keysyms.enter, false);
      case _SpecialKind.backSpace:
        _sendKeysym(Keysyms.backSpace, true);
        _sendKeysym(Keysyms.backSpace, false);
      case _SpecialKind.char:
        final code = k.charCode!;
        _sendKeysym(code, true);
        _sendKeysym(code, false);
      case _SpecialKind.ctrlAltDel:
        _sendKeysym(Keysyms.controlL, true);
        _sendKeysym(Keysyms.altL, true);
        _sendKeysym(Keysyms.delete, true);
        _sendKeysym(Keysyms.delete, false);
        _sendKeysym(Keysyms.altL, false);
        _sendKeysym(Keysyms.controlL, false);
    }
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
        return Focus(
          focusNode: _keyboardFocus,
          autofocus: true,
          onKeyEvent: _onKeyEvent,
          child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) {
            _keyboardFocus.requestFocus();
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
                  ? const Text('等待画面…\n（点击画面后即可直接打字）',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54))
                  : RawImage(
                      image: _image,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.low,
                    ),
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
        onSpecialKey: _sendSpecialKey,
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

enum _SpecialKind { escape, tab, ctrlAltDel, enter, backSpace, char }

class _SpecialKey {
  const _SpecialKey._(this.kind, [this.charCode]);

  final _SpecialKind kind;
  final int? charCode;

  static const escape = _SpecialKey._(_SpecialKind.escape);
  static const tab = _SpecialKey._(_SpecialKind.tab);
  static const ctrlAltDel = _SpecialKey._(_SpecialKind.ctrlAltDel);
  static const enter = _SpecialKey._(_SpecialKind.enter);
  static const backSpace = _SpecialKey._(_SpecialKind.backSpace);
  static _SpecialKey char(int code) => _SpecialKey._(_SpecialKind.char, code);
}

// ---------------------------------------------------------------------------
// 键盘面板
// ---------------------------------------------------------------------------

class _KeyboardPanel extends StatefulWidget {
  _KeyboardPanel({
    required this.activeModifiers,
    required this.onToggleModifier,
    required this.onSpecialKey,
  });

  final Set<int> activeModifiers;
  final void Function(int) onToggleModifier;
  final void Function(_SpecialKey) onSpecialKey;

  @override
  State<_KeyboardPanel> createState() => _KeyboardPanelState();
}

class _KeyboardPanelState extends State<_KeyboardPanel> {
  final _textCtrl = TextEditingController();
  String _last = '';

  /// 软键盘实时逐字发送（含退格），与查看器硬件键盘一致。
  void _onChanged(String text) {
    var i = 0;
    final minLen = math.min(_last.length, text.length);
    while (i < minLen && _last[i] == text[i]) {
      i++;
    }
    for (var d = 0; d < _last.length - i; d++) {
      widget.onSpecialKey(_SpecialKey.backSpace);
    }
    for (final rune in text.substring(i).runes) {
      if (rune == 0x0A || rune == 0x0D) {
        widget.onSpecialKey(_SpecialKey.enter);
        continue;
      }
      // 可打印字符直接发送。
      if (rune >= 0x20 && rune <= 0x7E) {
        widget.onSpecialKey(_SpecialKey.char(rune));
      }
    }
    _last = text;
    _textCtrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    Widget modBtn(String label, int keysym) {
      final active = widget.activeModifiers.contains(keysym);
      return Padding(
        padding: const EdgeInsets.all(4),
        child: FilledButton.tonal(
          style: FilledButton.styleFrom(
            backgroundColor: active ? Theme.of(context).colorScheme.primary : null,
            foregroundColor: active ? Colors.white : null,
            minimumSize: const Size(64, 48),
          ),
          onPressed: () => widget.onToggleModifier(keysym),
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
            TextField(
              controller: _textCtrl,
              autofocus: true,
              keyboardType: TextInputType.text,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: '直接打字——输入内容实时发送到远端',
                border: OutlineInputBorder(),
              ),
              onChanged: _onChanged,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () => widget.onSpecialKey(_SpecialKey.escape),
                  child: const Text('Esc'),
                ),
                OutlinedButton(
                  onPressed: () => widget.onSpecialKey(_SpecialKey.tab),
                  child: const Text('Tab'),
                ),
                OutlinedButton(
                  onPressed: () => widget.onSpecialKey(_SpecialKey.ctrlAltDel),
                  child: const Text('Ctrl+Alt+Del'),
                ),
                OutlinedButton(
                  onPressed: () => widget.onSpecialKey(_SpecialKey.enter),
                  child: const Text('回车'),
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
