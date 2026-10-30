/// 单实例锁：桌宠常驻后台，多开会让状态推送与点击穿透互相打架。
///
/// 用文件排他锁而不是端口探测：进程异常退出时锁会自动释放，不会留下“假占用”。
library;

import 'dart:io';

import 'paths/app_paths.dart';

class SingleInstance {
  SingleInstance._();

  static RandomAccessFile? _handle;

  /// 抢到锁返回 true；已有实例在跑返回 false。
  static Future<bool> acquire() async {
    AppPaths.ensure();
    final file = File(
      '${AppPaths.root.path}${Platform.pathSeparator}instance.lock',
    );
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
      _handle = handle;
      return true;
    } on FileSystemException {
      await handle.close();
      return false;
    }
  }

  static Future<void> release() async {
    final handle = _handle;
    _handle = null;
    if (handle == null) return;
    await handle.close();
  }
}
