import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'connections_page.dart';
import 'frpc_profiles_page.dart';
import 'status_page.dart';

/// 主页：移动端底部导航 / 桌面端侧边导航。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;

  static const _pages = [
    ConnectionsPage(),
    FrpcProfilesPage(),
    StatusPage(),
  ];

  bool get _wide =>
      !kIsWeb &&
      (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  @override
  Widget build(BuildContext context) {
    final body = _pages[_index];

    if (_wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              labelType: NavigationRailLabelType.all,
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.desktop_windows_outlined),
                  selectedIcon: Icon(Icons.desktop_windows),
                  label: Text('连接'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.hub_outlined),
                  selectedIcon: Icon(Icons.hub),
                  label: Text('frpc'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.monitor_heart_outlined),
                  selectedIcon: Icon(Icons.monitor_heart),
                  label: Text('状态'),
                ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: body),
          ],
        ),
      );
    }

    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.desktop_windows_outlined),
            selectedIcon: Icon(Icons.desktop_windows),
            label: '连接',
          ),
          NavigationDestination(
            icon: Icon(Icons.hub_outlined),
            selectedIcon: Icon(Icons.hub),
            label: 'frpc',
          ),
          NavigationDestination(
            icon: Icon(Icons.monitor_heart_outlined),
            selectedIcon: Icon(Icons.monitor_heart),
            label: '状态',
          ),
        ],
      ),
    );
  }
}
