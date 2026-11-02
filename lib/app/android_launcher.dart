/// Android 启动引导页：悬浮窗权限 + 通知权限 + 启动桌宠服务。
///
/// 桌宠本体在 PetOverlayService 的悬浮窗引擎里，这里只是“装机向导”；
/// 授权完成后启动服务即可回到桌面，宠物会悬浮在所有应用之上。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AndroidLauncherApp extends StatelessWidget {
  const AndroidLauncherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '大肥鱼助手',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const LauncherPage(),
    );
  }
}

class LauncherPage extends StatefulWidget {
  const LauncherPage({super.key});

  @override
  State<LauncherPage> createState() => _LauncherPageState();
}

class _LauncherPageState extends State<LauncherPage> with WidgetsBindingObserver {
  static const _engine = MethodChannel('dsh_pet/engine');

  bool _hasOverlayPermission = false;
  bool _hasNotifications = false;
  bool _petStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从系统授权页返回时刷新开关状态。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshPermissions();
  }

  Future<void> _refreshPermissions() async {
    final overlay = await _engine.invokeMethod<bool>('hasOverlayPermission') ?? false;
    final notifications = await _engine.invokeMethod<bool>('hasNotifications') ?? true;
    if (!mounted) return;
    setState(() {
      _hasOverlayPermission = overlay;
      _hasNotifications = notifications;
    });
  }

  Future<void> _openOverlaySettings() async {
    await _engine.invokeMethod<void>('openOverlaySettings');
  }

  Future<void> _requestNotifications() async {
    await _engine.invokeMethod<void>('requestNotifications');
  }

  Future<void> _startPet() async {
    await _engine.invokeMethod<void>('startPet');
    if (!mounted) return;
    setState(() => _petStarted = true);
  }

  Future<void> _stopPet() async {
    await _engine.invokeMethod<void>('stopPet');
    if (!mounted) return;
    setState(() => _petStarted = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('大肥鱼助手')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _stepCard(
            index: 1,
            title: '允许显示在其他应用上层',
            subtitle: _hasOverlayPermission ? '已授权' : '宠物要悬浮在桌面上，需要这个权限',
            done: _hasOverlayPermission,
            action: _hasOverlayPermission
                ? null
                : FilledButton(onPressed: _openOverlaySettings, child: const Text('去授权')),
          ),
          _stepCard(
            index: 2,
            title: '开启通知',
            subtitle: _hasNotifications ? '已开启' : '常驻通知是宠物的“托盘”（对话/设置/退出入口）',
            done: _hasNotifications,
            action: _hasNotifications
                ? null
                : FilledButton(onPressed: _requestNotifications, child: const Text('去开启')),
          ),
          _stepCard(
            index: 3,
            title: '放宠物上桌',
            subtitle: _petStarted ? '宠物已在桌面，可回到桌面或其他应用' : '启动后宠物悬浮在所有应用之上',
            done: _petStarted,
            action: FilledButton(
              onPressed: _hasOverlayPermission ? (_petStarted ? _stopPet : _startPet) : null,
              child: Text(_petStarted ? '收起宠物' : '启动大肥鱼助手'),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _hasOverlayPermission ? '' : '提示：授权页里找到「大肥鱼助手」并打开开关，返回本页即可。',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _stepCard({
    required int index,
    required String title,
    required String subtitle,
    required bool done,
    Widget? action,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              done ? Icons.check_circle : Icons.radio_button_unchecked,
              color: done ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (action != null) ...[const SizedBox(width: 12), action],
          ],
        ),
      ),
    );
  }
}
