/// 全局快捷键：组合串解析（配置/设置页共用）+ 注册源。
///
/// 为什么只用 macOS Carbon RegisterEventHotKey：它不需要辅助功能授权，
/// 与“热键是唤起入口、不应设门槛”的定位一致；Windows 首期不实现。
library;

import '../core/result.dart';
import '../platform/pet_platform.dart';

/// 归一后的修饰键写法 → 显示/存储用的规范名。
const Map<String, String> _modifierAliases = {
  'cmd': 'cmd',
  'command': 'cmd',
  'meta': 'cmd',
  'ctrl': 'ctrl',
  'control': 'ctrl',
  'alt': 'alt',
  'option': 'alt',
  'shift': 'shift',
};

/// 支持的命名主键（解析时统一小写，别名归一到规范名）。
const Map<String, String> _namedKeyAliases = {
  'return': 'return',
  'enter': 'return',
  'esc': 'escape',
  'escape': 'escape',
  'tab': 'tab',
  'space': 'space',
  'delete': 'delete',
  'backspace': 'delete',
};

class HotkeySpec {
  const HotkeySpec({required this.modifiers, required this.key});

  /// 修饰键集合（规范名：cmd / ctrl / alt / shift）。
  final Set<String> modifiers;

  /// 主键（小写）：单字母、单数字、f1-f19 或命名键。
  final String key;

  /// 归一后的组合串，如 `cmd+shift+p`，写回配置用它。
  String get combo {
    final ordered = modifiers.toList()..sort();
    return [...ordered, key].join('+');
  }

  /// 解析组合串：按 `+` 切分，修饰键归一去重，主键只允许一个。
  /// 必须含 cmd / ctrl / alt 之一——没有主修饰键的组合会吞掉正常打字。
  static Result<HotkeySpec> parse(String input) {
    final raw = input.trim().toLowerCase();
    if (raw.isEmpty) {
      return const Failure('hotkey.parse', '快捷键为空');
    }
    final parts = raw
        .split('+')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) {
      return const Failure('hotkey.parse', '快捷键为空');
    }

    final modifiers = <String>{};
    String? key;
    for (final part in parts) {
      final modifier = _modifierAliases[part];
      if (modifier != null) {
        modifiers.add(modifier);
        continue;
      }
      if (key != null) {
        return Failure('hotkey.parse', '主键只允许一个：$input');
      }
      final named = _namedKeyAliases[part];
      if (named != null) {
        key = named;
        continue;
      }
      if (_isLetterOrDigit(part) || _isFunctionKey(part)) {
        key = part;
        continue;
      }
      return Failure('hotkey.parse', '无法识别的按键「$part」：只支持字母、数字、F1-F19 与命名键');
    }

    if (key == null) {
      return const Failure('hotkey.parse', '缺少主键：修饰键后面要跟一个按键');
    }
    if (!modifiers.any((name) => name != 'shift')) {
      return const Failure(
        'hotkey.parse',
        '至少需要 cmd / ctrl / alt 中的一个修饰键，否则会吞掉正常打字',
      );
    }
    return Success(HotkeySpec(modifiers: modifiers, key: key));
  }

  static bool _isLetterOrDigit(String part) {
    if (part.length != 1) return false;
    final code = part.codeUnitAt(0);
    final isLetter = code >= 0x61 && code <= 0x7A;
    final isDigit = code >= 0x30 && code <= 0x39;
    return isLetter || isDigit;
  }

  static bool _isFunctionKey(String part) {
    final match = RegExp(r'^f([1-9]|1[0-9])$').firstMatch(part);
    return match != null;
  }
}

/// 热键注册源：包装平台通道，同时维护“当前注册的组合”。
class HotkeySource {
  HotkeySource({PetPlatform? platform}) : _platform = platform ?? PetPlatform();

  final PetPlatform _platform;

  /// 当前已注册的归一组合串；未注册为空。
  String activeCombo = '';

  /// 注册（已注册时先注销旧的）。
  /// 解析失败或平台不支持/注册失败都返回 Failure，原因交由调用方提示。
  Future<Result<bool>> register(String combo) async {
    switch (HotkeySpec.parse(combo)) {
      case Success(value: final spec):
        if (activeCombo == spec.combo) return const Success(true);
        if (activeCombo.isNotEmpty) {
          await _platform.unregisterHotkey();
        }
        if (await _platform.registerHotkey(spec.combo)) {
          activeCombo = spec.combo;
          return const Success(true);
        }
        return const Failure('hotkey.register', '系统拒绝注册该快捷键（可能已被其他应用占用）');
      case Failure(:final code, :final reason):
        return Failure(code, reason);
    }
  }

  Future<bool> unregister() async {
    if (activeCombo.isEmpty) return true;
    if (await _platform.unregisterHotkey()) {
      activeCombo = '';
      return true;
    }
    return false;
  }

  /// 原生回调：热键按下（macOS：无需任何系统授权）。
  void listen(void Function() onPressed) {
    _platform.listenHotkey(onPressed);
  }
}
