library;

/// frpc 配置 ↔ TOML 双向转换。
///
/// 解析器覆盖 frpc 配置实际使用的 TOML 子集：注释、`[table]`、
/// `[[array-of-table]]`、点号键、基本/字面字符串（含多行）、整数
/// （含 hex/oct/bin）、浮点、布尔、数组、内联表。日期时间按原始
/// 字符串保留（frpc 配置中不使用）。
///
/// 导出时 `extra` 中的未知字段原样写回，保证导入导出往返无损。

import '../../models/frpc_profile.dart';

class TomlParseException implements Exception {
  TomlParseException(this.message, this.line);
  final String message;
  final int line;

  @override
  String toString() => 'TOML 解析错误（第 $line 行）：$message';
}

// ---------------------------------------------------------------------------
// 导出：Profile → TOML
// ---------------------------------------------------------------------------

String profileToToml(FrpcProfile profile) {
  final buf = StringBuffer();
  _w(buf, '# 由 frpc-vnc 生成\n');
  _w(buf, '# 配置名: ${profile.name}\n\n');

  // 服务端连接配置（根级标量）。
  final s = profile.server;
  if (s.serverAddr.isNotEmpty) _w(buf, 'serverAddr = ${_v(s.serverAddr)}\n');
  _w(buf, 'serverPort = ${s.serverPort}\n');
  if (s.user != null && s.user!.isNotEmpty) _w(buf, 'user = ${_v(s.user!)}\n');

  // auth.* 命名空间。
  final authExtra = <String, dynamic>{
    for (final e in s.extra.entries)
      if (e.key.startsWith('auth.')) e.key.substring(5): e.value,
  };
  if ((s.token != null && s.token!.isNotEmpty) || authExtra.isNotEmpty) {
    _w(buf, '\n[auth]\n');
    if (s.token != null && s.token!.isNotEmpty) _w(buf, 'token = ${_v(s.token!)}\n');
    _writeExtraTable(buf, authExtra, prefix: 'auth', root: false);
  }

  // transport.* 命名空间。
  final transport = <String, dynamic>{};
  if (s.transportProtocol != null && s.transportProtocol!.isNotEmpty) {
    transport['protocol'] = s.transportProtocol;
  }
  if (s.bandwidthLimit != null && s.bandwidthLimit!.isNotEmpty) {
    transport['bandwidthLimit'] = s.bandwidthLimit;
  }
  if (s.tlsEnable || s.tlsDisableCustomVerify != null) {
    final tls = <String, dynamic>{};
    if (s.tlsEnable) tls['enable'] = true;
    if (s.tlsDisableCustomVerify != null) tls['disableCustomVerify'] = s.tlsDisableCustomVerify;
    transport['tls'] = tls;
  }
  final transportExtra = <String, dynamic>{
    for (final e in s.extra.entries)
      if (e.key.startsWith('transport.')) e.key.substring(10): e.value,
  };
  if (transport.isNotEmpty || transportExtra.isNotEmpty) {
    _w(buf, '\n[transport]\n');
    _writeExtraTable(buf, {...transport, ...transportExtra}, prefix: 'transport', root: false);
  }

  // 顶层未建模字段（如 [log]、[webServer]、根级标量）。
  final rootScalars = <String, dynamic>{};
  final rootTables = <String, dynamic>{};
  for (final e in profile.extra.entries) {
    if (e.value is Map) {
      rootTables[e.key] = e.value;
    } else {
      rootScalars[e.key] = e.value;
    }
  }
  if (rootScalars.isNotEmpty) {
    _w(buf, '\n');
    for (final e in rootScalars.entries) {
      _w(buf, '${_k(e.key)} = ${_v(e.value)}\n');
    }
  }
  for (final e in rootTables.entries) {
    _w(buf, '\n[${_k(e.key)}]\n');
    _writeExtraTable(buf, e.value as Map<String, dynamic>, prefix: '', root: false);
  }

  // 代理列表。
  for (final p in profile.proxies) {
    _w(buf, '\n[[proxies]]\n');
    _w(buf, 'name = ${_v(p.name)}\n');
    _w(buf, 'type = ${_v(p.type)}\n');
    _w(buf, 'localIP = ${_v(p.localIp)}\n');
    _w(buf, 'localPort = ${p.localPort}\n');
    switch (p) {
      case TcpProxy(:final remotePort):
        _w(buf, 'remotePort = $remotePort\n');
      case UdpProxy(:final remotePort):
        _w(buf, 'remotePort = $remotePort\n');
      case HttpProxy():
        if (p.customDomains.isNotEmpty) _w(buf, 'customDomains = ${_v(p.customDomains)}\n');
        if (p.subdomain != null && p.subdomain!.isNotEmpty) {
          _w(buf, 'subdomain = ${_v(p.subdomain!)}\n');
        }
        if (p.locations.isNotEmpty) _w(buf, 'locations = ${_v(p.locations)}\n');
      case HttpsProxy():
        if (p.customDomains.isNotEmpty) _w(buf, 'customDomains = ${_v(p.customDomains)}\n');
        if (p.subdomain != null && p.subdomain!.isNotEmpty) {
          _w(buf, 'subdomain = ${_v(p.subdomain!)}\n');
        }
      case StcpProxy(:final secretKey):
        if (secretKey.isNotEmpty) _w(buf, 'secretKey = ${_v(secretKey)}\n');
      case XtcpProxy(:final secretKey):
        if (secretKey.isNotEmpty) _w(buf, 'secretKey = ${_v(secretKey)}\n');
      case GenericProxy(:final fields):
        for (final e in fields.entries) {
          if (['name', 'type', 'localIP', 'localPort', 'extra'].contains(e.key)) continue;
          if (e.value is Map) continue; // 嵌套表单独写
          _w(buf, '${_k(e.key)} = ${_v(e.value)}\n');
        }
        for (final e in fields.entries) {
          if (e.value is Map) {
            _w(buf, '\n[proxies.${_k(e.key)}]\n');
            _writeExtraTable(buf, e.value as Map<String, dynamic>, prefix: '', root: false);
          }
        }
    }
    // 代理下未建模字段。
    if (p.extra.isNotEmpty) {
      for (final e in p.extra.entries) {
        if (e.value is Map) continue;
        _w(buf, '${_k(e.key)} = ${_v(e.value)}\n');
      }
      for (final e in p.extra.entries) {
        if (e.value is Map) {
          _w(buf, '\n[proxies.${_k(e.key)}]\n');
          _writeExtraTable(buf, e.value as Map<String, dynamic>, prefix: '', root: false);
        }
      }
    }
  }
  return buf.toString();
}

void _writeExtraTable(StringBuffer buf, Map<String, dynamic> table,
    {required String prefix, required bool root}) {
  // 先写标量，再写嵌套表（TOML 要求）。
  for (final e in table.entries) {
    if (e.value is Map) continue;
    final key = e.key.contains('.') ? _k(e.key) : e.key;
    _w(buf, '$key = ${_v(e.value)}\n');
  }
  for (final e in table.entries) {
    if (e.value is! Map) continue;
    final path = prefix.isEmpty ? e.key : '$prefix.${_k(e.key)}';
    _w(buf, '\n[$path]\n');
    _writeExtraTable(buf, e.value as Map<String, dynamic>, prefix: path, root: false);
  }
}

void _w(StringBuffer buf, String s) => buf.write(s);

/// 裸键（含点号路径）转带引号键（含特殊字符时）。
String _k(String key) {
  final hasSpecial = key.codeUnits.any((c) =>
      !(c >= 0x61 && c <= 0x7A || c >= 0x41 && c <= 0x5A || c >= 0x30 && c <= 0x39 || c == 0x5F || c == 0x2D));
  return hasSpecial ? _v(key) : key;
}

String _v(Object? value) {
  if (value is String) return _str(value);
  if (value is bool) return value.toString();
  if (value is num) return value.toString();
  if (value is List) return '[${value.map(_v).join(', ')}]';
  if (value is Map) {
    return '{ ${value.entries.map((e) => '${_k(e.key)} = ${_v(e.value)}').join(', ')} }';
  }
  return _str(value.toString());
}

String _str(String s) {
  final b = StringBuffer('"');
  for (final c in s.codeUnits) {
    switch (c) {
      case 0x22:
        b.write(r'\"');
      case 0x5C:
        b.write(r'\\');
      case 0x08:
        b.write(r'\b');
      case 0x0C:
        b.write(r'\f');
      case 0x0A:
        b.write(r'\n');
      case 0x0D:
        b.write(r'\r');
      case 0x09:
        b.write(r'\t');
      default:
        if (c < 0x20) {
          b.write('\\u${c.toRadixString(16).padLeft(4, '0')}');
        } else {
          b.writeCharCode(c);
        }
    }
  }
  b.write('"');
  return b.toString();
}

// ---------------------------------------------------------------------------
// 导入：TOML → Profile
// ---------------------------------------------------------------------------

/// 解析 TOML 为通用 map。表 → Map，数组表 → List<Map>。
Map<String, dynamic> parseToml(String source) {
  final root = <String, dynamic>{};
  var current = root;
  final lines = source.split('\n');
  var i = 0;

  String? peek() => i < lines.length ? lines[i] : null;

  // 跳过注释/空白。
  void skipFiller() {
    while (i < lines.length) {
      final t = _stripComment(lines[i]).trim();
      if (t.isEmpty) {
        i++;
      } else {
        return;
      }
    }
  }

  while (true) {
    skipFiller();
    if (i >= lines.length) break;
    final raw = _stripComment(lines[i]).trim();
    i++;

    if (raw.startsWith('[[')) {
      final path = _parseHeaderPath(raw, arrayTable: true, line: i);
      current = _ensureArrayTable(root, path, i);
    } else if (raw.startsWith('[')) {
      final path = _parseHeaderPath(raw, arrayTable: false, line: i);
      current = _ensureTable(root, path, i);
    } else {
      // key = value（value 可能跨多行数组/多行字符串）。
      final eq = _findTopLevelEq(raw);
      if (eq < 0) {
        throw TomlParseException('无法识别的行：$raw', i);
      }
      final keyPath = _parseKeyPath(raw.substring(0, eq).trim(), i);
      var valueText = raw.substring(eq + 1).trim();
      // 多行数组/多行字符串：聚合后续行直到闭合。
      while (_needsMore(valueText)) {
        final next = peek();
        if (next == null) throw TomlParseException('值未闭合：$valueText', i);
        i++;
        valueText = '$valueText\n${_stripComment(next)}';
      }
      final value = _parseValue(valueText, i);
      _assign(current, keyPath, value, i);
    }
  }
  return root;
}

/// TOML → FrpcProfile。[id]/[name] 由调用方提供（TOML 内不含）。
FrpcProfile tomlToProfile(String source, {required String id, String? name}) {
  final root = parseToml(source);

  final server = ServerConfig();
  final extra = <String, dynamic>{};

  server.serverAddr = (root.remove('serverAddr') as String?) ?? '';
  server.serverPort = ((root.remove('serverPort') as num?) ?? 7000).toInt();
  server.user = root.remove('user') as String?;

  final auth = root.remove('auth');
  if (auth is Map) {
    final m = auth.cast<String, dynamic>();
    server.token = m.remove('token') as String?;
    final nested = <String, dynamic>{};
    m.forEach((k, v) {
      if (v is Map) {
        // auth.tokenMeta 等嵌套表：扁平化为 auth.k.k2 形式由 _flatten 处理
        nested[k] = v;
      } else {
        server.extra['auth.$k'] = v;
      }
    });
    _flattenInto(server.extra, 'auth', nested);
  }

  final transport = root.remove('transport');
  if (transport is Map) {
    final m = transport.cast<String, dynamic>();
    server.transportProtocol = m.remove('protocol') as String?;
    server.bandwidthLimit = m.remove('bandwidthLimit')?.toString();
    final tls = m.remove('tls');
    if (tls is Map) {
      final t = tls.cast<String, dynamic>();
      server.tlsEnable = (t.remove('enable') as bool?) ?? false;
      server.tlsDisableCustomVerify = t.remove('disableCustomVerify') as bool?;
      t.forEach((k, v) {
        server.extra['transport.tls.$k'] = v;
      });
    }
    final nested = <String, dynamic>{};
    m.forEach((k, v) {
      if (v is Map) {
        nested[k] = v;
      } else {
        server.extra['transport.$k'] = v;
      }
    });
    _flattenInto(server.extra, 'transport', nested);
  }

  final proxiesRaw = root.remove('proxies');
  final proxies = <ProxyConfig>[];
  if (proxiesRaw is List) {
    for (final p in proxiesRaw) {
      if (p is Map) proxies.add(_proxyFromToml(p.cast<String, dynamic>()));
    }
  }

  // 其余顶层键进 extra。
  extra.addAll(root);

  return FrpcProfile(
    id: id,
    name: name ?? '导入的配置',
    server: server,
    proxies: proxies,
    extra: extra,
  );
}

void _flattenInto(Map<String, dynamic> target, String prefix, Map<String, dynamic> nested) {
  nested.forEach((k, v) {
    if (v is Map) {
      _flattenInto(target, '$prefix.$k', v.cast<String, dynamic>());
    } else {
      target['$prefix.$k'] = v;
    }
  });
}

ProxyConfig _proxyFromToml(Map<String, dynamic> m) {
  final name = (m['name'] as String?) ?? 'proxy';
  final type = (m['type'] as String?) ?? 'tcp';
  final localIp = (m['localIP'] as String?) ?? '127.0.0.1';
  final localPort = ((m['localPort'] as num?) ?? 5900).toInt();
  final extra = <String, dynamic>{};

  // 每种类型建模过的字段集合，其余进 extra。
  const modeled = {'name', 'type', 'localIP', 'localPort'};
  Set<String> known;
  switch (type) {
    case 'tcp':
    case 'udp':
      known = {...modeled, 'remotePort', 'extra'};
    case 'http':
      known = {...modeled, 'customDomains', 'subdomain', 'locations', 'extra'};
    case 'https':
      known = {...modeled, 'customDomains', 'subdomain', 'extra'};
    case 'stcp':
    case 'xtcp':
      known = {...modeled, 'secretKey', 'extra'};
    default:
      known = modeled;
  }
  m.forEach((k, v) {
    if (!known.contains(k)) extra[k] = v;
  });

  switch (type) {
    case 'tcp':
      return TcpProxy(
        name: name,
        localIp: localIp,
        localPort: localPort,
        remotePort: ((m['remotePort'] as num?) ?? 0).toInt(),
        extra: extra,
      );
    case 'udp':
      return UdpProxy(
        name: name,
        localIp: localIp,
        localPort: localPort,
        remotePort: ((m['remotePort'] as num?) ?? 0).toInt(),
        extra: extra,
      );
    case 'http':
      return HttpProxy(
        name: name,
        localIp: localIp,
        localPort: localPort,
        customDomains: [...(m['customDomains'] as List? ?? []).cast<String>()],
        subdomain: m['subdomain'] as String?,
        locations: [...(m['locations'] as List? ?? []).cast<String>()],
        extra: extra,
      );
    case 'https':
      return HttpsProxy(
        name: name,
        localIp: localIp,
        localPort: localPort,
        customDomains: [...(m['customDomains'] as List? ?? []).cast<String>()],
        subdomain: m['subdomain'] as String?,
        extra: extra,
      );
    case 'stcp':
      return StcpProxy(
        name: name,
        localIp: localIp,
        localPort: localPort,
        secretKey: (m['secretKey'] as String?) ?? '',
        extra: extra,
      );
    case 'xtcp':
      return XtcpProxy(
        name: name,
        localIp: localIp,
        localPort: localPort,
        secretKey: (m['secretKey'] as String?) ?? '',
        extra: extra,
      );
    default:
      return GenericProxy(
        name: name,
        localIp: localIp,
        localPort: localPort,
        type: type,
        fields: {
          for (final e in m.entries)
            if (e.key != 'name' && e.key != 'type' && e.key != 'localIP' && e.key != 'localPort') e.key: e.value,
        },
        extra: extra,
      );
  }
}

// ---------------------------------------------------------------------------
// TOML 解析器内部实现
// ---------------------------------------------------------------------------

String _stripComment(String line) {
  // 去掉字符串外的 # 注释。
  var inStr = false;
  var strChar = 0;
  for (var i = 0; i < line.length; i++) {
    final c = line.codeUnitAt(i);
    if (inStr) {
      if (c == 0x5C && strChar == 0x22) {
        i++; // 跳过转义
      } else if (c == strChar) {
        inStr = false;
      }
    } else if (c == 0x22 || c == 0x27) {
      inStr = true;
      strChar = c;
    } else if (c == 0x23) {
      return line.substring(0, i);
    }
  }
  return line;
}

int _findTopLevelEq(String line) {
  var inStr = false;
  var strChar = 0;
  var depth = 0;
  for (var i = 0; i < line.length; i++) {
    final c = line.codeUnitAt(i);
    if (inStr) {
      if (c == 0x5C && strChar == 0x22) {
        i++;
      } else if (c == strChar) {
        inStr = false;
      }
    } else if (c == 0x22 || c == 0x27) {
      inStr = true;
      strChar = c;
    } else if (c == 0x5B || c == 0x7B) {
      depth++;
    } else if (c == 0x5D || c == 0x7D) {
      depth--;
    } else if (c == 0x3D && depth == 0) {
      return i;
    }
  }
  return -1;
}

bool _needsMore(String text) {
  final t = text.trim();
  if (t.startsWith('"""') || t.startsWith("'''")) {
    final closer = t.substring(0, 3);
    return t.length < 6 || !(t.endsWith(closer) && t.length > 3 && !_endsWithEscapedQuote(t, closer));
  }
  // 数组/内联表跨行：括号不平衡则需要更多输入。
  var depth = 0;
  var inStr = false;
  var strChar = 0;
  for (var i = 0; i < t.length; i++) {
    final c = t.codeUnitAt(i);
    if (inStr) {
      if (c == 0x5C && strChar == 0x22) {
        i++;
      } else if (c == strChar) {
        inStr = false;
      }
    } else if (c == 0x22 || c == 0x27) {
      inStr = true;
      strChar = c;
    } else if (c == 0x5B || c == 0x7B) {
      depth++;
    } else if (c == 0x5D || c == 0x7D) {
      depth--;
    }
  }
  return depth > 0;
}

bool _endsWithEscapedQuote(String t, String closer) {
  // 判断结尾的 """ 是否被转义干扰（多行字符串结尾前不允许奇数个反斜杠+引号）。
  if (!t.endsWith(closer)) return false;
  var backslashes = 0;
  var idx = t.length - closer.length - 1;
  while (idx >= 0 && t.codeUnitAt(idx) == 0x5C) {
    backslashes++;
    idx--;
  }
  return backslashes.isOdd;
}

List<String> _parseKeyPath(String keyText, int line) {
  final parts = <String>[];
  var i = 0;
  while (i < keyText.length) {
    while (i < keyText.length && keyText.codeUnitAt(i) == 0x20) {
      i++;
    }
    if (i < keyText.length && (keyText.codeUnitAt(i) == 0x22 || keyText.codeUnitAt(i) == 0x27)) {
      final quote = keyText.codeUnitAt(i);
      i++;
      final b = StringBuffer();
      while (i < keyText.length && keyText.codeUnitAt(i) != quote) {
        if (quote == 0x22 && keyText.codeUnitAt(i) == 0x5C) {
          i++;
          b.write(_unescapeChar(keyText[i], line));
        } else {
          b.writeCharCode(keyText.codeUnitAt(i));
        }
        i++;
      }
      if (i >= keyText.length) throw TomlParseException('键名引号未闭合', line);
      i++;
      parts.add(b.toString());
    } else {
      final b = StringBuffer();
      while (i < keyText.length && keyText.codeUnitAt(i) != 0x2E) {
        b.writeCharCode(keyText.codeUnitAt(i));
        i++;
      }
      final part = b.toString().trim();
      if (part.isEmpty) throw TomlParseException('空键名', line);
      parts.add(part);
    }
    while (i < keyText.length && (keyText.codeUnitAt(i) == 0x20)) {
      i++;
    }
    if (i < keyText.length && keyText.codeUnitAt(i) == 0x2E) {
      i++;
    } else {
      break;
    }
  }
  return parts;
}

List<String> _parseHeaderPath(String raw, {required bool arrayTable, required int line}) {
  final inner = raw
      .trim()
      .substring(arrayTable ? 2 : 1, raw.trim().length - (arrayTable ? 2 : 1));
  return _parseKeyPath(inner.trim(), line);
}

Map<String, dynamic> _ensureTable(Map<String, dynamic> root, List<String> path, int line) {
  var cur = root;
  for (final part in path) {
    final existing = cur[part];
    if (existing == null) {
      final t = <String, dynamic>{};
      cur[part] = t;
      cur = t;
    } else if (existing is Map<String, dynamic>) {
      cur = existing;
    } else if (existing is List) {
      // 数组表的最后一个元素。
      final list = existing.cast<Map<String, dynamic>>();
      cur = list.last;
    } else {
      throw TomlParseException('表路径与已有值冲突: $part', line);
    }
  }
  return cur;
}

Map<String, dynamic> _ensureArrayTable(Map<String, dynamic> root, List<String> path, int line) {
  var cur = root;
  for (var i = 0; i < path.length - 1; i++) {
    final part = path[i];
    final existing = cur[part];
    if (existing == null) {
      final t = <String, dynamic>{};
      cur[part] = t;
      cur = t;
    } else if (existing is Map<String, dynamic>) {
      cur = existing;
    } else {
      throw TomlParseException('表路径与已有值冲突: $part', line);
    }
  }
  final last = path.last;
  final existing = cur[last];
  if (existing == null) {
    cur[last] = <Map<String, dynamic>>[];
  } else if (existing is! List<Map<String, dynamic>>) {
    // List 可能是任意元素类型；统一转存。
    final casted = <Map<String, dynamic>>[];
    for (final e in existing as List) {
      if (e is Map) casted.add(e.cast<String, dynamic>());
    }
    cur[last] = casted;
  }
  final t = <String, dynamic>{};
  (cur[last] as List).add(t);
  return t;
}

void _assign(Map<String, dynamic> table, List<String> path, Object? value, int line) {
  var cur = table;
  for (var i = 0; i < path.length - 1; i++) {
    final existing = cur[path[i]];
    if (existing is Map<String, dynamic>) {
      cur = existing;
    } else if (existing is List) {
      final list = existing.cast<Map<String, dynamic>>();
      cur = list.last;
    } else if (existing == null) {
      final t = <String, dynamic>{};
      cur[path[i]] = t;
      cur = t;
    } else {
      throw TomlParseException('键路径与已有值冲突: ${path[i]}', line);
    }
  }
  cur[path.last] = value;
}

Object? _parseValue(String text, int line) {
  final t = text.trim();
  if (t.isEmpty) throw TomlParseException('空值', line);

  // 多行基本字符串 """..."""
  if (t.startsWith('"""')) {
    if (t == '"""' || !t.endsWith('"""') || t.length < 6) {
      throw TomlParseException('多行字符串未闭合', line);
    }
    var inner = t.substring(3, t.length - 3);
    // TOML 中紧跟开头的换行被修剪。
    if (inner.startsWith('\n')) inner = inner.substring(1);
    return _unescapeBasic(inner, line);
  }
  // 多行字面字符串 '''...'''
  if (t.startsWith("'''")) {
    if (t.length < 6 || !t.endsWith("'''")) throw TomlParseException('多行字符串未闭合', line);
    var inner = t.substring(3, t.length - 3);
    if (inner.startsWith('\n')) inner = inner.substring(1);
    return inner;
  }
  // 单行字符串。
  if (t.startsWith('"')) {
    if (t.length < 2 || !t.endsWith('"')) throw TomlParseException('字符串未闭合', line);
    return _unescapeBasic(t.substring(1, t.length - 1), line);
  }
  if (t.startsWith("'")) {
    if (t.length < 2 || !t.endsWith("'")) throw TomlParseException('字符串未闭合', line);
    return t.substring(1, t.length - 1);
  }
  // 布尔。
  if (t == 'true') return true;
  if (t == 'false') return false;
  // 数组。
  if (t.startsWith('[')) {
    if (!t.endsWith(']')) throw TomlParseException('数组未闭合', line);
    return _parseArray(t.substring(1, t.length - 1), line);
  }
  // 内联表。
  if (t.startsWith('{')) {
    if (!t.endsWith('}')) throw TomlParseException('内联表未闭合', line);
    final table = <String, dynamic>{};
    final items = _splitTopLevel(t.substring(1, t.length - 1), ',');
    for (final item in items) {
      final it = item.trim();
      if (it.isEmpty) continue;
      final eq = _findTopLevelEq(it);
      if (eq < 0) throw TomlParseException('内联表项缺少 =：$it', line);
      _assign(table, _parseKeyPath(it.substring(0, eq).trim(), line), _parseValue(it.substring(eq + 1), line), line);
    }
    return table;
  }
  // 数字。
  final numStr = t.replaceAll('_', '');
  if (numStr.startsWith('0x') || numStr.startsWith('0X')) {
    return int.parse(numStr.substring(2), radix: 16);
  }
  if (numStr.startsWith('0o') || numStr.startsWith('0O')) {
    return int.parse(numStr.substring(2), radix: 8);
  }
  if (numStr.startsWith('0b') || numStr.startsWith('0B')) {
    return int.parse(numStr.substring(2), radix: 2);
  }
  if (numStr == 'inf' || numStr == '+inf') return double.infinity;
  if (numStr == '-inf') return double.negativeInfinity;
  if (numStr == 'nan' || numStr == '+nan' || numStr == '-nan') return double.nan;
  final parsed = int.tryParse(numStr);
  if (parsed != null) return parsed;
  final parsedF = double.tryParse(numStr);
  if (parsedF != null) return parsedF;
  // 日期时间等：保留原始字符串（frpc 配置中不使用）。
  return t;
}

List<Object?> _parseArray(String inner, int line) {
  final result = <Object?>[];
  for (final item in _splitTopLevel(inner, ',')) {
    final it = item.trim();
    if (it.isEmpty) continue;
    result.add(_parseValue(it, line));
  }
  return result;
}

/// 按顶层分隔符切分（忽略字符串与括号内的分隔符）。
List<String> _splitTopLevel(String text, String sep) {
  final parts = <String>[];
  var depth = 0;
  var inStr = false;
  var strChar = 0;
  final b = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (inStr) {
      b.writeCharCode(c);
      if (c == 0x5C && strChar == 0x22) {
        i++;
        if (i < text.length) b.writeCharCode(text.codeUnitAt(i));
      } else if (c == strChar) {
        inStr = false;
      }
      continue;
    }
    if (c == 0x22 || c == 0x27) {
      inStr = true;
      strChar = c;
      b.writeCharCode(c);
    } else if (c == 0x5B || c == 0x7B) {
      depth++;
      b.writeCharCode(c);
    } else if (c == 0x5D || c == 0x7D) {
      depth--;
      b.writeCharCode(c);
    } else if (sep == ',' && c == 0x2C && depth == 0) {
      parts.add(b.toString());
      b.clear();
    } else {
      b.writeCharCode(c);
    }
  }
  parts.add(b.toString());
  return parts;
}

String _unescapeBasic(String s, int line) {
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == r'\' && i + 1 < s.length) {
      i++;
      b.write(_unescapeChar(s[i], line));
    } else {
      b.write(c);
    }
  }
  return b.toString();
}

String _unescapeChar(String c, int line) {
  switch (c) {
    case 'n':
      return '\n';
    case 't':
      return '\t';
    case 'r':
      return '\r';
    case 'b':
      return '\b';
    case 'f':
      return '\f';
    case '"':
      return '"';
    case r'\':
      return r'\';
    case 'u':
    case 'U':
      // 由调用方处理后续码位（简化：此处不支持，frpc 配置中不使用）。
      throw TomlParseException('不支持 \\$c unicode 转义', line);
    default:
      throw TomlParseException('未知转义字符 \\$c', line);
  }
}
