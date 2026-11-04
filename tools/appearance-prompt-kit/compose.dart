/// 变体提示词组合器：上游动作提示词 + 变体角色修饰 → 每动作一段完整
/// 可复制的视频生成提示词。
///
/// 用法（在本仓库根目录）：
///   dart tools/appearance-prompt-kit/compose.dart \
///     --variant rain \
///     --actions "/path/to/桌面宠物 10 秒动作提示词.md"
///
/// 可选：--out build/appearance-prompts（默认）、--all（一次性产出全部变体）。
/// 产物：out 目录下的 变体/动作名.md 与 INDEX.md（含逐段生成检查单）。
/// 动作文件来自上游仓库 prompts/ 目录（见 README），本仓库不搬运全文。
library;

import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final options = _parseArgs(args);
  if (options == null) return;

  final kitDir = File.fromUri(Platform.script).parent;
  final prefix = _readFile(
    File('${kitDir.path}${Platform.pathSeparator}prefix.md'),
  );
  final variantsFile = File(
    '${kitDir.path}${Platform.pathSeparator}variants.json',
  );
  final variants =
      jsonDecode(_readFile(variantsFile)) as Map<String, dynamic>;
  final baseCharacter = variants['baseCharacter'] as String;
  final sharedIdentity = variants['sharedIdentity'] as String;
  final specs = variants['variants'] as Map<String, dynamic>;

  final wanted = options.all
      ? specs.keys.toList()
      : [options.variant!];
  for (final id in wanted) {
    final spec = specs[id];
    if (spec is! Map<String, dynamic>) {
      stderr.writeln('未知变体：$id（可用：${specs.keys.join('、')}）');
      exitCode = 64;
      return;
    }
    _composeOne(
      variantId: id,
      label: spec['label'] as String? ?? id,
      character: spec['character'] as String,
      baseCharacter: baseCharacter,
      sharedIdentity: sharedIdentity,
      prefix: prefix,
      actionsPath: options.actions,
      outRoot: options.out,
    );
  }
}

class _Options {
  const _Options({
    required this.actions,
    required this.out,
    this.variant,
    this.all = false,
  });

  final String actions;
  final String out;
  final String? variant;
  final bool all;
}

_Options? _parseArgs(List<String> args) {
  String? variant;
  String? actions;
  var out = 'build${Platform.pathSeparator}appearance-prompts';
  var all = false;

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--variant':
        variant = args[++i];
      case '--actions':
        actions = args[++i];
      case '--out':
        out = args[++i];
      case '--all':
        all = true;
      default:
        stderr.writeln('未知参数：${args[i]}');
        stderr.writeln(
          '用法：dart compose.dart --variant rain --actions <上游动作提示词.md> [--out 输出目录] [--all]',
        );
        return null;
    }
  }
  if (actions == null || (!all && variant == null)) {
    stderr.writeln('缺少 --actions 或 --variant（或改用 --all）。');
    stderr.writeln(
      '动作提示词下载：https://github.com/PC2005-cloud/dsh-pet 的 prompts/ 目录',
    );
    return null;
  }
  return _Options(actions: actions, out: out, variant: variant, all: all);
}

String _readFile(File file) {
  if (!file.existsSync()) {
    stderr.writeln('文件不存在：${file.path}');
    exitCode = 66;
    exit(exitCode);
  }
  return file.readAsStringSync();
}

void _composeOne({
  required String variantId,
  required String label,
  required String character,
  required String baseCharacter,
  required String sharedIdentity,
  required String prefix,
  required String actionsPath,
  required String outRoot,
}) {
  final actions = _splitActions(_readFile(File(actionsPath)));
  if (actions.isEmpty) {
    stderr.writeln('动作文件里没有找到任何「## 动作名」小节：$actionsPath');
    exitCode = 65;
    return;
  }

  final outDir = Directory(
    '$outRoot${Platform.pathSeparator}$variantId',
  )..createSync(recursive: true);

  final index = StringBuffer()
    ..writeln('# $variantId · $label — 生成清单')
    ..writeln()
    ..writeln('共 ${actions.length} 段。逐段生成 10 秒 16:9 绿幕视频，逐段过')
    ..writeln('检查单后再进素材链；任何一段不达标都重生成该段，不要带病转码。')
    ..writeln()
    ..writeln('| 动作 | 提示词文件 | 首尾帧一致 | 画幅安全 | 抠像干净 |')
    ..writeln('| --- | --- | --- | --- | --- |');
  for (final action in actions) {
    // 角色名整体替换成变体描述：上游动作文本全部以基础角色名行文。
    final body = action.body.replaceAll(baseCharacter, character);
    File(
      '${outDir.path}${Platform.pathSeparator}${action.name}.md',
    ).writeAsStringSync('''
# $variantId · ${action.name}

$prefix

## 角色（$label）

$character
（$sharedIdentity。）

## 动作：${action.name}

$body
''');
    index.writeln('| ${action.name} | ${action.name}.md | ☐ | ☐ | ☐ |');
  }
  index
    ..writeln()
    ..writeln('- 首尾帧一致：第一帧 = 最后一帧 = 标准正面站立、无道具残留。')
    ..writeln('- 画幅安全：任何一帧（含呆毛/帽尖/道具最高点）距边缘 ≥10% 画幅。')
    ..writeln('- 抠像干净：纯 #00FF00 背景，无阴影、无渐变、无杂物。')
    ..writeln()
    ..writeln('生成完成后按 README 的「素材链 → 落位 → 登记」三步收尾。');
  File('${outDir.path}${Platform.pathSeparator}INDEX.md').writeAsStringSync(
    index.toString(),
  );
  stdout.writeln('✔ $variantId：${actions.length} 段 → ${outDir.path}');
}

class _Action {
  const _Action(this.name, this.body);
  final String name;
  final String body;
}

/// 动作文件按「## 」分节：第一节是通用前缀（跳过，用本目录 prefix.md）。
List<_Action> _splitActions(String source) {
  final actions = <_Action>[];
  final sections = source.split(RegExp(r'^## ', multiLine: true));
  for (final section in sections.skip(1)) {
    final lineBreak = section.indexOf('\n');
    if (lineBreak < 0) continue;
    final name = section.substring(0, lineBreak).trim();
    // 去掉节尾的水平分割线与首尾空白。
    final body = section
        .substring(lineBreak + 1)
        .replaceAll(RegExp(r'^---\s*$|^---\s*$', multiLine: true), '')
        .trim();
    if (name.isNotEmpty && body.isNotEmpty) actions.add(_Action(name, body));
  }
  return actions;
}
