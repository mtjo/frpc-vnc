library;

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
}
