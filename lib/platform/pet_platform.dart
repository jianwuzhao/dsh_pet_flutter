/// 平台能力封装：窗口穿透、全局光标、前台应用、正文读取、按键注入。
///
/// 为什么集中在一个类而不是散落到各功能模块：这些能力都只在原生侧存在，
/// 且都带“平台不支持 / 未授权”这两种结构化失败，集中管理能让降级逻辑只有一处。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

class AppActivation {
  const AppActivation({
    required this.bundleId,
    required this.name,
    required this.pid,
  });

  final String bundleId;
  final String name;
  final int pid;
}

class FocusedContent {
  const FocusedContent({
    required this.bundleId,
    required this.title,
    required this.text,
  });

  final String bundleId;
  final String title;
  final String text;
}

/// 全局光标事件：位置是窗口本地坐标，[down] 是鼠标左键是否按下。
///
/// 桌宠窗口只覆盖一块屏，跨屏拖动时 Flutter 的 pan 可能被系统取消；
/// 有了按下状态，Dart 可以靠这条全局流继续拖、并在松开时收尾。
class PetPointer {
  const PetPointer({required this.position, required this.down});

  final Offset position;
  final bool down;
}

/// 换屏结果：新窗口尺寸 + 指针在新窗口里的本地坐标。
class ScreenMove {
  const ScreenMove({
    required this.index,
    required this.size,
    required this.pointer,
  });

  final int index;
  final Size size;
  final Offset pointer;
}

class PetPlatform {
  PetPlatform({MethodChannel? methods})
    : _window = const MethodChannel('dsh_pet/window'),
      _content = const MethodChannel('dsh_pet/content'),
      _input = const MethodChannel('dsh_pet/input');

  final MethodChannel _window;
  final MethodChannel _content;
  final MethodChannel _input;

  /// macOS 与 Windows 各有一套原生实现（MainFlutterWindow.swift / pet_bridge.cpp），
  /// Android 由 PetOverlayService 承载；三端通道协议完全一致，其余平台走降级分支。
  static bool get _native =>
      Platform.isMacOS || Platform.isWindows || Platform.isAndroid;

  /// 触摸平台（Android）：没有 hover 光标，穿透窗下的手势由原生哨兵层
  /// 转成光标事件流驱动，拖拽/点击不经过 Flutter 手势系统。
  static bool get isTouch => Platform.isAndroid;

  /// 托盘（菜单栏/通知区图标）：原生侧点击后回调到这里。
  static const MethodChannel _tray = MethodChannel('dsh_pet/tray');

  /// 托盘动作（openPanel: chat / settings）。桌面端没有托盘时什么都不发生。
  void listenTray(void Function(String action) handler) {
    if (!_native) return;
    _tray.setMethodCallHandler((call) async {
      if (call.method == 'openPanel') {
        handler(call.arguments as String? ?? 'chat');
      }
      return null;
    });
  }

  static bool get isDesktop => Platform.isMacOS || Platform.isWindows;

  /// 是否能收到系统级光标流（macOS / Windows 原生轮询实现）。
  /// 其他平台跨屏换窗没有全局指针兜底，拖动取消只能按普通取消处理。
  static bool get hasGlobalCursor => _native;

  /// 全局光标（窗口内坐标）+ 左键状态。无原生实现的平台返回空流。
  Stream<PetPointer> get cursor {
    if (!_native) return const Stream.empty();
    return const EventChannel('dsh_pet/cursor').receiveBroadcastStream().map((
      event,
    ) {
      final map = event as Map<Object?, Object?>;
      return PetPointer(
        position: Offset(
          (map['x'] as num?)?.toDouble() ?? 0,
          (map['y'] as num?)?.toDouble() ?? 0,
        ),
        down: map['down'] == true,
      );
    });
  }

  /// 前台应用切换事件。
  Stream<AppActivation> get appActivations {
    if (!_native) return const Stream.empty();
    return const EventChannel('dsh_pet/app').receiveBroadcastStream().map((
      event,
    ) {
      final map = event as Map<Object?, Object?>;
      return AppActivation(
        bundleId: map['bundleId'] as String? ?? '',
        name: map['name'] as String? ?? '',
        pid: (map['pid'] as num?)?.toInt() ?? 0,
      );
    });
  }

  /// 全部真实屏幕的可见区（窗口本地坐标，主屏排最前）。
  Future<List<Rect>> getScreens() async {
    if (!_native) return const [];
    final raw = await _window.invokeMethod<List<Object?>>('getScreens');
    if (raw == null) return const [];
    return [
      for (final item in raw)
        if (item is Map<Object?, Object?>)
          Rect.fromLTWH(
            (item['x'] as num?)?.toDouble() ?? 0,
            (item['y'] as num?)?.toDouble() ?? 0,
            (item['width'] as num?)?.toDouble() ?? 0,
            (item['height'] as num?)?.toDouble() ?? 0,
          ),
    ];
  }

  /// 屏幕热插拔 / 分辨率变化时原生侧推送，回调里重取 getScreens。
  void onScreensChanged(void Function() callback) {
    if (!_native) return;
    _window.setMethodCallHandler((call) async {
      if (call.method == 'screensChanged') callback();
      return null;
    });
  }

  /// 把单屏窗口搬到另一块显示器。返回新窗口尺寸与指针的本地坐标，
  /// 调用方据此把宠物重新摆到指针下方。
  Future<ScreenMove?> moveToScreen(int index) async {
    if (!_native) return null;
    final raw = await _window.invokeMapMethod<String, Object?>('moveToScreen', {
      'index': index,
    });
    if (raw == null) return null;
    final pointer = raw['pointer'];
    final pointerMap = pointer is Map ? pointer : const <Object?, Object?>{};
    return ScreenMove(
      index: (raw['index'] as num?)?.toInt() ?? index,
      size: Size(
        (raw['width'] as num?)?.toDouble() ?? 0,
        (raw['height'] as num?)?.toDouble() ?? 0,
      ),
      pointer: Offset(
        (pointerMap['x'] as num?)?.toDouble() ?? 0,
        (pointerMap['y'] as num?)?.toDouble() ?? 0,
      ),
    );
  }

  Future<void> setInteractive(bool interactive) async {
    if (!_native) return;
    await _window.invokeMethod<void>('setInteractive', interactive);
  }

  /// 触摸平台专用：把宠物命中区同步给原生哨兵层（窗口本地逻辑坐标）。
  /// 哨兵只盖住宠物身体，默认穿透态下第一下触摸才收得到。
  Future<void> updateHitRect(Rect rect) async {
    if (!isTouch) return;
    await _window.invokeMethod<void>('updateHitRect', {
      'x': rect.left,
      'y': rect.top,
      'width': rect.width,
      'height': rect.height,
    });
  }

  Future<void> setFocusable(bool focusable) async {
    if (!_native) return;
    await _window.invokeMethod<void>('setFocusable', focusable);
  }

  Future<void> setAlwaysOnTop(bool onTop) async {
    if (!_native) return;
    await _window.invokeMethod<void>('setAlwaysOnTop', onTop);
  }

  // ---------------------------------------------------------------------------
  // 窗口可见性：事件服务把 /window/* 暴露成诊断端点，宠物藏丢时
  // 一条 curl 就能拉回来，不用用户摸托盘。
  // ---------------------------------------------------------------------------

  Future<bool> isWindowVisible() async {
    if (!_native) return true;
    return await _window.invokeMethod<bool>('isVisible') ?? true;
  }

  /// 进程视角的窗口/屏幕全量状态（frame、并集、屏幕列表）——多屏错位时对账用。
  Future<Map<String, Object?>?> windowDiagnostics() async {
    if (!_native) return null;
    return await _window.invokeMapMethod<String, Object?>('windowState');
  }

  Future<void> showWindow() async {
    if (!_native) return;
    await _window.invokeMethod<void>('showWindow');
  }

  Future<void> hideWindow() async {
    if (!_native) return;
    await _window.invokeMethod<void>('hideWindow');
  }

  Future<void> quit() async {
    if (!_native) {
      exit(0);
    }
    await _window.invokeMethod<void>('quit');
  }

  Future<FocusedContent?> readFocusedContent() async {
    if (!_native) return null;
    final raw = await _content.invokeMapMethod<String, Object?>(
      'readFocusedText',
    );
    if (raw == null) return null;
    return FocusedContent(
      bundleId: raw['bundleId'] as String? ?? '',
      title: raw['title'] as String? ?? '',
      text: raw['text'] as String? ?? '',
    );
  }

  Future<bool> isAccessibilityTrusted() async {
    if (!_native) return false;
    // Windows 读取 UIA 无需授权，原生侧恒返回 true。
    return await _content.invokeMethod<bool>('isTrusted') ?? false;
  }

  /// 系统通知：显式 notify 事件/自动化脚本用；未授权或原生不可用时抛 PlatformException。
  Future<void> notify({required String title, required String body}) async {
    if (!_native) return;
    await _content.invokeMethod<void>('notify', {'title': title, 'body': body});
  }

  Future<bool> requestAccessibility() async {
    if (!_native) return false;
    return await _content.invokeMethod<bool>('requestTrust') ?? false;
  }

  Future<bool> activateApp(String bundleId) async {
    if (!_native) return false;
    // Windows 侧 bundleId 约定为 exe 名（如 Trae.exe），原生桥按进程可执行文件匹配。
    return await _input.invokeMethod<bool>('activateApp', {
          'bundleId': bundleId,
        }) ??
        false;
  }

  Future<bool> pasteAndSubmit() async {
    if (!_native) return false;
    return await _input.invokeMethod<bool>('pasteAndSubmit') ?? false;
  }

  Future<bool> openUrl(String url) async {
    if (!_native) return false;
    return await _input.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
  }

  // ---------------------------------------------------------------------------
  // 全局快捷键：macOS Carbon RegisterEventHotKey，无需辅助功能授权。
  // Windows 首期不实现，register 恒返回 false（设置页据此提示不支持）。
  // ---------------------------------------------------------------------------

  /// 热键回调通道：原生侧 invoke，这里只挂 handler（照托盘通道模式）。
  static const MethodChannel _hotkey = MethodChannel('dsh_pet/hotkey');

  /// 注册全局快捷键，combo 为归一组合串（如 `cmd+shift+p`）。
  Future<bool> registerHotkey(String combo) async {
    if (!Platform.isMacOS) return false;
    try {
      return await _input.invokeMethod<bool>('registerHotkey', {
            'combo': combo,
          }) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> unregisterHotkey() async {
    if (!Platform.isMacOS) return false;
    try {
      return await _input.invokeMethod<bool>('unregisterHotkey') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// 原生热键回调：按下时触发（幂等注册，重复调用只保留最后一个 handler）。
  void listenHotkey(void Function() onPressed) {
    if (!Platform.isMacOS) return;
    _hotkey.setMethodCallHandler((call) async {
      if (call.method == 'hotkeyPressed') onPressed();
      return null;
    });
  }
}
