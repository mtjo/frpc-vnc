library;

/// 应用数据持久化：profiles 与书签存储为 JSON 文件。

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../models/frpc_profile.dart';

class AppStore {
  AppStore._();
  static final AppStore instance = AppStore._();

  List<FrpcProfile> profiles = [];
  List<VncBookmark> bookmarks = [];

  File? _file;

  Future<void> load() async {
    final dir = await getApplicationSupportDirectory();
    _file = File('${dir.path}/frpc_vnc.json');
    if (!_file!.existsSync()) return;
    try {
      final data = jsonDecode(_file!.readAsStringSync()) as Map<String, dynamic>;
      profiles = [
        for (final p in (data['profiles'] as List? ?? []))
          FrpcProfile.fromJson((p as Map).cast<String, dynamic>())
      ];
      bookmarks = [
        for (final b in (data['bookmarks'] as List? ?? []))
          VncBookmark.fromJson((b as Map).cast<String, dynamic>())
      ];
    } catch (_) {
      // 损坏的配置文件不阻塞启动。
      profiles = [];
      bookmarks = [];
    }
  }

  Future<void> save() async {
    if (_file == null) return;
    final data = {
      'profiles': [for (final p in profiles) p.toJson()],
      'bookmarks': [for (final b in bookmarks) b.toJson()],
    };
    await _file!.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  }
}

/// 生成短 id。
String newId() {
  final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final rand = ((DateTime.now().microsecondsSinceEpoch * 7919) % 0xFFFFF)
      .toRadixString(36)
      .padLeft(4, '0');
  return '$ts-$rand';
}
