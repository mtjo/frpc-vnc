import 'package:flutter/material.dart';

import '../models/frpc_profile.dart';
import '../services/frpc/frpc_manager.dart';
import '../services/store/app_store.dart';
import '../services/vnc/vnc_session.dart';
import '../services/vnc/keysyms.dart' show Keysyms; // ignore: unused_import
import 'vnc_viewer_page.dart';
import 'widgets/connect_dialog.dart';

/// 连接页：VNC 书签列表 + 新建连接。
class ConnectionsPage extends StatefulWidget {
  const ConnectionsPage({super.key});

  @override
  State<ConnectionsPage> createState() => _ConnectionsPageState();
}

class _ConnectionsPageState extends State<ConnectionsPage> {
  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    final bookmarks = store.bookmarks;

    return Scaffold(
      appBar: AppBar(title: const Text('VNC 连接')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showConnectDialog(),
        icon: const Icon(Icons.add_link),
        label: const Text('新建连接'),
      ),
      body: bookmarks.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.desktop_windows_outlined,
                      size: 64, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: 16),
                  const Text('还没有 VNC 连接'),
                  const SizedBox(height: 4),
                  Text(
                    '支持局域网 IP 直连，或通过 frpc 隧道连接远程桌面',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: bookmarks.length,
              itemBuilder: (context, i) {
                final b = bookmarks[i];
                return _BookmarkCard(
                  bookmark: b,
                  onConnect: () => _connect(b),
                  onEdit: () => _showConnectDialog(existing: b),
                  onDelete: () {
                    setState(() => store.bookmarks.removeAt(i));
                    store.save();
                  },
                );
              },
            ),
    );
  }

  Future<void> _showConnectDialog({VncBookmark? existing}) async {
    final result = await showDialog<VncBookmark>(
      context: context,
      builder: (_) => ConnectDialog(existing: existing),
    );
    if (result == null) return;
    setState(() {
      if (existing == null) {
        AppStore.instance.bookmarks.add(result);
      } else {
        final i = AppStore.instance.bookmarks.indexWhere((b) => b.id == existing.id);
        if (i >= 0) AppStore.instance.bookmarks[i] = result;
      }
    });
    AppStore.instance.save();
  }

  Future<void> _connect(VncBookmark b) async {
    // 解析实际 host:port。
    String host;
    int port;
    if (b.viaProxyId != null) {
      // 先按名称匹配 TCP 代理，再匹配 stcp/xtcp 访问者。
      final proxies = FrpcManager.instance.runningTcpProxies();
      TcpProxy? proxy;
      for (final p in proxies) {
        if (p.name == b.viaProxyName && p.localPort > 0) {
          proxy = p;
          break;
        }
      }
      if (proxy != null) {
        host = '127.0.0.1';
        port = proxy.localPort;
      } else {
        final visitors = FrpcManager.instance.runningVisitors();
        VisitorConfig? visitor;
        for (final v in visitors) {
          if (v.name == b.viaProxyName && v.bindPort > 0) {
            visitor = v;
            break;
          }
        }
        if (visitor == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('没有运行中的 frpc 隧道/访问者，请先在 frpc 页启动配置')),
            );
          }
          return;
        }
        host = visitor.bindAddr.isEmpty || visitor.bindAddr == '0.0.0.0'
            ? '127.0.0.1'
            : visitor.bindAddr;
        port = visitor.bindPort;
      }
    } else {
      host = b.host;
      port = b.port;
    }

    final session = await Navigator.of(context).push<VncSession>(
      MaterialPageRoute(
        builder: (_) => VncViewerPage(
          host: host,
          port: port,
          username: b.username,
          password: b.password,
          tlsVerify: b.tlsVerify,
          title: b.name,
        ),
      ),
    );
    if (session != null) {
      // 离开查看器时会话已关闭。
    }
  }
}

class _BookmarkCard extends StatelessWidget {
  const _BookmarkCard({
    required this.bookmark,
    required this.onConnect,
    required this.onEdit,
    required this.onDelete,
  });

  final VncBookmark bookmark;
  final VoidCallback onConnect;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final viaTunnel = bookmark.viaProxyId != null;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        leading: CircleAvatar(
          child: Icon(viaTunnel ? Icons.vpn_key_outlined : Icons.lan_outlined),
        ),
        title: Text(bookmark.name),
        subtitle: Text(
          viaTunnel
              ? 'frpc 隧道 · ${bookmark.viaProxyName ?? bookmark.viaProxyId}'
              : '${bookmark.host}:${bookmark.port}',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(icon: const Icon(Icons.edit_outlined), onPressed: onEdit),
            IconButton(icon: const Icon(Icons.delete_outline), onPressed: onDelete),
          ],
        ),
        onTap: onConnect,
      ),
    );
  }
}
