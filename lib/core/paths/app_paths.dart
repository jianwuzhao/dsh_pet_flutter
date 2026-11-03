/// 用户数据目录。
///
/// 为什么不用 path_provider 的 appSupport：Trae skill / petctl 需要**稳定可预测**的路径来读 token
/// 与写事件，桌面端 `~/.dsh_pet_flutter` 与上游 `~/.dsh/pet-bridge` 的约定保持一致；
/// Windows 用 `%APPDATA%`，Android 无 HOME 环境变量，只能借 path_provider 拿应用私有目录。
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

class AppPaths {
  AppPaths._();

  static Directory? _rootOverride;

  /// 测试用：把数据目录指到临时目录。
  static void overrideRoot(Directory dir) => _rootOverride = dir;

  /// Android 引导引擎与悬浮窗引擎都在 main 早期就需要数据目录，
  /// 而 path_provider 只有异步 API：main() 里先 await 一次再 runApp。
  static Future<void> initForAndroid() async {
    if (!Platform.isAndroid || _rootOverride != null) return;
    final support = await getApplicationSupportDirectory();
    _rootOverride = support;
  }

  static Directory get root {
    final override = _rootOverride;
    if (override != null) return override;

    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        return Directory('$appData${Platform.pathSeparator}dsh_pet_flutter');
      }
    }
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      return Directory('$home${Platform.pathSeparator}.dsh_pet_flutter');
    }
    return Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}dsh_pet_flutter',
    );
  }

  static File get configFile =>
      File('${root.path}${Platform.pathSeparator}config.jsonc');
  static File get tokenFile =>
      File('${root.path}${Platform.pathSeparator}token');
  static File get memoryFile =>
      File('${root.path}${Platform.pathSeparator}memory.json');
  static File get positionFile =>
      File('${root.path}${Platform.pathSeparator}position.json');
  static File get aiKeyFile =>
      File('${root.path}${Platform.pathSeparator}ai_key');
  static File get logFile =>
      File('${root.path}${Platform.pathSeparator}pet.log');

  // ---- 四层核心的本地数据布局（全部在 root 下的子目录，原子写由各自仓库负责） ----

  /// 个性化层档案：人格DNA / 用户画像 / 情绪档案 / 隐私授权。
  static Directory get profileDir =>
      Directory('${root.path}${Platform.pathSeparator}profile');
  static File get personaDnaFile =>
      File('${profileDir.path}${Platform.pathSeparator}persona_dna.json');
  static File get userProfileFile =>
      File('${profileDir.path}${Platform.pathSeparator}user_profile.json');
  static File get emotionProfileFile =>
      File('${profileDir.path}${Platform.pathSeparator}emotion_profile.json');
  static File get privacyFile =>
      File('${profileDir.path}${Platform.pathSeparator}privacy.json');

  /// 记忆库：四类记忆各一个文件（fact/episode/preference/task）。
  static Directory get memoryDir =>
      Directory('${root.path}${Platform.pathSeparator}memory');
  static File memoryFileFor(String kind) =>
      File('${memoryDir.path}${Platform.pathSeparator}$kind.json');
  static File get memoryExportFile =>
      File('${root.path}${Platform.pathSeparator}memory_export.json');

  /// 学习治理层：反馈流水（append-only）与策略版本。
  static Directory get learningDir =>
      Directory('${root.path}${Platform.pathSeparator}learning');
  static File get feedbackFile =>
      File('${learningDir.path}${Platform.pathSeparator}feedback.jsonl');
  static File get policyFile =>
      File('${learningDir.path}${Platform.pathSeparator}policy.json');
  static Directory get policySnapshotsDir =>
      Directory('${learningDir.path}${Platform.pathSeparator}snapshots');

  /// 自主进化：反思流水（append-only）与经验准则（待确认/已生效）。
  static File get reflectionFile =>
      File('${learningDir.path}${Platform.pathSeparator}reflections.jsonl');
  static File get guidelineFile =>
      File('${learningDir.path}${Platform.pathSeparator}guidelines.json');

  /// 技能库：每技能一个目录（SKILL.md + history/），index.json 是常驻索引。
  static Directory get skillsDir =>
      Directory('${root.path}${Platform.pathSeparator}skills');
  static File get skillIndexFile =>
      File('${skillsDir.path}${Platform.pathSeparator}index.json');

  /// 技能治理审计流（append-only）：生成/晋升/停用/退役全留痕。
  static File get skillEventsFile =>
      File('${learningDir.path}${Platform.pathSeparator}skill_events.jsonl');

  static void ensure() {
    if (!root.existsSync()) root.createSync(recursive: true);
    // 四层数据子目录一并建好：各仓库只管写文件，不再各自 ensure。
    for (final dir in [profileDir, memoryDir, learningDir]) {
      if (!dir.existsSync()) dir.createSync(recursive: true);
    }
  }
}
