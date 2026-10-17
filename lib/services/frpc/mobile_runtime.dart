library;

/// 移动端 frpc 运行时：platform channel 调用 Go 桥接模块。

import 'dart:async';

import 'package:flutter/services.dart';

import 'frpc_log_parser.dart';
import 'frpc_runtime.dart';

class MobileFrpcRuntime implements FrpcRuntime {
  static const _channel = MethodChannel('frpc_vnc/frpc');
  static const _events = EventChannel('frpc_vnc/frpc/events');

  final _eventCtrl = StreamController<FrpcEvent>.broadcast();
  final _states = <String, FrpcState>{};
  final _logs = <String, List<String>>{};
  StreamSubscription? _sub;

  @override
  Stream<FrpcEvent> get events => _eventCtrl.stream;

  @override
  Future<void> init() async {
    _sub ??= _events.receiveBroadcastStream().listen((dynamic data) {
      if (data is! Map) return;
      final m = data.cast<String, Object?>();
      final profileId = m['profileId'] as String?;
      final type = m['type'] as String?;
      switch (type) {
        case 'state':
          final s = FrpcState.values.firstWhere(
            (v) => v.name == m['state'],
            orElse: () => FrpcState.stopped,
          );
          _states[profileId ?? ''] = s;
          _eventCtrl.add(FrpcEvent(profileId: profileId, type: 'state', data: {'state': s.name}));
        case 'log':
          final line = (m['line'] as String?) ?? '';
          _logs.putIfAbsent(profileId ?? '', () => []).add(line);
          final parsed = parseFrpcLog(line);
          if (parsed.isLoginSuccess && profileId != null) {
            _states[profileId] = FrpcState.running;
            _eventCtrl.add(FrpcEvent(
              profileId: profileId,
              type: 'state',
              data: {'state': FrpcState.running.name},
            ));
          }
          _eventCtrl.add(FrpcEvent(profileId: profileId, type: 'log', data: {'line': line}));
        case 'error':
          if (profileId != null) _states[profileId] = FrpcState.error;
          _eventCtrl.add(FrpcEvent(
            profileId: profileId,
            type: 'error',
            message: (m['message'] as String?) ?? '未知错误',
          ));
      }
    });
  }

  @override
  FrpcState stateOf(String profileId) => _states[profileId] ?? FrpcState.stopped;

  @override
  Future<void> start(String profileId, String toml) async {
    _setState(profileId, FrpcState.starting);
    try {
      await _channel.invokeMethod<void>('start', {'profileId': profileId, 'toml': toml});
    } catch (e) {
      _setState(profileId, FrpcState.error);
      rethrow;
    }
  }

  @override
  Future<void> stop(String profileId) async {
    _setState(profileId, FrpcState.stopping);
    try {
      await _channel.invokeMethod<void>('stop', {'profileId': profileId});
      _setState(profileId, FrpcState.stopped);
    } catch (e) {
      _setState(profileId, FrpcState.error);
      rethrow;
    }
  }

  @override
  Future<void> stopAll() async {
    try {
      await _channel.invokeMethod<void>('stopAll');
    } finally {
      _states.clear();
    }
  }

  void _setState(String profileId, FrpcState s) {
    _states[profileId] = s;
    _eventCtrl.add(FrpcEvent(profileId: profileId, type: 'state', data: {'state': s.name}));
  }

  List<String> recentLogs(String profileId) => List.of(_logs[profileId] ?? const []);
}
