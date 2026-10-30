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

  /// 托盘（菜单栏图标）：原生侧点击后回调到这里。
  static const MethodChannel _tray = MethodChannel('dsh_pet/tray');

  /// 托盘动作（openPanel: chat / settings）。桌面端没有托盘时什么都不发生。
  void listenTray(void Function(String action) handler) {
    if (!Platform.isMacOS) return;
    _tray.setMethodCallHandler((call) async {
      if (call.method == 'openPanel') {
        handler(call.arguments as String? ?? 'chat');
      }
      return null;
    });
  }

  static bool get isDesktop => Platform.isMacOS || Platform.isWindows;

  /// 是否能收到系统级光标流（目前只有 macOS 实现）。
  /// 非 macOS 上跨屏换窗没有全局指针兜底，拖动取消只能按普通取消处理。
  static bool get hasGlobalCursor => Platform.isMacOS;

  /// 全局光标（窗口内坐标）+ 左键状态。非 macOS 返回空流。
  Stream<PetPointer> get cursor {
    if (!Platform.isMacOS) return const Stream.empty();
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
    if (!Platform.isMacOS) return const Stream.empty();
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
    if (!Platform.isMacOS) return const [];
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
    if (!Platform.isMacOS) return;
    _window.setMethodCallHandler((call) async {
      if (call.method == 'screensChanged') callback();
      return null;
    });
  }

  /// 把单屏窗口搬到另一块显示器。返回新窗口尺寸与指针的本地坐标，
  /// 调用方据此把宠物重新摆到指针下方。
  Future<ScreenMove?> moveToScreen(int index) async {
    if (!Platform.isMacOS) return null;
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
    if (!Platform.isMacOS && !Platform.isWindows) return;
    await _window.invokeMethod<void>('setInteractive', interactive);
  }

  Future<void> setFocusable(bool focusable) async {
    if (!Platform.isMacOS && !Platform.isWindows) return;
    await _window.invokeMethod<void>('setFocusable', focusable);
  }

  Future<void> setAlwaysOnTop(bool onTop) async {
    if (!Platform.isMacOS && !Platform.isWindows) return;
    await _window.invokeMethod<void>('setAlwaysOnTop', onTop);
  }

  // ---------------------------------------------------------------------------
  // 窗口可见性：事件服务把 /window/* 暴露成诊断端点，宠物藏丢时
  // 一条 curl 就能拉回来，不用用户摸托盘。
  // ---------------------------------------------------------------------------

  Future<bool> isWindowVisible() async {
    if (!Platform.isMacOS) return true;
    return await _window.invokeMethod<bool>('isVisible') ?? true;
  }

  /// 进程视角的窗口/屏幕全量状态（frame、并集、屏幕列表）——多屏错位时对账用。
  Future<Map<String, Object?>?> windowDiagnostics() async {
    if (!Platform.isMacOS) return null;
    return await _window.invokeMapMethod<String, Object?>('windowState');
  }

  Future<void> showWindow() async {
    if (!Platform.isMacOS) return;
    await _window.invokeMethod<void>('showWindow');
  }

  Future<void> hideWindow() async {
    if (!Platform.isMacOS) return;
    await _window.invokeMethod<void>('hideWindow');
  }

  Future<void> quit() async {
    if (!Platform.isMacOS && !Platform.isWindows) {
      exit(0);
    }
    await _window.invokeMethod<void>('quit');
  }

  Future<FocusedContent?> readFocusedContent() async {
    if (!Platform.isMacOS) return null;
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
    if (!Platform.isMacOS) return false;
    return await _content.invokeMethod<bool>('isTrusted') ?? false;
  }

  /// 系统通知：显式 notify 事件/自动化脚本用；未授权或原生不可用时抛 PlatformException。
  Future<void> notify({required String title, required String body}) async {
    if (!Platform.isMacOS) return;
    await _content.invokeMethod<void>('notify', {'title': title, 'body': body});
  }

  Future<bool> requestAccessibility() async {
    if (!Platform.isMacOS) return false;
    return await _content.invokeMethod<bool>('requestTrust') ?? false;
  }

  Future<bool> activateApp(String bundleId) async {
    if (!Platform.isMacOS) return false;
    return await _input.invokeMethod<bool>('activateApp', {
          'bundleId': bundleId,
        }) ??
        false;
  }

  Future<bool> pasteAndSubmit() async {
    if (!Platform.isMacOS) return false;
    return await _input.invokeMethod<bool>('pasteAndSubmit') ?? false;
  }

  Future<bool> openUrl(String url) async {
    if (!Platform.isMacOS) return false;
    return await _input.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
  }
}
