import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../services/vnc/vnc_session.dart';

/// TightVNC 文件传输面板（远端目录浏览 + 下载/上传）。
///
/// 本地目录固定使用应用下载目录（与下载文件互通），避免引入
/// 系统文件选择器插件。
class FileTransferSheet extends StatefulWidget {
  const FileTransferSheet({super.key, required this.session});

  final VncSession session;

  @override
  State<FileTransferSheet> createState() => _FileTransferSheetState();
}

class _FileTransferSheetState extends State<FileTransferSheet> {
  String _remotePath = '/';
  List<Map<String, Object?>> _entries = [];
  String? _error;
  bool _loading = true;
  bool _localListLoading = true;
  List<FileSystemEntity> _localFiles = [];
  double? _progress; // 0-1，null 表示空闲
  String _progressLabel = '';

  late final Directory _localDir;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final docs = await getApplicationDocumentsDirectory();
    _localDir = Directory('${docs.path}/exchange');
    if (!_localDir.existsSync()) _localDir.createSync(recursive: true);
    _refreshLocal();
    _refreshRemote(_remotePath);
    // 监听文件事件。
    widget.session.events.listen(_onFileEvent);
  }

  void _onFileEvent(Map<String, Object?> ev) {
    switch (ev['ev']) {
      case 'fileList':
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = null;
          _entries = (ev['entries'] as List).cast<Map<String, Object?>>();
          _entries.sort((a, b) {
            final da = a['isDir'] == true;
            final db = b['isDir'] == true;
            if (da != db) return da ? -1 : 1;
            return (a['name'] as String).compareTo(b['name'] as String);
          });
        });
      case 'fileError':
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = ev['error'] as String?;
        });
      case 'fileProgress':
        if (!mounted) return;
        final sent = ev['sent'] as int;
        final total = ev['total'] as int;
        setState(() {
          _progress = total > 0 ? sent / total : null;
          _progressLabel = '传输中… ${_fmtSize(sent)}${total > 0 ? ' / ${_fmtSize(total)}' : ''}';
        });
      case 'fileDone':
        if (!mounted) return;
        setState(() {
          _progress = null;
          _progressLabel = '完成';
        });
        _refreshLocal();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('传输完成'), duration: Duration(seconds: 2)),
        );
    }
  }

  void _refreshLocal() {
    setState(() => _localListLoading = true);
    final files = _localDir.listSync().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    setState(() {
      _localFiles = files;
      _localListLoading = false;
    });
  }

  void _refreshRemote(String path) {
    setState(() {
      _remotePath = path;
      _loading = true;
      _error = null;
    });
    widget.session.listFiles(path);
  }

  String _joinPath(String dir, String name) =>
      dir.endsWith('/') ? '$dir$name' : '$dir/$name';

  static String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      builder: (context, controller) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('文件传输（TightVNC / x11vnc 服务器）',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            if (_progress != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  children: [
                    LinearProgressIndicator(value: _progress),
                    Text(_progressLabel, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            Expanded(
              child: Row(
                children: [
                  // 远端
                  Expanded(
                    child: _RemotePane(
                      state: this,
                      session: widget.session,
                      scrollController: controller,
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  // 本地
                  Expanded(child: _buildLocalPane()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLocalPane() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              const Icon(Icons.phone_android, size: 16),
              const SizedBox(width: 4),
              const Expanded(child: Text('本机 exchange 目录', style: TextStyle(fontSize: 13))),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: _refreshLocal,
              ),
            ],
          ),
        ),
        if (_localListLoading)
          const CircularProgressIndicator()
        else if (_localFiles.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('（空）下载的文件会出现在这里'),
          )
        else
          Expanded(
            child: ListView.builder(
              itemCount: _localFiles.length,
              itemBuilder: (context, i) {
                final f = _localFiles[i];
                final stat = f.statSync();
                final name = f.path.split(Platform.pathSeparator).last;
                return ListTile(
                  dense: true,
                  leading: Icon(
                    stat.type == FileSystemEntityType.directory
                        ? Icons.folder
                        : Icons.insert_drive_file,
                    size: 20,
                  ),
                  title: Text(name, style: const TextStyle(fontSize: 13)),
                  subtitle: stat.type != FileSystemEntityType.directory
                      ? Text(_fmtSize(stat.size), style: const TextStyle(fontSize: 11))
                      : null,
                  trailing: IconButton(
                    icon: const Icon(Icons.upload, size: 20),
                    tooltip: '上传到当前远端目录',
                    onPressed: stat.type == FileSystemEntityType.file
                        ? () => widget.session.uploadFile(
                              f.path,
                              _joinPath(_remotePath, name),
                            )
                        : null,
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _RemotePane extends StatelessWidget {
  const _RemotePane({
    required this.state,
    required this.session,
    required this.scrollController,
  });

  final _FileTransferSheetState state;
  final VncSession session;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_upward, size: 18),
                tooltip: '上级目录',
                onPressed: () {
                  if (state._remotePath == '/') return;
                  final parent =
                      state._remotePath.substring(0, state._remotePath.lastIndexOf('/') + 1);
                  state._refreshRemote(parent.isEmpty ? '/' : parent);
                },
              ),
              Expanded(
                child: Text(state._remotePath,
                    style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: () => state._refreshRemote(state._remotePath),
              ),
            ],
          ),
        ),
        if (state._loading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (state._error != null)
          Expanded(
            child: Center(
              child: Text(
                '${state._error}\n（此功能需要 TightVNC / x11vnc 服务器）',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              controller: scrollController,
              itemCount: state._entries.length,
              itemBuilder: (context, i) {
                final e = state._entries[i];
                final isDir = e['isDir'] == true;
                final name = e['name'] as String;
                final size = e['size'] as int;
                return ListTile(
                  dense: true,
                  leading: Icon(
                    isDir ? Icons.folder : Icons.insert_drive_file,
                    size: 20,
                  ),
                  title: Text(name, style: const TextStyle(fontSize: 13)),
                  subtitle:
                      !isDir ? Text(_FileTransferSheetState._fmtSize(size), style: const TextStyle(fontSize: 11)) : null,
                  onTap: isDir
                      ? () => state._refreshRemote(state._joinPath(state._remotePath, name))
                      : null,
                  trailing: !isDir
                      ? IconButton(
                          icon: const Icon(Icons.download, size: 20),
                          tooltip: '下载到本机',
                          onPressed: () async {
                            final local = '${state._localDir.path}/$name';
                            session.downloadFile(
                              state._joinPath(state._remotePath, name),
                              local,
                            );
                          },
                        )
                      : const Icon(Icons.chevron_right, size: 18),
                );
              },
            ),
          ),
      ],
    );
  }
}
