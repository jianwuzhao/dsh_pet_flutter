/// 用户数据目录。
///
/// 为什么不用 path_provider 的 appSupport：Trae skill / petctl 需要**稳定可预测**的路径来读 token
/// 与写事件，`~/.dsh_pet_flutter` 与上游 `~/.dsh/pet-bridge` 的约定保持一致。
library;

import 'dart:io';

class AppPaths {
  AppPaths._();

  static Directory? _rootOverride;

  /// 测试用：把数据目录指到临时目录。
  static void overrideRoot(Directory dir) => _rootOverride = dir;

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

  static void ensure() {
    if (!root.existsSync()) root.createSync(recursive: true);
  }
}
