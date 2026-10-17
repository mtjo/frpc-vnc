import 'package:flutter/material.dart';

import '../../models/frpc_profile.dart';
import '../../services/frpc/frpc_manager.dart';
import '../../services/frpc/frpc_runtime.dart';
import '../../services/store/app_store.dart';

/// 新建/编辑 VNC 连接对话框。
///
/// 提供两种连接入口：局域网 IP 直连 / 通过 frpc 隧道。
class ConnectDialog extends StatefulWidget {
  const ConnectDialog({super.key, this.existing});

  final VncBookmark? existing;

  @override
  State<ConnectDialog> createState() => _ConnectDialogState();
}

class _ConnectDialogState extends State<ConnectDialog> {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _password;
  late bool _viaTunnel;
  String? _selectedProxyName;
  late bool _tlsVerify;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _host = TextEditingController(text: e?.host ?? '');
    _port = TextEditingController(text: (e?.port ?? 5900).toString());
    _password = TextEditingController(text: e?.password ?? '');
    _viaTunnel = e?.viaProxyId != null;
    _selectedProxyName = e?.viaProxyName;
    _tlsVerify = e?.tlsVerify ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tcpProxies = FrpcManager.instance.runningTcpProxies();
    final runningProfiles = AppStore.instance.profiles
        .where((p) => FrpcManager.instance.stateOf(p.id) != FrpcState.stopped)
        .toList();

    return AlertDialog(
      title: Text(widget.existing == null ? '新建 VNC 连接' : '编辑连接'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '如：公司 Windows',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, icon: Icon(Icons.lan), label: Text('IP 直连')),
                  ButtonSegment(value: true, icon: Icon(Icons.vpn_key), label: Text('frpc 隧道')),
                ],
                selected: {_viaTunnel},
                onSelectionChanged: (s) => setState(() => _viaTunnel = s.first),
              ),
              const SizedBox(height: 12),
              if (_viaTunnel) ...[
                if (runningProfiles.isEmpty)
                  const ListTile(
                    leading: Icon(Icons.warning_amber_rounded),
                    title: Text('没有运行中的 frpc 配置'),
                    subtitle: Text('请先到 frpc 页启动一个配置，隧道建立后即可连接'),
                    contentPadding: EdgeInsets.zero,
                  )
                else
                  DropdownButtonFormField<String>(
                    initialValue: _selectedProxyName,
                    decoration: const InputDecoration(
                      labelText: '选择隧道代理（TCP）',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final p in tcpProxies)
                        DropdownMenuItem(value: p.name, child: Text('${p.name} (→:${p.remotePort})')),
                    ],
                    onChanged: (v) => setState(() => _selectedProxyName = v),
                  ),
              ] else ...[
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _host,
                        decoration: const InputDecoration(
                          labelText: 'VNC 服务器 IP / 主机名',
                          hintText: '192.168.1.100',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _port,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '端口',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'VNC 密码（可留空）',
                  border: OutlineInputBorder(),
                ),
              ),
              if (!_viaTunnel)
                CheckboxListTile(
                  value: _tlsVerify,
                  onChanged: (v) => setState(() => _tlsVerify = v ?? false),
                  title: const Text('TLS 证书校验'),
                  subtitle: const Text('服务器使用 TLS 时校验证书（自签名请关闭）'),
                  contentPadding: EdgeInsets.zero,
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => _submit(tcpProxies),
          child: const Text('保存'),
        ),
      ],
    );
  }

  void _submit(List<TcpProxy> tcpProxies) {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _toast('请填写名称');
      return;
    }
    if (_viaTunnel) {
      if (_selectedProxyName == null) {
        _toast('请选择隧道代理');
        return;
      }
      Navigator.of(context).pop(VncBookmark(
        id: widget.existing?.id ?? newId(),
        name: name,
        host: '127.0.0.1',
        port: 0,
        password: _password.text.isEmpty ? null : _password.text,
        viaProxyId: _selectedProxyName,
        viaProxyName: _selectedProxyName,
      ));
      return;
    }
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    if (host.isEmpty || port == null || port <= 0 || port > 65535) {
      _toast('请填写正确的地址与端口');
      return;
    }
    Navigator.of(context).pop(VncBookmark(
      id: widget.existing?.id ?? newId(),
      name: name,
      host: host,
      port: port,
      password: _password.text.isEmpty ? null : _password.text,
      tlsVerify: _tlsVerify,
    ));
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
