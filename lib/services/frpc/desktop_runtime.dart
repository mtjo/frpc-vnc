library;

/// 桌面端 frpc 运行时：子进程方式运行随应用分发的 frpc 二进制。

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'frpc_log_parser.dart';
import 'frpc_runtime.dart';

/// 从 assets 提取 frpc 二进制到应用数据目录（首次运行或版本变更时）。
class FrpcBinary {
  FrpcBinary._(this.path);

  final String path;

  static const _version = '1'; // 二进制版本号，更新 frpc 时递增

  static Future<FrpcBinary> ensure() async {
    final dir = await getApplicationSupportDirectory();
    final binDir = Directory('${dir.path}/frpc');
    await binDir.create(recursive: true);
    final marker = File('${binDir.path}/.version');

    if (marker.existsSync() && marker.readAsStringSync() == _version) {
      final existing = _binaryPath(binDir.path);
      if (existing != null) return FrpcBinary._(existing);
    }

    final assetName = _assetName();
    if (assetName == null) {
      throw UnsupportedError('当前平台不支持内置 frpc');
    }
    final data = await rootBundle.load('assets/frpc/bin/$assetName');
    final path = '${binDir.path}/${assetName.contains('.exe') ? 'frpc.exe' : 'frpc'}';
    final f = File(path);
    await f.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', path]);
      // macOS：清除 quarantine 属性（不依赖外部下载时通常没有）。
      if (Platform.isMacOS) {
        await Process.run('xattr', ['-d', 'com.apple.quarantine', path],
            runInShell: true).catchError((_) => ProcessResult(0, 0, '', ''));
      }
    }
    await marker.writeAsString(_version);
    return FrpcBinary._(path);
  }

  static String? _binaryPath(String dir) {
    final unix = '$dir/frpc';
    final win = '$dir/frpc.exe';
    if (Platform.isWindows) return File(win).existsSync() ? win : null;
    return File(unix).existsSync() ? unix : null;
  }

  static String? _assetName() {
    if (Platform.isMacOS) {
      return const String.fromEnvironment('OS_ARCH') == 'x86_64'
          ? 'frpc-macos-amd64'
          : 'frpc-macos-arm64';
    }
    if (Platform.isWindows) return 'frpc-windows-amd64.exe';
    if (Platform.isLinux) return 'frpc-linux-amd64';
    return null;
  }
}

class DesktopFrpcRuntime implements FrpcRuntime {
  final _events = StreamController<FrpcEvent>.broadcast();
  final _processes = <String, Process>{};
  final _states = <String, FrpcState>{};
  final _logs = <String, List<String>>{};

  @override
  Stream<FrpcEvent> get events => _events.stream;

  late FrpcBinary _binary;

  @override
  Future<void> init() async {
    _binary = await FrpcBinary.ensure();
    await _killOrphans();
  }

  /// 清理上一个应用实例遗留的 frpc 子进程（其端口占用会让新实例
  /// 的 visitor 绑定失败）。仅匹配我们自己的运行目录特征。
  Future<void> _killOrphans() async {
    try {
      final result = await Process.run('pgrep', ['-f', 'frpc.toml']);
      final pids = (result.stdout as String)
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty);
      for (final pid in pids) {
        final ps = await Process.run('ps', ['-p', pid, '-o', 'command=']);
        final cmd = (ps.stdout as String).trim();
        if (cmd.contains('frpc.toml') && cmd.contains('frpc')) {
          await Process.run('kill', [pid]);
        }
      }
    } catch (_) {}
  }

  @override
  FrpcState stateOf(String profileId) => _states[profileId] ?? FrpcState.stopped;

  @override
  Future<void> start(String profileId, String toml) async {
    if (_processes.containsKey(profileId)) {
      throw StateError('frpc 已在运行');
    }
    final dir = await getApplicationSupportDirectory();
    final workDir = Directory('${dir.path}/frpc/run/$profileId');
    await workDir.create(recursive: true);
    final configFile = File('${workDir.path}/frpc.toml');
    await configFile.writeAsString(toml);

    _setState(profileId, FrpcState.starting);
    _logs[profileId] = [];

    try {
      final proc = await Process.start(
        _binary.path,
        ['-c', configFile.path],
        workingDirectory: workDir.path,
      );
      _processes[profileId] = proc;
      proc.stdout.transform(systemEncoding.decoder).listen((line) => _onLog(profileId, line));
      proc.stderr.transform(systemEncoding.decoder).listen((line) => _onLog(profileId, line));
      proc.exitCode.then((code) {
        _processes.remove(profileId);
        if (_states[profileId] != FrpcState.stopping) {
          _setState(profileId, FrpcState.stopped);
        }
        if (code != 0 && _states[profileId] != FrpcState.stopping) {
          _events.add(FrpcEvent(
            profileId: profileId,
            type: 'error',
            message: 'frpc 进程退出（代码 $code）',
          ));
        }
      });
    } catch (e) {
      _setState(profileId, FrpcState.error);
      _events.add(FrpcEvent(profileId: profileId, type: 'error', message: '启动 frpc 失败：$e'));
      rethrow;
    }
  }

  @override
  Future<void> stop(String profileId) async {
    final proc = _processes[profileId];
    if (proc == null) {
      _setState(profileId, FrpcState.stopped);
      return;
    }
    _setState(profileId, FrpcState.stopping);
    proc.kill();
    // 等待最多 3 秒后强杀。
    final exit = proc.exitCode.timeout(const Duration(seconds: 3), onTimeout: () {
      proc.kill(ProcessSignal.sigkill);
      return -1;
    });
    await exit;
    _processes.remove(profileId);
    _setState(profileId, FrpcState.stopped);
  }

  @override
  Future<void> stopAll() async {
    await Future.wait([for (final id in _processes.keys.toList()) stop(id)]);
  }

  void _onLog(String profileId, String line) {
    if (line.trim().isEmpty) return;
    final l = _logs.putIfAbsent(profileId, () => []);
    l.add(line);
    if (l.length > 500) l.removeAt(0);
    _events.add(FrpcEvent(profileId: profileId, type: 'log', data: {'line': line}));

    final parsed = parseFrpcLog(line);
    if (parsed.isLoginSuccess) {
      _setState(profileId, FrpcState.running);
    } else if (parsed.isLoginFailed) {
      _setState(profileId, FrpcState.error);
      _events.add(FrpcEvent(profileId: profileId, type: 'error', message: parsed.text));
    } else if (parsed.isProxySuccess) {
      _events.add(FrpcEvent(
        profileId: profileId,
        type: 'proxy',
        data: {'proxy': parsed.proxyName, 'status': 'running'},
      ));
    } else if (parsed.isProxyError) {
      _events.add(FrpcEvent(
        profileId: profileId,
        type: 'proxy',
        data: {'proxy': parsed.proxyName, 'status': 'error', 'message': parsed.text},
      ));
    }
  }

  void _setState(String profileId, FrpcState s) {
    _states[profileId] = s;
    _events.add(FrpcEvent(profileId: profileId, type: 'state', data: {'state': s.name}));
  }

  /// 最近日志（用于状态页展示）。
  List<String> recentLogs(String profileId) => List.of(_logs[profileId] ?? const []);
}
