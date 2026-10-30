import 'package:dsh_pet_flutter/core/config/jsonc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('decodeJsonc', () {
    test('去掉行注释与块注释', () {
      const source = '''
      {
        // 行注释
        "a": 1, /* 块注释 */
        "b": 2
      }
      ''';
      expect(decodeJsonc(source), {'a': 1, 'b': 2});
    });

    test('容忍尾逗号', () {
      const source = '{"a": 1, "b": [1, 2,],}';
      expect(decodeJsonc(source), {
        'a': 1,
        'b': [1, 2],
      });
    });

    test('字符串里的 // 与 /* 不会被当成注释', () {
      const source =
          '{"url": "http://example.com/a", "note": "/* not comment */"}';
      expect(decodeJsonc(source), {
        'url': 'http://example.com/a',
        'note': '/* not comment */',
      });
    });

    test('非法 JSON 抛错而不是静默兜底', () {
      expect(() => decodeJsonc('{"a": }'), throwsA(anything));
    });
  });
}
