/// 隐私权限中心：四项能力授权的单一事实来源与运行时门禁。
///
/// 所有“会看到用户数据/会打扰用户”的路径（前台应用感知、正文读取、
/// 记忆写入、主动关心）都必须先过这里，不允许各自再读 config 开关。
/// 首次启动时把旧配置 `linkage.contentRead` 迁移为 screenAwareness，
/// 之后 privacy.json 即为唯一权威，config 里的旧字段不再被读取。
library;

import 'dart:io';

import '../core/result.dart';
import '../persona/profile_store.dart';

class PrivacyCenter {
  PrivacyCenter({Directory? directory, bool legacyContentRead = false})
    : _store = ProfileStore(directory: directory),
      _settings = PrivacySettings(screenAwareness: legacyContentRead);

  final ProfileStore _store;
  PrivacySettings _settings;

  PrivacySettings get settings => _settings;

  /// 运行时门禁：未知能力一律拒绝（宁可少做，不可越权）。
  bool allowed(String capability) => switch (capability) {
    'screenAwareness' => _settings.screenAwareness,
    'appWatch' => _settings.appWatch,
    'memoryRecording' => _settings.memoryRecording,
    'proactiveCare' => _settings.proactiveCare,
    _ => false,
  };

  /// 启动时加载：privacy.json 不存在视为首次启动，用旧 contentRead 初始化。
  /// 读取失败（文件损坏）大声返回 Failure，由装配层气泡告知，绝不静默覆盖。
  Result<void> load() {
    if (!_store.hasPrivacy) {
      return update(_settings);
    }
    switch (_store.loadPrivacy()) {
      case Success(value: final settings):
        _settings = settings;
        return const Success(null);
      case Failure(:final code, :final reason):
        return Failure(code, reason);
    }
  }

  /// 更新并落盘：只有写成功才改内存态，避免“界面显示已关、实际还在读”。
  Result<void> update(PrivacySettings settings) {
    switch (_store.savePrivacy(settings)) {
      case Success():
        _settings = settings;
        return const Success(null);
      case Failure(:final code, :final reason):
        return Failure(code, reason);
    }
  }
}
