import 'dart:io';

import 'package:flutter/material.dart';

import 'app/pet_app.dart';
import 'core/paths/app_paths.dart';
import 'core/single_instance.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 桌宠常驻后台：多开会让状态推送与点击穿透互相干扰，第二个实例直接退出。
  if (!await SingleInstance.acquire()) {
    await _logBoot('已有桌宠实例在运行，本进程退出');
    exit(0);
  }
  await _logBoot('启动 pid=$pid');
  runApp(const PetApp());
}

/// 启动/退出审计写文件：进程静默消失时 stdout 没人看，文件能留下线索。
Future<void> _logBoot(String message) async {
  try {
    final directory = Directory('${AppPaths.root.path}/logs');
    await directory.create(recursive: true);
    final file = File('${directory.path}/boot.log');
    await file.writeAsString(
      '${DateTime.now().toIso8601String()} $message\n',
      mode: FileMode.append,
    );
  } on Object {
    // 审计日志失败不能阻断启动
  }
}
