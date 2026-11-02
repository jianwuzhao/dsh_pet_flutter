import 'package:dsh_pet_flutter/core/result.dart';
import 'package:dsh_pet_flutter/gateway/hotkey_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HotkeySpec.parse 组合串解析', () {
    test('归一修饰键别名并去重排序', () {
      final result = HotkeySpec.parse('Meta+Command+SHIFT+p');
      final spec = (result as Success<HotkeySpec>).value;
      expect(spec.modifiers, {'cmd', 'shift'});
      expect(spec.key, 'p');
      expect(spec.combo, 'cmd+shift+p');
    });

    test('支持字母 / 数字 / F1-F19 / 命名键', () {
      for (final combo in ['cmd+a', 'ctrl+0', 'alt+f12', 'cmd+esc']) {
        final result = HotkeySpec.parse(combo);
        expect(result, isA<Success<HotkeySpec>>(), reason: combo);
      }
      expect(
        (HotkeySpec.parse('cmd+esc') as Success<HotkeySpec>).value.key,
        'escape',
      );
      expect(
        (HotkeySpec.parse('cmd+enter') as Success<HotkeySpec>).value.key,
        'return',
      );
      expect(
        (HotkeySpec.parse('cmd+backspace') as Success<HotkeySpec>).value.key,
        'delete',
      );
    });

    test('空串与纯修饰键拒绝', () {
      for (final combo in ['', '   ', 'cmd']) {
        final result = HotkeySpec.parse(combo);
        expect(result, isA<Failure<HotkeySpec>>(), reason: "'$combo'");
      }
    });

    test('没有主修饰键拒绝：会吞掉正常打字', () {
      final result = HotkeySpec.parse('shift+p');
      expect(result, isA<Failure<HotkeySpec>>());
      expect(
        (result as Failure<HotkeySpec>).reason,
        contains('cmd / ctrl / alt'),
      );
    });

    test('多个主键 / 未知按键拒绝', () {
      expect(
        HotkeySpec.parse('cmd+a+b'),
        isA<Failure<HotkeySpec>>(),
      );
      expect(
        HotkeySpec.parse('cmd+[,'),
        isA<Failure<HotkeySpec>>(),
      );
      expect(
        HotkeySpec.parse('cmd+f20'),
        isA<Failure<HotkeySpec>>(),
      );
    });
  });
}
