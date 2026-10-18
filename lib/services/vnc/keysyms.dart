library;

import 'package:flutter/services.dart';

/// X11 keysym 常量与 Flutter LogicalKeyboardKey → keysym 映射。

/// 常用 X11 keysym（RFB 协议使用）。
class Keysyms {
  // 可打印 ASCII：0x20-0x7E 直接映射。
  static int fromAscii(int charCode) => charCode;

  static const int backSpace = 0xFF08;
  static const int tab = 0xFF09;
  static const int enter = 0xFF0D;
  static const int escape = 0xFF1B;
  static const int home = 0xFF50;
  static const int left = 0xFF51;
  static const int up = 0xFF52;
  static const int right = 0xFF53;
  static const int down = 0xFF54;
  static const int pageUp = 0xFF55;
  static const int pageDown = 0xFF56;
  static const int end = 0xFF57;
  static const int insert = 0xFF63;
  static const int f1 = 0xFFBE;
  static const int f2 = 0xFFBF;
  static const int f3 = 0xFFC0;
  static const int f4 = 0xFFC1;
  static const int f5 = 0xFFC2;
  static const int f6 = 0xFFC3;
  static const int f7 = 0xFFC4;
  static const int f8 = 0xFFC5;
  static const int f9 = 0xFFC6;
  static const int f10 = 0xFFC7;
  static const int f11 = 0xFFC8;
  static const int f12 = 0xFFC9;
  static const int shiftL = 0xFFE1;
  static const int shiftR = 0xFFE2;
  static const int controlL = 0xFFE3;
  static const int controlR = 0xFFE4;
  static const int metaL = 0xFFE7; // Super/Win/Command
  static const int metaR = 0xFFE8;
  static const int altL = 0xFFE9;
  static const int altR = 0xFFEA;
  static const int delete = 0xFFFF;
  static const int capsLock = 0xFFE5;
  static const int space = 0x0020;

  /// flutter/services LogicalKeyboardKey.keyLabel 或 keyId → keysym。
  static int? fromLogical(int flutterKeyId, String label) {
    // Function-key / modifier 等 keyId 直接内嵌 X keysym：
    // Flutter 的 keyId 对大多数键为 Unicode 值；控制键另有 0x1 00000000 平面。
    final labelMap = _labelToKeysym[label];
    if (labelMap != null) return labelMap;
    if (label.length == 1) {
      final c = label.toUpperCase().codeUnitAt(0);
      if (c >= 0x20 && c <= 0x7E) return c;
    }
    return null;
  }

  static const Map<String, int> _labelToKeysym = {
    'Backspace': backSpace,
    'Tab': tab,
    'Enter': enter,
    'Escape': escape,
    'Home': home,
    'Arrow Left': left,
    'Arrow Up': up,
    'Arrow Right': right,
    'Arrow Down': down,
    'Page Up': pageUp,
    'Page Down': pageDown,
    'End': end,
    'Insert': insert,
    'Delete': delete,
    'F1': f1,
    'F2': f2,
    'F3': f3,
    'F4': f4,
    'F5': f5,
    'F6': f6,
    'F7': f7,
    'F8': f8,
    'F9': f9,
    'F10': f10,
    'F11': f11,
    'F12': f12,
    'Shift Left': shiftL,
    'Shift Right': shiftR,
    'Control Left': controlL,
    'Control Right': controlR,
    'Meta Left': metaL,
    'Meta Right': metaR,
    'Alt Left': altL,
    'Alt Right': altR,
    'Caps Lock': capsLock,
    'Space Bar': space,
    ' ': space,
  };

  /// 将 Flutter 按键事件映射为 keysym。
  ///
  /// 优先使用 event.character（含 Shift 产生的实际字符），否则按
  /// keyLabel 查表，最后回退到 keyId（可打印 ASCII 与 unicode 一致）。
  static int? fromKeyEvent(KeyEvent event) {
    final key = event.logicalKey;
    final character = event.character;
    if (character != null && character.isNotEmpty) {
      final rune = character.runes.first;
      if (rune >= 0x20 && rune <= 0x7E) return rune;
    }
    final mapped = _labelToKeysym[key.keyLabel];
    if (mapped != null) return mapped;
    // 修饰键等无字符按键：按 keyId 匹配常见控制键。
    switch (key) {
      case LogicalKeyboardKey.shiftLeft:
        return shiftL;
      case LogicalKeyboardKey.shiftRight:
        return shiftR;
      case LogicalKeyboardKey.controlLeft:
        return controlL;
      case LogicalKeyboardKey.controlRight:
        return controlR;
      case LogicalKeyboardKey.altLeft:
        return altL;
      case LogicalKeyboardKey.altRight:
        return altR;
      case LogicalKeyboardKey.metaLeft:
        return metaL;
      case LogicalKeyboardKey.metaRight:
        return metaR;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        return enter;
      case LogicalKeyboardKey.backspace:
        return backSpace;
      case LogicalKeyboardKey.escape:
        return escape;
      case LogicalKeyboardKey.tab:
        return tab;
      case LogicalKeyboardKey.delete:
        return delete;
      case LogicalKeyboardKey.arrowLeft:
        return left;
      case LogicalKeyboardKey.arrowRight:
        return right;
      case LogicalKeyboardKey.arrowUp:
        return up;
      case LogicalKeyboardKey.arrowDown:
        return down;
      case LogicalKeyboardKey.home:
        return home;
      case LogicalKeyboardKey.end:
        return end;
      case LogicalKeyboardKey.pageUp:
        return pageUp;
      case LogicalKeyboardKey.pageDown:
        return pageDown;
      case LogicalKeyboardKey.f1:
        return f1;
      case LogicalKeyboardKey.f2:
        return f2;
      case LogicalKeyboardKey.f3:
        return f3;
      case LogicalKeyboardKey.f4:
        return f4;
      case LogicalKeyboardKey.f5:
        return f5;
      case LogicalKeyboardKey.f6:
        return f6;
      case LogicalKeyboardKey.f7:
        return f7;
      case LogicalKeyboardKey.f8:
        return f8;
      case LogicalKeyboardKey.f9:
        return f9;
      case LogicalKeyboardKey.f10:
        return f10;
      case LogicalKeyboardKey.f11:
        return f11;
      case LogicalKeyboardKey.f12:
        return f12;
      case LogicalKeyboardKey.capsLock:
        return capsLock;
    }
    // 可打印 ASCII：Flutter 的 keyId 即小写字符的 unicode。
    final id = key.keyId;
    if (id >= 0x20 && id <= 0x7E) return id;
    return null;
  }
}
