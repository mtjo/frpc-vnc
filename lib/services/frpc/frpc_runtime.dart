library;

/// frpc 运行时统一抽象。
///
/// 桌面端实现以子进程方式运行官方 frpc 二进制；
/// 移动端实现通过 platform channel 调用 Go 桥接模块。

import 'dart:async';

/// frpc 运行状态机。
enum FrpcState { stopped, starting, running, stopping, error }

/// frpc 事件。
class FrpcEvent {
  FrpcEvent({required this.profileId, required this.type, this.data = const {}, this.message});

  /// 事件来源的 Profile id；全局事件（如运行时错误）为空。
  final String? profileId;

  /// state / log / proxy / error
  final String type;
  final Map<String, Object?> data;
  final String? message;
}

abstract class FrpcRuntime {
  /// 全局事件流（广播）。
  Stream<FrpcEvent> get events;

  Future<void> init();

  /// 以 TOML 配置启动指定 Profile 的 frpc。
  Future<void> start(String profileId, String toml);

  Future<void> stop(String profileId);

  Future<void> stopAll();

  FrpcState stateOf(String profileId);
}
