library;

/// frp 日志行解析：提取关键状态信息。
///
/// frpc 典型日志：
/// `2024/01/02 15:04:05 [I] [root.go:139] login to server success`
/// `2024/01/02 15:04:05 [I] [proxy_manager.go:173] [xxxxxxxx] [tcp_vnc] start proxy success`
/// `2024/01/02 15:04:05 [E] [proxy_manager.go:110] [tcp_vnc] start error: ...`

class ParsedFrpcLog {
  ParsedFrpcLog({
    required this.level,
    required this.text,
    this.proxyName,
    this.isLoginSuccess = false,
    this.isLoginFailed = false,
    this.isProxySuccess = false,
    this.isProxyError = false,
  });

  final String level;
  final String text;
  final String? proxyName;
  final bool isLoginSuccess;
  final bool isLoginFailed;
  final bool isProxySuccess;
  final bool isProxyError;
}

ParsedFrpcLog parseFrpcLog(String rawLine) {
  // frp 即使输出到管道也带 ANSI 颜色码，先剥掉。
  final line = rawLine.replaceAll(RegExp(r'\x1B\[[0-9;]*[A-Za-z]'), '').trimRight();
  // 去掉时间戳与 [level]。
  final m = RegExp(r'^\d{4}[-/]\d{2}[-/]\d{2} \d{2}:\d{2}:\d{2}(\.\d+)? \[([IWE])\] (.*)$').firstMatch(line);
  if (m == null) {
    return ParsedFrpcLog(level: 'I', text: line);
  }
  final level = m.group(2)!;
  var body = m.group(3)!;

  // 去掉 runID 与代理名标记 [xxx] [yyy]。
  final proxyMatch = RegExp(r'\[([a-z0-9_]+)\] ([\w/\-\.]+)$').firstMatch(body);
  String? proxyName;
  if (body.contains('] [')) {
    final parts = body.split('] [');
    if (parts.length >= 2) {
      final last = parts.last;
      final nameEnd = last.indexOf(']');
      if (nameEnd > 0) {
        proxyName = last.substring(0, nameEnd);
        body = body.substring(0, body.length - last.length - 1) + last.substring(nameEnd + 1);
      }
    }
  }
  proxyName ??= proxyMatch?.group(2);

  body = body.trim();
  return ParsedFrpcLog(
    level: level,
    text: body,
    proxyName: proxyName,
    isLoginSuccess: body.contains('login to server success'),
    isLoginFailed: body.contains('login to server error') || body.contains('connect to server error'),
    isProxySuccess: body.contains('start proxy success'),
    isProxyError: body.contains('start error') || (level == 'E' && proxyName != null),
  );
}
