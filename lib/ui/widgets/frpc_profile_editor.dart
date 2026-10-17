import 'package:flutter/material.dart';

import '../../models/frpc_profile.dart';
import '../../services/frpc/frpc_manager.dart';
import '../../services/frpc/toml_codec.dart';
import '../../services/store/app_store.dart';

/// frpc 配置编辑页。
///
/// 「表单」标签页覆盖常用配置（服务端 + 各类型代理）；
/// 「TOML 源码」标签页支持直接编辑/粘贴完整 frpc 配置。

class FrpcProfileEditorPage extends StatefulWidget {
  const FrpcProfileEditorPage({super.key, this.existing});

  final FrpcProfile? existing;

  @override
  State<FrpcProfileEditorPage> createState() => _FrpcProfileEditorPageState();
}

class _FrpcProfileEditorPageState extends State<FrpcProfileEditorPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late FrpcProfile _profile;

  late final TextEditingController _addr;
  late final TextEditingController _port;
  late final TextEditingController _token;
  late final TextEditingController _bandwidth;
  late final TextEditingController _user;
  late bool _tlsEnable;
  late bool _tlsDisableVerify;
  String? _transport;

  late final TextEditingController _tomlSource;
  bool _tomlDirty = false;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    final e = widget.existing;
    _profile = e?.copy() ??
        FrpcProfile(
          id: newId(),
          name: '',
          server: ServerConfig(),
          proxies: [],
        );

    _addr = TextEditingController(text: _profile.server.serverAddr);
    _port = TextEditingController(text: _profile.server.serverPort.toString());
    _token = TextEditingController(text: _profile.server.token ?? '');
    _bandwidth = TextEditingController(text: _profile.server.bandwidthLimit ?? '');
    _user = TextEditingController(text: _profile.server.user ?? '');
    _tlsEnable = _profile.server.tlsEnable;
    _tlsDisableVerify = _profile.server.tlsDisableCustomVerify ?? false;
    _transport = _profile.server.transportProtocol;
    _tomlSource = TextEditingController(text: profileToToml(_profile));
  }

  @override
  void dispose() {
    _tabs.dispose();
    _addr.dispose();
    _port.dispose();
    _token.dispose();
    _bandwidth.dispose();
    _user.dispose();
    _tomlSource.dispose();
    super.dispose();
  }

  void _syncFormToProfile() {
    _profile
      ..name = _profile.name.isEmpty ? '未命名配置' : _profile.name
      ..server.serverAddr = _addr.text.trim()
      ..server.serverPort = int.tryParse(_port.text.trim()) ?? 7000
      ..server.token = _token.text.isEmpty ? null : _token.text
      ..server.bandwidthLimit = _bandwidth.text.isEmpty ? null : _bandwidth.text
      ..server.user = _user.text.isEmpty ? null : _user.text
      ..server.tlsEnable = _tlsEnable
      ..server.tlsDisableCustomVerify = _tlsEnable && _tlsDisableVerify ? true : null
      ..server.transportProtocol = _transport;
  }

  Future<void> _save() async {
    // 若当前在 TOML 标签页且被修改，先解析回表单。
    if (_tabs.index == 1 && _tomlDirty) {
      final ok = _applyToml();
      if (!ok) return;
    } else {
      _syncFormToProfile();
    }
    if (_profile.name.trim().isEmpty) {
      _promptName();
      return;
    }
    AppStore.instance.profiles
      ..removeWhere((p) => p.id == _profile.id)
      ..add(_profile);
    await AppStore.instance.save();
    // 若正在运行，提示重启生效。
    await FrpcManager.instance.restartProfile(_profile);
    if (mounted) Navigator.of(context).pop(true);
  }

  void _promptName() {
    final c = TextEditingController(text: _profile.name);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('配置名称'),
        content: TextField(controller: c, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              setState(() => _profile.name = c.text.trim());
              Navigator.pop(ctx);
              _save();
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  bool _applyToml() {
    try {
      final parsed = tomlToProfile(_tomlSource.text, id: _profile.id);
      setState(() {
        _profile = parsed..name = _profile.name;
        _addr.text = _profile.server.serverAddr;
        _port.text = _profile.server.serverPort.toString();
        _token.text = _profile.server.token ?? '';
        _bandwidth.text = _profile.server.bandwidthLimit ?? '';
        _user.text = _profile.server.user ?? '';
        _tlsEnable = _profile.server.tlsEnable;
        _tlsDisableVerify = _profile.server.tlsDisableCustomVerify ?? false;
        _transport = _profile.server.transportProtocol;
        _tomlDirty = false;
      });
      return true;
    } on TomlParseException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      return false;
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('解析失败：$e')));
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? '新建 frpc 配置' : '编辑配置'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save_outlined),
            tooltip: '保存',
            onPressed: _save,
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          onTap: (_) {
            // 切到 TOML 标签时同步当前表单内容。
            if (_tabs.index == 1 && !_tomlDirty) {
              _syncFormToProfile();
              _tomlSource.text = profileToToml(_profile);
            }
          },
          tabs: const [
            Tab(text: '表单'),
            Tab(text: 'TOML 源码'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _buildFormTab(),
          _buildTomlTab(),
        ],
      ),
    );
  }

  Widget _buildFormTab() {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            decoration: const InputDecoration(
              labelText: '配置名称',
              border: OutlineInputBorder(),
            ),
            controller: TextEditingController(text: _profile.name),
            onChanged: (v) => _profile.name = v,
          ),
          const SizedBox(height: 16),
          _SectionCard(
            title: 'frps 服务器',
            children: [
              TextFormField(
                controller: _addr,
                decoration: const InputDecoration(
                  labelText: '服务器地址',
                  hintText: 'frps.example.com',
                  border: OutlineInputBorder(),
                ),
                validator: (v) => (v == null || v.trim().isEmpty) ? '必填' : null,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _port,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '端口',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) {
                        final p = int.tryParse(v ?? '');
                        return (p == null || p <= 0 || p > 65535) ? '无效端口' : null;
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _transport,
                      decoration: const InputDecoration(
                        labelText: '传输协议',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(value: null, child: Text('tcp（默认）')),
                        DropdownMenuItem(value: 'kcp', child: Text('kcp')),
                        DropdownMenuItem(value: 'quic', child: Text('quic')),
                        DropdownMenuItem(value: 'websocket', child: Text('websocket')),
                        DropdownMenuItem(value: 'wss', child: Text('wss')),
                      ],
                      onChanged: (v) => setState(() => _transport = v),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _token,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '认证 token',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                value: _tlsEnable,
                onChanged: (v) => setState(() => _tlsEnable = v),
                title: const Text('TLS 加密'),
                contentPadding: EdgeInsets.zero,
              ),
              if (_tlsEnable)
                CheckboxListTile(
                  value: _tlsDisableVerify,
                  onChanged: (v) => setState(() => _tlsDisableVerify = v ?? false),
                  title: const Text('跳过证书校验'),
                  subtitle: const Text('frps 使用自签名证书时开启'),
                  contentPadding: EdgeInsets.zero,
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _bandwidth,
                      decoration: const InputDecoration(
                        labelText: '带宽限制（可选，如 1MB）',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _user,
                      decoration: const InputDecoration(
                        labelText: '用户名（可选）',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SectionCard(
            title: '代理（${_profile.proxies.length}）',
            action: IconButton(
              icon: const Icon(Icons.add),
              tooltip: '添加代理',
              onPressed: _addProxy,
            ),
            children: [
              if (_profile.proxies.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('还没有代理。添加 TCP 代理即可将远程 VNC 端口映射到本机。'),
                ),
              for (var i = 0; i < _profile.proxies.length; i++)
                _ProxyTile(
                  proxy: _profile.proxies[i],
                  onEdit: () => _editProxy(i),
                  onDelete: () => setState(() => _profile.proxies.removeAt(i)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTomlTab() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Row(
            children: [
              const Expanded(
                child: Text('完整 frpc TOML 配置（与官方 frpc.toml 格式互通，可粘贴已有配置）'),
              ),
              TextButton(
                onPressed: () {
                  if (_applyToml()) {
                    setState(() {
                      _tomlSource.text = profileToToml(_profile);
                    });
                  }
                },
                child: const Text('解析并应用'),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _tomlSource,
              onChanged: (_) => _tomlDirty = true,
              maxLines: null,
              expands: true,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '[serverAddr = "..."]',
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _addProxy() async {
    final type = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择代理类型'),
        children: [
          for (final (t, desc) in const [
            ('tcp', 'TCP 端口映射（VNC 隧道用这个）'),
            ('udp', 'UDP 端口映射'),
            ('http', 'HTTP（需要 vhostHTTPPort）'),
            ('https', 'HTTPS'),
            ('stcp', '安全 TCP（需 secretKey，不暴露公网端口）'),
            ('xtcp', 'P2P 穿透 TCP（需 secretKey）'),
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, t),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text(desc, style: Theme.of(ctx).textTheme.bodySmall),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    if (type == null || !mounted) return;
    final proxy = switch (type) {
      'tcp' => TcpProxy(name: 'proxy_${_profile.proxies.length + 1}', localPort: 5900, remotePort: 6000),
      'udp' => UdpProxy(name: 'proxy_${_profile.proxies.length + 1}', localPort: 5900, remotePort: 6000),
      'http' => HttpProxy(name: 'proxy_${_profile.proxies.length + 1}', localPort: 80),
      'https' => HttpsProxy(name: 'proxy_${_profile.proxies.length + 1}', localPort: 443),
      'stcp' => StcpProxy(name: 'proxy_${_profile.proxies.length + 1}', localPort: 5900, secretKey: ''),
      'xtcp' => XtcpProxy(name: 'proxy_${_profile.proxies.length + 1}', localPort: 5900, secretKey: ''),
      _ => throw StateError('unreachable'),
    };
    final result = await showDialog<ProxyConfig>(
      context: context,
      builder: (_) => _ProxyEditDialog(proxy: proxy, isNew: true),
    );
    if (result != null) {
      setState(() => _profile.proxies.add(result));
    }
  }

  Future<void> _editProxy(int index) async {
    final result = await showDialog<ProxyConfig>(
      context: context,
      builder: (_) => _ProxyEditDialog(proxy: _profile.proxies[index].copy(), isNew: false),
    );
    if (result != null) {
      setState(() => _profile.proxies[index] = result);
    }
  }
}

// ---------------------------------------------------------------------------
// 分区卡片
// ---------------------------------------------------------------------------

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.children, this.action});

  final String title;
  final List<Widget> children;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title, style: Theme.of(context).textTheme.titleMedium),
                ),
                if (action != null) action!,
              ],
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _ProxyTile extends StatelessWidget {
  const _ProxyTile({required this.proxy, required this.onEdit, required this.onDelete});

  final ProxyConfig proxy;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  String get _summary {
    final base = '${proxy.localIp}:${proxy.localPort}';
    return switch (proxy) {
      TcpProxy(:final remotePort) => '$base → 远程 :$remotePort',
      UdpProxy(:final remotePort) => '$base → 远程 :$remotePort (UDP)',
      HttpProxy(:final customDomains) => '$base → ${customDomains.join(', ')}',
      HttpsProxy(:final customDomains) => '$base → ${customDomains.join(', ')}',
      StcpProxy() => '$base（安全隧道）',
      XtcpProxy() => '$base（P2P 穿透）',
      GenericProxy(:final type) => '$base（$type）',
    };
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.compare_arrows),
      title: Text('${proxy.name}  [${proxy.type.toUpperCase()}]'),
      subtitle: Text(_summary),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(icon: const Icon(Icons.edit_outlined), onPressed: onEdit),
          IconButton(icon: const Icon(Icons.delete_outline), onPressed: onDelete),
        ],
      ),
      onTap: onEdit,
    );
  }
}

// ---------------------------------------------------------------------------
// 代理编辑对话框
// ---------------------------------------------------------------------------

class _ProxyEditDialog extends StatefulWidget {
  const _ProxyEditDialog({required this.proxy, required this.isNew});

  final ProxyConfig proxy;
  final bool isNew;

  @override
  State<_ProxyEditDialog> createState() => _ProxyEditDialogState();
}

class _ProxyEditDialogState extends State<_ProxyEditDialog> {
  late final ProxyConfig _p;
  late final TextEditingController _name;
  late final TextEditingController _localIp;
  late final TextEditingController _localPort;
  late final TextEditingController _remotePort;
  late final TextEditingController _secretKey;
  late final TextEditingController _domains;
  late final TextEditingController _subdomain;
  late final TextEditingController _locations;

  @override
  void initState() {
    super.initState();
    _p = widget.proxy;
    _name = TextEditingController(text: _p.name);
    _localIp = TextEditingController(text: _p.localIp);
    _localPort = TextEditingController(text: _p.localPort.toString());
    _remotePort = TextEditingController(
        text: _p is TcpProxy ? _p.remotePort.toString() : _p is UdpProxy ? _p.remotePort.toString() : '');
    _secretKey = TextEditingController(
        text: _p is StcpProxy ? _p.secretKey : _p is XtcpProxy ? _p.secretKey : '');
    _domains = TextEditingController(
        text: _p is HttpProxy ? _p.customDomains.join(', ') : _p is HttpsProxy ? _p.customDomains.join(', ') : '');
    _subdomain = TextEditingController(
        text: _p is HttpProxy ? _p.subdomain ?? '' : _p is HttpsProxy ? _p.subdomain ?? '' : '');
    _locations = TextEditingController(
        text: _p is HttpProxy ? _p.locations.join(', ') : '');
  }

  @override
  void dispose() {
    _name.dispose();
    _localIp.dispose();
    _localPort.dispose();
    _remotePort.dispose();
    _secretKey.dispose();
    _domains.dispose();
    _subdomain.dispose();
    _locations.dispose();
    super.dispose();
  }

  ProxyConfig? _build() {
    final name = _name.text.trim();
    final localIp = _localIp.text.trim().isEmpty ? '127.0.0.1' : _localIp.text.trim();
    final localPort = int.tryParse(_localPort.text.trim());
    if (name.isEmpty || localPort == null) return null;

    switch (_p) {
      case TcpProxy():
        final rp = int.tryParse(_remotePort.text.trim());
        if (rp == null) return null;
        return TcpProxy(name: name, localIp: localIp, localPort: localPort, remotePort: rp, extra: _p.extra);
      case UdpProxy():
        final rp = int.tryParse(_remotePort.text.trim());
        if (rp == null) return null;
        return UdpProxy(name: name, localIp: localIp, localPort: localPort, remotePort: rp, extra: _p.extra);
      case HttpProxy():
        return HttpProxy(
          name: name,
          localIp: localIp,
          localPort: localPort,
          customDomains: _splitList(_domains.text),
          subdomain: _subdomain.text.trim().isEmpty ? null : _subdomain.text.trim(),
          locations: _splitList(_locations.text),
          extra: _p.extra,
        );
      case HttpsProxy():
        return HttpsProxy(
          name: name,
          localIp: localIp,
          localPort: localPort,
          customDomains: _splitList(_domains.text),
          subdomain: _subdomain.text.trim().isEmpty ? null : _subdomain.text.trim(),
          extra: _p.extra,
        );
      case StcpProxy():
        return StcpProxy(name: name, localIp: localIp, localPort: localPort, secretKey: _secretKey.text.trim(), extra: _p.extra);
      case XtcpProxy():
        return XtcpProxy(name: name, localIp: localIp, localPort: localPort, secretKey: _secretKey.text.trim(), extra: _p.extra);
      case GenericProxy():
        return GenericProxy(
          name: name,
          localIp: localIp,
          localPort: localPort,
          type: _p.type,
          fields: _p.fields,
          extra: _p.extra,
        );
    }
  }

  List<String> _splitList(String s) => [
        for (final part in s.split(','))
          if (part.trim().isNotEmpty) part.trim()
      ];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isNew ? '添加代理' : '编辑代理'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _f('代理名称', _name),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: _f('本地 IP', _localIp)),
                  const SizedBox(width: 8),
                  Expanded(child: _f('本地端口', _localPort, number: true)),
                ],
              ),
              if (_p is TcpProxy || _p is UdpProxy) ...[
                const SizedBox(height: 12),
                _f('远程端口（frps 上暴露的端口）', _remotePort, number: true),
              ],
              if (_p is StcpProxy || _p is XtcpProxy) ...[
                const SizedBox(height: 12),
                _f('secretKey（访问密钥）', _secretKey),
              ],
              if (_p is HttpProxy || _p is HttpsProxy) ...[
                const SizedBox(height: 12),
                _f('自定义域名（逗号分隔）', _domains),
                const SizedBox(height: 12),
                _f('子域名（可选）', _subdomain),
              ],
              if (_p is HttpProxy) ...[
                const SizedBox(height: 12),
                _f('路由 locations（逗号分隔，可选）', _locations),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final p = _build();
            if (p == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('请填写完整且正确的字段')),
              );
              return;
            }
            Navigator.pop(context, p);
          },
          child: const Text('确定'),
        ),
      ],
    );
  }

  Widget _f(String label, TextEditingController c, {bool number = false}) => TextField(
        controller: c,
        keyboardType: number ? TextInputType.number : null,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      );
}
