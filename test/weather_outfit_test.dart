import 'dart:convert';

import 'package:dsh_pet_flutter/persona/appearance/weather_outfit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  http.Response ok({int code = 293}) => http.Response(
    jsonEncode({
      'current_condition': [
        {'weatherCode': '$code', 'temp_C': '12'},
      ],
    }),
    200,
  );

  test('wttr.in 天气代码映射：晴/雨/雪/不换装', () {
    expect(WeatherOutfitService.mapWeatherCode(113), 'sunny');
    expect(WeatherOutfitService.mapWeatherCode(293), 'rain');
    expect(WeatherOutfitService.mapWeatherCode(389), 'rain'); // 雷雨
    expect(WeatherOutfitService.mapWeatherCode(353), 'rain'); // 毛毛雨
    expect(WeatherOutfitService.mapWeatherCode(227), 'snow');
    expect(WeatherOutfitService.mapWeatherCode(338), 'snow');
    expect(WeatherOutfitService.mapWeatherCode(116), isNull); // 多云
    expect(WeatherOutfitService.mapWeatherCode(143), isNull); // 雾
    expect(WeatherOutfitService.mapWeatherCode(null), isNull);
    expect(WeatherOutfitService.mapWeatherCode(999), isNull); // 未知代码安全侧
  });

  test('12h 缓存内不再发请求；缓存过期才重新拉取', () async {
    var now = DateTime(2026, 11, 4, 8);
    var requests = 0;
    final service = WeatherOutfitService(
      client: MockClient((_) async {
        requests++;
        return ok(code: 293);
      }),
      clock: () => now,
    );

    final first = await service.current();
    expect(first?.outfit, 'rain');
    expect(requests, 1);

    // 缓存内：直接复用，不发请求。
    now = now.add(const Duration(hours: 11));
    expect((await service.current())?.outfit, 'rain');
    expect(requests, 1);

    // 过期：重新拉取。
    now = now.add(const Duration(hours: 2));
    expect((await service.current())?.outfit, 'rain');
    expect(requests, 2);
  });

  test('每日最多拉取 2 次，超限用旧缓存，跨天重置', () async {
    // 从 11/4 凌晨起步：两次 12h TTL 都落在 11/4，第三次过期仍在 11/4，
    // 被日限挡住；11/5 跨天重置后恢复拉取。
    var now = DateTime(2026, 11, 4, 0, 30);
    var requests = 0;
    final service = WeatherOutfitService(
      client: MockClient((_) async {
        requests++;
        return ok(code: 227);
      }),
      clock: () => now,
    );

    expect((await service.current())?.outfit, 'snow');
    now = DateTime(2026, 11, 4, 13);
    expect((await service.current())?.outfit, 'snow');
    expect(requests, 2);

    // 同日第三次 TTL 过期：日限兜底，不发请求。
    now = DateTime(2026, 11, 4, 23);
    expect((await service.current())?.outfit, 'snow');
    expect(requests, 2);

    // 跨天自动重置日限。
    now = DateTime(2026, 11, 5, 8);
    expect((await service.current())?.outfit, 'snow');
    expect(requests, 3);
  });

  test('拉取失败静默：保留旧缓存，不抛异常', () async {
    var now = DateTime(2026, 11, 4, 8);
    var broken = false;
    final service = WeatherOutfitService(
      client: MockClient((_) async {
        if (broken) throw Exception('network down');
        return ok(code: 293);
      }),
      clock: () => now,
    );

    expect((await service.current())?.outfit, 'rain');
    broken = true;
    now = now.add(const Duration(hours: 13));
    final afterFailure = await service.current();
    expect(afterFailure?.outfit, 'rain'); // 旧缓存兜底
    expect(() => service.current(), returnsNormally);
  });

  test('非 200 与坏响应体：返回缓存（首次则 null）', () async {
    final service = WeatherOutfitService(
      client: MockClient((_) async => http.Response('oops', 500),
      ),
      clock: () => DateTime(2026, 11, 4, 8),
    );
    expect(await service.current(), isNull);

    final malformed = WeatherOutfitService(
      client: MockClient((_) async => http.Response('[]', 200)),
      clock: () => DateTime(2026, 11, 4, 8),
    );
    // 坏响应体解析不出代码：观察结果缓存为「今天不值得换装」。
    final observed = await malformed.current();
    expect(observed, isNotNull);
    expect(observed?.outfit, isNull);
  });
}
