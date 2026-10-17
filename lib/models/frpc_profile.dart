library;

/// frpc 配置数据模型。
///
/// 与 frpc 原生 TOML 配置一一对应；未识别的字段保存在各模型的
/// `extra` 中，TOML 导入/导出时原样保留，避免破坏手工配置。

/// 一个 frpc 配置文件 = 一个 Profile。
class FrpcProfile {
  FrpcProfile({
    required this.id,
    required this.name,
    required this.server,
    List<ProxyConfig> proxies = const [],
    this.enabled = false,
    Map<String, dynamic> extra = const {},
  })  : proxies = List.of(proxies),
        extra = Map.of(extra);

  String id;
  String name;
  ServerConfig server;
  List<ProxyConfig> proxies;
  bool enabled;

  /// 顶层未归类的 frpc 字段（如 webServer、log 等）。
  Map<String, dynamic> extra;

  FrpcProfile copy() => FrpcProfile(
        id: id,
        name: name,
        server: server.copy(),
        proxies: [for (final p in proxies) p.copy()],
        enabled: enabled,
        extra: Map.of(extra),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'server': server.toJson(),
        'proxies': [for (final p in proxies) p.toJson()],
        'enabled': enabled,
        if (extra.isNotEmpty) 'extra': extra,
      };

  static FrpcProfile fromJson(Map<String, dynamic> j) => FrpcProfile(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '未命名配置',
        server: ServerConfig.fromJson((j['server'] as Map).cast<String, dynamic>()),
        proxies: [
          for (final p in (j['proxies'] as List? ?? []))
            ProxyConfig.fromJson((p as Map).cast<String, dynamic>())
        ],
        enabled: (j['enabled'] as bool?) ?? false,
        extra: ((j['extra'] as Map?) ?? {}).cast<String, dynamic>(),
      );
}

/// frpc 客户端级（服务端连接）配置。
class ServerConfig {
  ServerConfig({
    this.serverAddr = '',
    this.serverPort = 7000,
    this.token,
    this.tlsEnable = true,
    this.tlsDisableCustomVerify,
    this.transportProtocol,
    this.bandwidthLimit,
    this.user,
    Map<String, dynamic> extra = const {},
  }) : extra = Map.of(extra);

  String serverAddr;
  int serverPort;

  /// 认证 token；为空表示服务端未开启认证。
  String? token;
  bool tlsEnable;

  /// 跳过 TLS 证书校验（自签名证书场景）。
  bool? tlsDisableCustomVerify;

  /// tcp / kcp / quic / websocket / wss。
  String? transportProtocol;
  String? bandwidthLimit;
  String? user;

  /// auth./transport. 等命名空间下未显式建模的字段，
  /// key 为 "auth.xxx" / "transport.xxx" 形式。
  Map<String, dynamic> extra;

  ServerConfig copy() => ServerConfig(
        serverAddr: serverAddr,
        serverPort: serverPort,
        token: token,
        tlsEnable: tlsEnable,
        tlsDisableCustomVerify: tlsDisableCustomVerify,
        transportProtocol: transportProtocol,
        bandwidthLimit: bandwidthLimit,
        user: user,
        extra: Map.of(extra),
      );

  Map<String, dynamic> toJson() => {
        'serverAddr': serverAddr,
        'serverPort': serverPort,
        if (token != null && token!.isNotEmpty) 'token': token,
        'tlsEnable': tlsEnable,
        if (tlsDisableCustomVerify != null) 'tlsDisableCustomVerify': tlsDisableCustomVerify,
        if (transportProtocol != null) 'transportProtocol': transportProtocol,
        if (bandwidthLimit != null && bandwidthLimit!.isNotEmpty) 'bandwidthLimit': bandwidthLimit,
        if (user != null && user!.isNotEmpty) 'user': user,
        if (extra.isNotEmpty) 'extra': extra,
      };

  static ServerConfig fromJson(Map<String, dynamic> j) => ServerConfig(
        serverAddr: (j['serverAddr'] as String?) ?? '',
        serverPort: (j['serverPort'] as num?)?.toInt() ?? 7000,
        token: j['token'] as String?,
        tlsEnable: (j['tlsEnable'] as bool?) ?? true,
        tlsDisableCustomVerify: j['tlsDisableCustomVerify'] as bool?,
        transportProtocol: j['transportProtocol'] as String?,
        bandwidthLimit: j['bandwidthLimit'] as String?,
        user: j['user'] as String?,
        extra: ((j['extra'] as Map?) ?? {}).cast<String, dynamic>(),
      );
}

/// 代理配置基类。[extra] 保留该代理下未建模的字段。
sealed class ProxyConfig {
  ProxyConfig({
    required this.name,
    this.localIp = '127.0.0.1',
    required this.localPort,
    Map<String, dynamic> extra = const {},
  }) : extra = Map.of(extra);

  String name;
  String localIp;
  int localPort;
  Map<String, dynamic> extra;

  /// TOML 中的 type 字段值。
  String get type;

  ProxyConfig copy();

  Map<String, dynamic> baseJson() => {
        'name': name,
        'type': type,
        'localIP': localIp,
        'localPort': localPort,
        if (extra.isNotEmpty) 'extra': extra,
      };

  Map<String, dynamic> toJson();

  static ProxyConfig fromJson(Map<String, dynamic> j) {
    final type = j['type'] as String;
    final name = (j['name'] as String?) ?? 'proxy';
    final localIp = (j['localIP'] as String?) ?? '127.0.0.1';
    final localPort = (j['localPort'] as num?)?.toInt() ?? 5900;
    final extra = (j['extra'] as Map?)?.cast<String, dynamic>() ?? const {};
    switch (type) {
      case 'tcp':
        return TcpProxy(
          name: name,
          localIp: localIp,
          localPort: localPort,
          remotePort: (j['remotePort'] as num?)?.toInt() ?? 0,
          extra: extra,
        );
      case 'udp':
        return UdpProxy(
          name: name,
          localIp: localIp,
          localPort: localPort,
          remotePort: (j['remotePort'] as num?)?.toInt() ?? 0,
          extra: extra,
        );
      case 'http':
        return HttpProxy(
          name: name,
          localIp: localIp,
          localPort: localPort,
          customDomains: [...(j['customDomains'] as List? ?? []).cast<String>()],
          subdomain: j['subdomain'] as String?,
          locations: [...(j['locations'] as List? ?? []).cast<String>()],
          extra: extra,
        );
      case 'https':
        return HttpsProxy(
          name: name,
          localIp: localIp,
          localPort: localPort,
          customDomains: [...(j['customDomains'] as List? ?? []).cast<String>()],
          subdomain: j['subdomain'] as String?,
          extra: extra,
        );
      case 'stcp':
        return StcpProxy(
          name: name,
          localIp: localIp,
          localPort: localPort,
          secretKey: (j['secretKey'] as String?) ?? '',
          extra: extra,
        );
      case 'xtcp':
        return XtcpProxy(
          name: name,
          localIp: localIp,
          localPort: localPort,
          secretKey: (j['secretKey'] as String?) ?? '',
          extra: extra,
        );
      default:
        // 未知类型：保留为通用代理，字段原样存 fields，避免丢数据。
        return GenericProxy(
          name: name,
          localIp: localIp,
          localPort: localPort,
          type: type,
          fields: {
            for (final e in j.entries)
              if (!['name', 'type', 'localIP', 'localPort', 'extra'].contains(e.key))
                e.key: e.value,
          },
          extra: extra,
        );
    }
  }
}

class TcpProxy extends ProxyConfig {
  TcpProxy({
    required super.name,
    required super.localPort,
    required this.remotePort,
    super.localIp,
    super.extra,
  });

  int remotePort;

  @override
  String get type => 'tcp';

  @override
  TcpProxy copy() => TcpProxy(
        name: name,
        localIp: localIp,
        localPort: localPort,
        remotePort: remotePort,
        extra: Map.of(extra),
      );

  @override
  Map<String, dynamic> toJson() => {...baseJson(), 'remotePort': remotePort};
}

class UdpProxy extends ProxyConfig {
  UdpProxy({
    required super.name,
    required super.localPort,
    required this.remotePort,
    super.localIp,
    super.extra,
  });

  int remotePort;

  @override
  String get type => 'udp';

  @override
  UdpProxy copy() => UdpProxy(
        name: name,
        localIp: localIp,
        localPort: localPort,
        remotePort: remotePort,
        extra: Map.of(extra),
      );

  @override
  Map<String, dynamic> toJson() => {...baseJson(), 'remotePort': remotePort};
}

class HttpProxy extends ProxyConfig {
  HttpProxy({
    required super.name,
    required super.localPort,
    List<String>? customDomains,
    this.subdomain,
    List<String>? locations,
    super.localIp,
    super.extra,
  })  : customDomains = List.of(customDomains ?? const []),
        locations = List.of(locations ?? const []);

  List<String> customDomains;
  String? subdomain;
  List<String> locations;

  @override
  String get type => 'http';

  @override
  HttpProxy copy() => HttpProxy(
        name: name,
        localIp: localIp,
        localPort: localPort,
        customDomains: List.of(customDomains),
        subdomain: subdomain,
        locations: List.of(locations),
        extra: Map.of(extra),
      );

  @override
  Map<String, dynamic> toJson() => {
        ...baseJson(),
        if (customDomains.isNotEmpty) 'customDomains': customDomains,
        if (subdomain != null && subdomain!.isNotEmpty) 'subdomain': subdomain,
        if (locations.isNotEmpty) 'locations': locations,
      };
}

class HttpsProxy extends ProxyConfig {
  HttpsProxy({
    required super.name,
    required super.localPort,
    List<String>? customDomains,
    this.subdomain,
    super.localIp,
    super.extra,
  }) : customDomains = List.of(customDomains ?? const []);

  List<String> customDomains;
  String? subdomain;

  @override
  String get type => 'https';

  @override
  HttpsProxy copy() => HttpsProxy(
        name: name,
        localIp: localIp,
        localPort: localPort,
        customDomains: List.of(customDomains),
        subdomain: subdomain,
        extra: Map.of(extra),
      );

  @override
  Map<String, dynamic> toJson() => {
        ...baseJson(),
        if (customDomains.isNotEmpty) 'customDomains': customDomains,
        if (subdomain != null && subdomain!.isNotEmpty) 'subdomain': subdomain,
      };
}

class StcpProxy extends ProxyConfig {
  StcpProxy({
    required super.name,
    required super.localPort,
    required this.secretKey,
    super.localIp,
    super.extra,
  });

  String secretKey;

  @override
  String get type => 'stcp';

  @override
  StcpProxy copy() => StcpProxy(
        name: name,
        localIp: localIp,
        localPort: localPort,
        secretKey: secretKey,
        extra: Map.of(extra),
      );

  @override
  Map<String, dynamic> toJson() => {...baseJson(), 'secretKey': secretKey};
}

class XtcpProxy extends ProxyConfig {
  XtcpProxy({
    required super.name,
    required super.localPort,
    required this.secretKey,
    super.localIp,
    super.extra,
  });

  String secretKey;

  @override
  String get type => 'xtcp';

  @override
  XtcpProxy copy() => XtcpProxy(
        name: name,
        localIp: localIp,
        localPort: localPort,
        secretKey: secretKey,
        extra: Map.of(extra),
      );

  @override
  Map<String, dynamic> toJson() => {...baseJson(), 'secretKey': secretKey};
}

/// 未知/未建模代理类型的兜底容器，字段原样保留。
class GenericProxy extends ProxyConfig {
  GenericProxy({
    required super.name,
    required super.localPort,
    required this.type,
    required this.fields,
    super.localIp,
    super.extra,
  });

  @override
  final String type;

  /// 除 name/localIP/localPort/extra 外的所有原始字段。
  final Map<String, dynamic> fields;

  @override
  GenericProxy copy() => GenericProxy(
        name: name,
        localIp: localIp,
        localPort: localPort,
        type: type,
        fields: Map.of(fields),
        extra: Map.of(extra),
      );

  @override
  Map<String, dynamic> toJson() {
    final j = {
      'name': name,
      'type': type,
      'localIP': localIp,
      'localPort': localPort,
      ...fields,
    }..remove('extra');
    if (extra.isNotEmpty) j['extra'] = extra;
    return j;
  }
}

/// VNC 连接书签。
class VncBookmark {
  VncBookmark({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    this.password,
    this.tlsVerify = false,
    this.viaProxyId,
    this.viaProxyName,
  });

  final String id;
  String name;
  String host;
  int port;

  /// VNC 密码；明文存储于本地配置（与主流 VNC 客户端行为一致）。
  String? password;

  /// TLS 下是否校验服务端证书。
  bool tlsVerify;

  /// 关联的 TCP 代理 id；非空表示通过 frpc 隧道连接。
  String? viaProxyId;
  String? viaProxyName;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        if (password != null && password!.isNotEmpty) 'password': password,
        'tlsVerify': tlsVerify,
        if (viaProxyId != null) 'viaProxyId': viaProxyId,
        if (viaProxyName != null) 'viaProxyName': viaProxyName,
      };

  static VncBookmark fromJson(Map<String, dynamic> j) => VncBookmark(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? 'VNC',
        host: (j['host'] as String?) ?? '',
        port: (j['port'] as num?)?.toInt() ?? 5900,
        password: j['password'] as String?,
        tlsVerify: (j['tlsVerify'] as bool?) ?? false,
        viaProxyId: j['viaProxyId'] as String?,
        viaProxyName: j['viaProxyName'] as String?,
      );
}
