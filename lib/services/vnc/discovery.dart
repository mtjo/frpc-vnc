/// Bonjour/mDNS 屏幕共享服务发现。
///
/// 新版 macOS 的屏幕共享监听端口在每次会话后会变化（不再固定 5900/5901），
/// 实际端口通过 Bonjour（`_rfb._tcp`）广播。本模块在直连被拒绝时用于
/// 自动发现目标机器的当前端口——与 Apple 自家"屏幕共享"客户端行为一致。

import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';

class DiscoveredScreenSharing {
  DiscoveredScreenSharing(this.name, this.host, this.port);

  final String name;
  final String host;
  final int port;

  @override
  String toString() => '$name ($host:$port)';
}

/// 在 [timeout] 内发现局域网内的屏幕共享服务。
Future<List<DiscoveredScreenSharing>> discoverScreenSharing({
  Duration timeout = const Duration(seconds: 5),
}) async {
  final discovery = BonsoirDiscovery(type: '_rfb._tcp', printLogs: false);
  await discovery.initialize();
  await discovery.start();

  final found = <DiscoveredScreenSharing>[];
  final completer = Completer<void>();

  late final StreamSubscription sub;
  sub = discovery.eventStream!.listen((event) async {
    switch (event) {
      case BonsoirDiscoveryServiceFoundEvent(:final service):
        await discovery.serviceResolver.resolveService(service);
      case BonsoirDiscoveryServiceResolvedEvent(:final service):
        if (service.host != null && service.port > 0) {
          found.add(DiscoveredScreenSharing(service.name, service.host!, service.port));
        }
      default:
        break;
    }
    if (!completer.isCompleted && found.isNotEmpty) {
      // 再等一小会儿，尽量收集全部实例（可能有同名多台机器）。
      Future<void>.delayed(const Duration(milliseconds: 800), () {
        if (!completer.isCompleted) completer.complete();
      });
    }
  });

  await completer.future.timeout(timeout, onTimeout: () {});
  await sub.cancel();
  await discovery.stop();
  return found;
}

/// 校验发现的服务确实位于目标 IP：实际拨号并检查远端地址。
///
/// mDNS 主机名可能重名（同名 Mac），以真实连接的远端地址为准。
Future<DiscoveredScreenSharing?> matchByDial(
  List<DiscoveredScreenSharing> services,
  String targetIp,
) async {
  for (final s in services) {
    try {
      final sock = await Socket.connect(s.host, s.port,
          timeout: const Duration(seconds: 2));
      final remote = sock.remoteAddress.address;
      sock.destroy();
      if (remote == targetIp) {
        return s;
      }
    } catch (_) {
      // 不可达，继续下一个。
    }
  }
  return null;
}
