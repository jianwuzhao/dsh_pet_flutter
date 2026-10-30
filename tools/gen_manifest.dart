/// 从上游 `vendor/config.jsonc` 生成 `assets/animations/manifest.json`。
///
/// 为什么生成而不是运行时读 config.jsonc：动画清单属于构建产物（与转码后的文件强绑定），
/// 生成时能一次性校验“配置里写了但素材没有”的动画名，缺失即显式报错（沿用上游不静默兜底的约定）。
///
/// 用法：dart run tools/gen_manifest.dart [--width 320] [--height 180] [--fps 12]
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsh_pet_flutter/core/config/jsonc.dart';

void main(List<String> args) {
  final root = Directory.current;
  final configFile = File('${root.path}/vendor/config.jsonc');
  final animDir = Directory('${root.path}/assets/animations');

  if (!configFile.existsSync()) {
    stderr.writeln('缺少 ${configFile.path}，先跑 tools/fetch_assets.sh');
    exit(1);
  }
  if (!animDir.existsSync()) {
    stderr.writeln('缺少 ${animDir.path}，先跑 tools/convert_assets.sh');
    exit(1);
  }

  final config = decodeJsonc(configFile.readAsStringSync()) as Map<String, dynamic>;
  final animations = (config['animations'] as Map<String, dynamic>?) ?? const {};
  final weights = (config['animationWeights'] as Map<String, dynamic>?) ?? const {};

  final available = animDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.webp'))
      .map((f) => f.uri.pathSegments.last.replaceAll('.webp', ''))
      .toSet();

  final referenced = <String>{};

  List<String> listOf(dynamic v) {
    final result = <String>[];
    if (v is String) result.add(v);
    if (v is List) {
      for (final item in v) {
        if (item is String) result.add(item);
      }
    }
    referenced.addAll(result);
    return result;
  }

  String? nameOf(dynamic v) => v is Map && v['name'] is String ? v['name'] as String : null;

  // moves：name 在 actions[].name 上，不是纯数组
  final moves = <Map<String, dynamic>>[];
  final movesRaw = animations['moves'];
  if (movesRaw is Map) {
    for (final raw in (movesRaw['actions'] as List? ?? const [])) {
      final name = nameOf(raw);
      if (name == null || name.isEmpty) continue;
      referenced.add(name);
      moves.add({
        'name': name,
        'params': (raw as Map)['params'] ?? const <String, dynamic>{},
      });
    }
  }

  final categories = <Map<String, dynamic>>[];
  for (final raw in (animations['categories'] as List? ?? const [])) {
    if (raw is! Map) continue;
    categories.add({
      'id': raw['id'],
      'weight': raw['weight'],
      'noMirror': raw['noMirror'] == true,
      'actions': listOf(raw['actions']),
    });
  }

  final events = <String, List<String>>{};
  final eventsRaw = animations['events'];
  if (eventsRaw is Map) {
    for (final entry in eventsRaw.entries) {
      events[entry.key as String] = listOf(entry.value);
    }
  }

  final missing = referenced.difference(available).toList()..sort();
  final unused = available.difference(referenced).toList()..sort();

  final manifest = {
    'generatedAt': DateTime.now().toIso8601String(),
    'width': int.tryParse(_option(args, '--width') ?? '') ?? 320,
    'height': int.tryParse(_option(args, '--height') ?? '') ?? 180,
    'fps': double.tryParse(_option(args, '--fps') ?? '') ?? 12,
    'names': available.toList()..sort(),
    'idle': listOf(animations['idle']),
    'turn': listOf(animations['turn']),
    'drag': listOf(animations['drag']),
    'clicks': listOf(animations['clicks']),
    'moves': {
      'default': movesRaw is Map ? (movesRaw['default'] ?? const {}) : const {},
      'actions': moves,
    },
    'categories': categories,
    'events': events,
    'weights': {
      'idle': weights['idle'] ?? 10,
      'turn': weights['turn'] ?? 5,
      'move': weights['move'] ?? 5,
    },
    'missing': missing,
    'unused': unused,
  };

  final out = File('${animDir.path}/manifest.json');
  out.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(manifest));

  stdout.writeln('写入 ${out.path}');
  stdout.writeln('素材 ${available.length} 个，引用 ${referenced.length} 个');
  if (unused.isNotEmpty) stdout.writeln('未被配置引用（保留）：${unused.length} 个');
  if (missing.isNotEmpty) {
    stderr.writeln('缺失素材 ${missing.length} 个：');
    for (final name in missing) {
      stderr.writeln('  - $name');
    }
    exit(1);
  }
}

String? _option(List<String> args, String key) {
  final index = args.indexOf(key);
  if (index < 0 || index + 1 >= args.length) return null;
  return args[index + 1];
}
