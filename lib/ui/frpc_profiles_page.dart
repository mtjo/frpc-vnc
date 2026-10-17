import 'package:flutter/material.dart';

import '../models/frpc_profile.dart';
import '../services/frpc/frpc_manager.dart';
import '../services/frpc/frpc_runtime.dart';
import '../services/store/app_store.dart';
import 'widgets/frpc_profile_editor.dart';

/// frpc 配置页：Profile 列表，支持启动/停止/编辑/复制/删除。
class FrpcProfilesPage extends StatefulWidget {
  const FrpcProfilesPage({super.key});

  @override
  State<FrpcProfilesPage> createState() => _FrpcProfilesPageState();
}

class _FrpcProfilesPageState extends State<FrpcProfilesPage> {
  @override
  void initState() {
    super.initState();
    FrpcManager.instance.onChange.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final profiles = AppStore.instance.profiles;
    return Scaffold(
      appBar: AppBar(title: const Text('frpc 配置')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editProfile(null),
        icon: const Icon(Icons.add),
        label: const Text('新建配置'),
      ),
      body: profiles.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.hub_outlined, size: 64, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: 16),
                  const Text('还没有 frpc 配置'),
                  const SizedBox(height: 4),
                  Text('新建配置连接到你的 frps 服务器', style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: profiles.length,
              itemBuilder: (context, i) {
                final p = profiles[i];
                return _ProfileCard(
                  profile: p,
                  onToggle: () => _toggle(p),
                  onEdit: () => _editProfile(p),
                  onCopy: () => _copy(p),
                  onDelete: () => _delete(i),
                );
              },
            ),
    );
  }

  Future<void> _toggle(FrpcProfile p) async {
    final manager = FrpcManager.instance;
    final state = manager.stateOf(p.id);
    try {
      if (state == FrpcState.stopped || state == FrpcState.error) {
        await manager.startProfile(p);
      } else {
        await manager.stopProfile(p);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败：$e')),
        );
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _editProfile(FrpcProfile? p) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => FrpcProfileEditorPage(existing: p),
      ),
    );
    if (saved == true && mounted) setState(() {});
  }

  void _copy(FrpcProfile p) {
    final copy = p.copy()
      ..id = newId()
      ..name = '${p.name} 副本'
      ..enabled = false;
    AppStore.instance.profiles.add(copy);
    AppStore.instance.save();
    setState(() {});
  }

  void _delete(int index) {
    final p = AppStore.instance.profiles[index];
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除配置'),
        content: Text('确定删除「${p.name}」？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    ).then((ok) async {
      if (ok == true) {
        if (FrpcManager.instance.stateOf(p.id) != FrpcState.stopped) {
          await FrpcManager.instance.stopProfile(p);
        }
        setState(() => AppStore.instance.profiles.removeAt(index));
        AppStore.instance.save();
      }
    });
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.profile,
    required this.onToggle,
    required this.onEdit,
    required this.onCopy,
    required this.onDelete,
  });

  final FrpcProfile profile;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onCopy;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final manager = FrpcManager.instance;
    final state = manager.stateOf(profile.id);
    final running = state == FrpcState.running;
    final starting = state == FrpcState.starting || state == FrpcState.stopping;
    final error = state == FrpcState.error;

    final (color, stateLabel) = switch (state) {
      FrpcState.running => (Colors.green, '已连接'),
      FrpcState.starting => (Colors.orange, '连接中…'),
      FrpcState.stopping => (Colors.orange, '停止中…'),
      FrpcState.error => (Colors.red, '错误'),
      FrpcState.stopped => (Colors.grey, '已停止'),
    };

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          children: [
            ListTile(
              leading: CircleAvatar(
                backgroundColor: color.withValues(alpha: 0.15),
                child: Icon(Icons.hub, color: color),
              ),
              title: Text(profile.name),
              subtitle: Text(
                '${profile.server.serverAddr}:${profile.server.serverPort}'
                ' · ${profile.proxies.length} 个代理',
              ),
              trailing: _StateChip(label: stateLabel, color: color),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (error)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: TextButton(
                      onPressed: () => _showError(context, manager, profile),
                      child: const Text('查看错误'),
                    ),
                  ),
                FilledButton.tonalIcon(
                  onPressed: starting ? null : onToggle,
                  icon: Icon(running ? Icons.stop : Icons.play_arrow),
                  label: Text(running ? '停止' : '启动'),
                ),
                IconButton(icon: const Icon(Icons.edit_outlined), onPressed: onEdit),
                IconButton(icon: const Icon(Icons.copy_outlined), onPressed: onCopy),
                IconButton(icon: const Icon(Icons.delete_outline), onPressed: onDelete),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showError(BuildContext context, FrpcManager manager, FrpcProfile p) {
    final logs = manager.recentLogs(p.id);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${p.name} · 最近日志'),
        content: SizedBox(
          width: 500,
          height: 300,
          child: SingleChildScrollView(
            child: SelectableText(
              logs.isEmpty ? '（暂无日志）' : logs.join('\n'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
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
