/// API Key 存取：优先系统安全存储（Keychain），不可用时回退到 0600 文件。
///
/// 桌宠没有 App Sandbox（要跨应用注入/读窗口），某些签名环境里 Keychain
/// 可能不可用；回退路径保证“功能能用”，同时不把 key 写进 config.jsonc。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/paths/app_paths.dart';

class AiKeyStore {
  AiKeyStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'dsh_pet_flutter.ai.key';
  final FlutterSecureStorage _storage;

  Future<String> read() async {
    try {
      final value = await _storage.read(key: _key);
      if (value != null && value.isNotEmpty) return value;
    } on Object catch (error) {
      debugPrint('[pet] 安全存储读取失败，尝试文件：$error');
    }
    return _readFile();
  }

  Future<void> write(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      await clear();
      return;
    }
    try {
      await _storage.write(key: _key, value: trimmed);
      _deleteFile();
    } on Object catch (error) {
      debugPrint('[pet] 安全存储写入失败，回退 0600 文件：$error');
      _writeFile(trimmed);
    }
  }

  Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } on Object catch (error) {
      debugPrint('[pet] 安全存储清除失败：$error');
    }
    _deleteFile();
  }

  String _readFile() {
    try {
      final file = AppPaths.aiKeyFile;
      if (!file.existsSync()) return '';
      return file.readAsStringSync().trim();
    } on Object catch (error) {
      debugPrint('[pet] 读取 key 文件失败：$error');
      return '';
    }
  }

  void _writeFile(String value) {
    try {
      AppPaths.ensure();
      final file = AppPaths.aiKeyFile;
      file.writeAsStringSync(value, flush: true);
      if (Platform.isMacOS || Platform.isLinux) {
        Process.runSync('chmod', ['600', file.path]);
      }
    } on Object catch (error) {
      debugPrint('[pet] 写入 key 文件失败：$error');
    }
  }

  void _deleteFile() {
    try {
      final file = AppPaths.aiKeyFile;
      if (file.existsSync()) file.deleteSync();
    } on Object catch (error) {
      debugPrint('[pet] 删除 key 文件失败：$error');
    }
  }
}
