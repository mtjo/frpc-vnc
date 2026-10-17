import 'package:flutter/material.dart';

import 'services/frpc/frpc_manager.dart';
import 'services/store/app_store.dart';
import 'ui/home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FrpcVncApp());
}

class FrpcVncApp extends StatelessWidget {
  const FrpcVncApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'frpc-vnc',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3B6FF6)),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3B6FF6),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: const Bootstrap(),
    );
  }
}

class Bootstrap extends StatefulWidget {
  const Bootstrap({super.key});

  @override
  State<Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<Bootstrap> {
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      await AppStore.instance.load();
      await FrpcManager.instance.init();
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomePage()),
        );
      }
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: _error == null
            ? const CircularProgressIndicator()
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 48),
                    const SizedBox(height: 12),
                    Text('初始化失败：$_error', textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton(onPressed: _init, child: const Text('重试')),
                  ],
                ),
              ),
      ),
    );
  }
}
