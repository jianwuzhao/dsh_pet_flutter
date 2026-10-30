/// JSONC 解析：去掉 `//`、`/* */` 注释与尾逗号后再交给 jsonDecode。
///
/// 为什么不用正则一把梭：注释可能出现在字符串字面量里（如 URL `https://…`），
/// 必须先做字符串状态机，否则会把配置里的路径/链接吃掉。
library;

import 'dart:convert';

String stripJsonc(String source) {
  final out = StringBuffer();
  var inString = false;
  var inLineComment = false;
  var inBlockComment = false;
  var escaped = false;

  for (var i = 0; i < source.length; i++) {
    final ch = source[i];
    final next = i + 1 < source.length ? source[i + 1] : '';

    if (inLineComment) {
      if (ch == '\n') {
        inLineComment = false;
        out.write(ch);
      }
      continue;
    }
    if (inBlockComment) {
      if (ch == '*' && next == '/') {
        inBlockComment = false;
        i++;
      }
      continue;
    }
    if (inString) {
      out.write(ch);
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }

    if (ch == '"') {
      inString = true;
      out.write(ch);
      continue;
    }
    if (ch == '/' && next == '/') {
      inLineComment = true;
      i++;
      continue;
    }
    if (ch == '/' && next == '*') {
      inBlockComment = true;
      i++;
      continue;
    }
    out.write(ch);
  }

  return _removeTrailingCommas(out.toString());
}

String _removeTrailingCommas(String text) {
  final buffer = StringBuffer();
  var inString = false;
  var escaped = false;

  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (inString) {
      buffer.write(ch);
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    if (ch == '"') {
      inString = true;
      buffer.write(ch);
      continue;
    }
    if (ch == ',') {
      // 向前看第一个非空白字符，若是 } 或 ] 则丢弃这个逗号
      var j = i + 1;
      while (j < text.length &&
          (text[j] == ' ' ||
              text[j] == '\n' ||
              text[j] == '\r' ||
              text[j] == '\t')) {
        j++;
      }
      if (j < text.length && (text[j] == '}' || text[j] == ']')) {
        continue;
      }
    }
    buffer.write(ch);
  }
  return buffer.toString();
}

dynamic decodeJsonc(String source) => jsonDecode(stripJsonc(source));
