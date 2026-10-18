import 'dart:async';

import 'package:flutter/material.dart';

import '../models/frpc_profile.dart';
import '../services/frpc/frpc_manager.dart';
import '../services/frpc/frpc_runtime.dart';
import '../services/store/app_store.dart';

/// 运行状态页：frpc 实例状态、代理列表、实时日志。
class StatusPage extends StatefulWidget {
  const StatusPage({super.key});

  @override
  State<StatusPage> createState() => _StatusPageState();
}

class _StatusPageState extends State<StatusPage> {
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _sub = FrpcManager.instance.onChange.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final profiles = AppStore.instance.profiles;
    final running = profiles
        .where((p) => FrpcManager.instance.stateOf(p.id) != FrpcState.stopped)
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('运行状态')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (running.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Icon(Icons.power_off_outlined,
                        size: 48, color: Theme.of(context).colorScheme.outline),
                    const SizedBox(height: 8),
                    const Text('没有运行中的 frpc 实例'),
                  ],
                ),
              ),
            ),
          for (final p in running) _InstanceCard(profile: p),
          const SizedBox(height: 16),
          Text('TCP 代理（可作为 VNC 隧道入口）',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final proxy in FrpcManager.instance.runningTcpProxies())
            Card(
              child: ListTile(
                leading: const Icon(Icons.vpn_key),
                title: Text(proxy.name),
                subtitle: Text(
                  '本机 127.0.0.1:${proxy.localPort} → frps :${proxy.remotePort}',
                ),
              ),
            ),
          if (FrpcManager.instance.runningVisitors().isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('访问者（STCP/XTCP 隧道入口）',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final v in FrpcManager.instance.runningVisitors())
              Card(
                child: ListTile(
                  leading: const Icon(Icons.enhanced_encryption),
                  title: Text('${v.name} [${v.type.toUpperCase()}]'),
                  subtitle: Text(
                    '本机 ${v.bindAddr}:${v.bindPort} → 远端代理 "${v.serverName}"',
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _InstanceCard extends StatelessWidget {
  const _InstanceCard({required this.profile});

  final FrpcProfile profile;

  @override
  Widget build(BuildContext context) {
    final manager = FrpcManager.instance;
    final state = manager.stateOf(profile.id);
    final logs = manager.recentLogs(profile.id);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('${profile.name}（${profile.server.serverAddr}）',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                _StateBadge(state: state),
              ],
            ),
            const SizedBox(height: 12),
            Text('日志', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 200),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                reverse: true,
                child: SelectableText(
                  logs.isEmpty ? '（暂无日志）' : logs.join('\n'),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StateBadge extends StatelessWidget {
  const _StateBadge({required this.state});

  final FrpcState state;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (state) {
      FrpcState.running => (Colors.green, '运行中'),
      FrpcState.starting => (Colors.orange, '连接中'),
      FrpcState.stopping => (Colors.orange, '停止中'),
      FrpcState.error => (Colors.red, '错误'),
      FrpcState.stopped => (Colors.grey, '已停止'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 12)),
    );
  }
}
