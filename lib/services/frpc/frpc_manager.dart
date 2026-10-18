library;

/// frpc 生命周期管理器（单例）。
///
/// 维护 Profile → 运行实例映射；对接平台对应的 FrpcRuntime；
/// 生成 TOML 并启动/停止 frpc。

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/frpc_profile.dart';
import '../frpc/desktop_runtime.dart';
import '../frpc/frpc_runtime.dart';
import '../frpc/mobile_runtime.dart';
import '../frpc/toml_codec.dart';
import '../store/app_store.dart';

class FrpcManager {
  FrpcManager._();
  static final FrpcManager instance = FrpcManager._();

  late final FrpcRuntime _runtime;
  final _states = <String, FrpcState>{};
  final _ctrl = StreamController<void>.broadcast();

  /// 状态变化通知（UI 监听后重建）。
  Stream<void> get onChange => _ctrl.stream;

  FrpcState stateOf(String profileId) => _states[profileId] ?? FrpcState.stopped;

  StreamSubscription? _sub;

  Future<void> init() async {
    _runtime = kIsWeb || defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS
        ? MobileFrpcRuntime()
        : DesktopFrpcRuntime();
    await _runtime.init();

    _sub = _runtime.events.listen((ev) {
      switch (ev.type) {
        case 'state':
          if (ev.profileId != null) {
            _states[ev.profileId!] =
                FrpcState.values.firstWhere((v) => v.name == ev.data['state'], orElse: () => FrpcState.stopped);
          }
        case 'error':
          if (ev.profileId != null) {
            _states[ev.profileId!] = FrpcState.error;
          }
      }
      _ctrl.add(null);
    });

    // 启动随应用自动开启的 Profile。
    await Future<void>.delayed(const Duration(milliseconds: 500));
    for (final p in AppStore.instance.profiles) {
      if (p.enabled) {
        startProfile(p).catchError((Object e) {});
      }
    }
  }

  /// 生成 Profile 的 TOML 配置。
  ///
  /// 应用托管的 frpc 强制日志输出到控制台：状态机依赖解析 stdout 判定
  /// "登录成功/代理启动"，若用户配置重定向到文件会导致状态失明。
  String buildToml(FrpcProfile profile) {
    final p = profile.copy();
    final log = p.extra['log'];
    if (log is Map) {
      log['to'] = 'console';
      log.remove('disablePrintColor');
    }
    return profileToToml(p);
  }

  Future<void> startProfile(FrpcProfile profile) async {
    if (stateOf(profile.id) == FrpcState.running ||
        stateOf(profile.id) == FrpcState.starting) {
      return;
    }
    await _runtime.start(profile.id, buildToml(profile));
  }

  Future<void> stopProfile(FrpcProfile profile) async {
    await _runtime.stop(profile.id);
  }

  /// 配置修改后重启。
  Future<void> restartProfile(FrpcProfile profile) async {
    final state = stateOf(profile.id);
    if (state != FrpcState.stopped) {
      await stopProfile(profile);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (profile.enabled || state != FrpcState.stopped) {
      await startProfile(profile);
    }
  }

  /// 最近日志（桌面端/移动端各自维护）。
  List<String> recentLogs(String profileId) {
    final r = _runtime;
    if (r is DesktopFrpcRuntime) return r.recentLogs(profileId);
    if (r is MobileFrpcRuntime) return r.recentLogs(profileId);
    return const [];
  }

  /// 列出所有运行中的 TCP 代理（本地端口），供 VNC 隧道连接选择。
  /// 从 Profile 定义推导（本地端口即隧道入口）。
  List<TcpProxy> runningTcpProxies() {
    final result = <TcpProxy>[];
    for (final p in AppStore.instance.profiles) {
      if (stateOf(p.id) != FrpcState.running) continue;
      for (final proxy in p.proxies) {
        if (proxy is TcpProxy) {
          result.add(proxy);
        }
      }
    }
    return result;
  }

  /// 列出所有运行中的 stcp/xtcp 访问者（本地绑定端口）。
  List<VisitorConfig> runningVisitors() {
    final result = <VisitorConfig>[];
    for (final p in AppStore.instance.profiles) {
      if (stateOf(p.id) != FrpcState.running) continue;
      result.addAll(p.visitors);
    }
    return result;
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _runtime.stopAll();
    await _ctrl.close();
  }
}
