import 'dart:io';

import 'package:dsh_pet_flutter/core/result.dart';
import 'package:dsh_pet_flutter/interop/adapters/chatgpt_adapter.dart';
import 'package:dsh_pet_flutter/interop/adapters/trae_cn_adapter.dart';
import 'package:dsh_pet_flutter/interop/capability.dart';
import 'package:dsh_pet_flutter/interop/capability_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('interop_test');
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  group('TraeCnCapability', () {
    test('桥目录为空 → 未配置（即使客户端已安装）', () async {
      final emptyBridge = Directory('${tmpDir.path}/bridge')..createSync();
      final app = Directory('${tmpDir.path}/Applications/Trae CN.app')
        ..createSync(recursive: true);
      final adapter = TraeCnCapability(
        bridgeDir: emptyBridge,
        appPaths: [app.path],
      );

      final availability = await adapter.probe();
      expect(availability.status, AvailabilityStatus.notConfigured);
      expect(availability.reason, contains('桌面桥未启用'));
    });

    test('桥目录有文件 → 可用', () async {
      final bridge = Directory('${tmpDir.path}/bridge')..createSync();
      File('${bridge.path}/state.json').writeAsStringSync('{}');
      final adapter = TraeCnCapability(
        bridgeDir: bridge,
        appPaths: ['${tmpDir.path}/nonexistent.app'],
      );

      final availability = await adapter.probe();
      expect(availability.ready, isTrue);
      expect(availability.detail, contains(bridge.path));
    });

    test('客户端与桥都没有 → 未配置且说明原因', () async {
      final adapter = TraeCnCapability(
        bridgeDir: Directory('${tmpDir.path}/nope'),
        appPaths: ['${tmpDir.path}/nope.app'],
      );
      final availability = await adapter.probe();
      expect(availability.status, AvailabilityStatus.notConfigured);
      expect(availability.reason, contains('未发现'));
    });
  });

  group('ChatGptCapability', () {
    test('无 API Key → 未配置', () async {
      final adapter = ChatGptCapability(
        keyLoader: () async => '',
        baseUrl: 'https://api.openai.com/v1',
        model: 'gpt-4o-mini',
        appPaths: ['${tmpDir.path}/ChatGPT.app'],
      );
      final availability = await adapter.probe();
      expect(availability.status, AvailabilityStatus.notConfigured);
      expect(availability.reason, contains('API Key'));
    });

    test('Key 齐全但 baseUrl 为空 → 未配置', () async {
      final adapter = ChatGptCapability(
        keyLoader: () async => 'sk-test',
        model: 'gpt-4o-mini',
        appPaths: const [],
      );
      final availability = await adapter.probe();
      expect(availability.status, AvailabilityStatus.notConfigured);
      expect(availability.reason, contains('Base URL'));
    });

    test('参数齐全 → 可用，且 detail 带端点与模型', () async {
      final adapter = ChatGptCapability(
        keyLoader: () async => 'sk-test',
        baseUrl: 'https://api.openai.com/v1',
        model: 'gpt-4o-mini',
        appPaths: const [],
      );
      final availability = await adapter.probe();
      expect(availability.ready, isTrue);
      expect(availability.detail, contains('gpt-4o-mini'));
    });

    test('读取 Key 抛异常 → 不可达，不外抛', () async {
      final adapter = ChatGptCapability(
        keyLoader: () async => throw StateError('keychain 不可用'),
        baseUrl: 'https://api.openai.com/v1',
        model: 'gpt-4o-mini',
        appPaths: const [],
      );
      final availability = await adapter.probe();
      expect(availability.status, AvailabilityStatus.unreachable);
    });
  });

  group('能力契约与注册表', () {
    test('M1 只探测：invoke 返回结构化“未开放”', () async {
      final adapter = TraeCnCapability(
        bridgeDir: Directory('${tmpDir.path}/bridge'),
        appPaths: const [],
      );
      final result = await adapter.invoke(
        const CapabilityRequest(goal: '改一个文件', kind: CapabilityKind.codeEdit),
      );
      expect(result, isA<Failure<CapabilityHandle>>());
      expect(
        (result as Failure<CapabilityHandle>).code,
        ProbeOnlyAdapter.notOpenCode,
      );
    });

    test('注册表并行探测并缓存；force 才重新探测', () async {
      var probes = 0;
      var now = DateTime(2026, 1, 1, 12);
      final registry = CapabilityRegistry(
        adapters: [
          TraeCnCapability(
            bridgeDir: Directory('${tmpDir.path}/bridge'),
            appPaths: const [],
          ),
          ChatGptCapability(
            keyLoader: () async {
              probes++;
              return 'sk-test';
            },
            baseUrl: 'https://api.openai.com/v1',
            model: 'gpt-4o-mini',
            appPaths: const [],
          ),
        ],
        cacheTtl: const Duration(seconds: 30),
        clock: () => now,
      );

      final first = await registry.probeAll();
      expect(first['chatgpt']!.ready, isTrue);
      expect(first['trae-cn']!.status, AvailabilityStatus.notConfigured);
      expect(probes, 1);

      await registry.probeAll();
      expect(probes, 1);

      now = now.add(const Duration(seconds: 31));
      await registry.probeAll();
      expect(probes, 2);

      await registry.probeAll(force: true);
      expect(probes, 3);
    });

    test('单个适配器抛异常不影响其它结果', () async {
      final registry = CapabilityRegistry(
        adapters: [
          _BrokenAdapter(),
          TraeCnCapability(
            bridgeDir: Directory('${tmpDir.path}/bridge'),
            appPaths: const [],
          ),
        ],
      );
      final results = await registry.probeAll();
      expect(results['broken']!.status, AvailabilityStatus.unreachable);
      expect(results['trae-cn'], isNotNull);
    });

    test('按能力种类筛选适配器', () {
      final registry = CapabilityRegistry(
        adapters: [
          TraeCnCapability(
            bridgeDir: Directory('${tmpDir.path}/bridge'),
            appPaths: const [],
          ),
          ChatGptCapability(
            keyLoader: () async => '',
            appPaths: const [],
          ),
        ],
      );
      expect(registry.supporting(CapabilityKind.codeEdit).length, 1);
      expect(registry.supporting(CapabilityKind.deepResearch).length, 1);
      expect(registry.byId('nope'), isNull);
    });
  });
}

class _BrokenAdapter extends ProbeOnlyAdapter {
  @override
  CapabilityDescriptor get descriptor => const CapabilityDescriptor(
    id: 'broken',
    displayName: 'Broken',
    kinds: {CapabilityKind.chat},
    mode: AccessMode.officialApi,
  );

  @override
  Future<Availability> probe({Duration? timeout}) async =>
      throw StateError('boom');
}
