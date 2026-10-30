import 'dart:io';

import 'package:dsh_pet_flutter/core/paths/app_paths.dart';
import 'package:dsh_pet_flutter/features/ai/chat_memory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('dsh_pet_memory_test_');
    AppPaths.overrideRoot(temp);
  });
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('对话记忆落盘并在新实例中恢复，上下文按轮数截断', () {
    final memory = ChatMemory();
    memory.appendRound('第一问', '第一答');
    memory.appendRound('第二问', '第二答');
    memory.appendRound('第三问', '第三答');

    final restored = ChatMemory();
    expect(restored.messages.length, 6);
    expect(restored.messages.first.content, '第一问');
    expect(restored.messages.last.content, '第三答');

    final context = restored.context(2);
    expect(context.length, 4);
    expect(context.first.content, '第二问');
    expect(context.last.content, '第三答');
  });

  test('清空会同步写回磁盘', () {
    final memory = ChatMemory()..appendRound('问', '答');
    memory.clear();
    expect(ChatMemory().messages, isEmpty);
  });
}
