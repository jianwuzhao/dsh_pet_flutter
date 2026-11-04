/// 天气装扮服务（P2-3）：显式开启后才工作，失败永远静默。
///
/// 免费无 Key API（wttr.in ?format=j1）+ 12h 缓存 + 每日最多 2 次拉取：
/// 天气只是装扮建议的输入之一，网络缺席或超限都不影响任何既有行为。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// 一次天气观察的结果；outfit 为 null 表示「今天不值得换装」（多云等）。
class WeatherOutfit {
  const WeatherOutfit({required this.outfit, required this.fetchedAt});

  /// 映射后的装扮名：rain | snow | sunny | null。
  final String? outfit;
  final DateTime fetchedAt;
}

/// 待用户确认的天气装扮建议（内存态：生命周期只有当天，重启即清，
/// 不值得为它持久化）。
class WeatherOutfitSuggestion {
  const WeatherOutfitSuggestion({
    required this.outfit,
    required this.reason,
    required this.suggestedAt,
  });

  final String outfit;
  final String reason;
  final DateTime suggestedAt;
}

/// 天气装扮名的中文短语（建议理由与 UI 共用）。
String weatherOutfitLabel(String outfit) => switch (outfit) {
  'rain' => '雨具装扮',
  'snow' => '雪装',
  'sunny' => '晴日装',
  _ => '$outfit 装扮',
};

class WeatherOutfitService {
  WeatherOutfitService({
    http.Client? client,
    DateTime Function()? clock,
    Uri? endpoint,
  }) : _client = client ?? http.Client(),
       _clock = clock ?? DateTime.now,
       _endpoint = endpoint ?? Uri.parse('https://wttr.in/?format=j1');

  final http.Client _client;
  final DateTime Function() _clock;
  final Uri _endpoint;

  /// 缓存有效期：一天两次拉取刚好覆盖早晚天气变化。
  static const Duration cacheTtl = Duration(hours: 12);

  /// 日限 2 次：防滥用（决策点 D4），超限直接用旧缓存。
  static const int dailyFetchLimit = 2;

  static const Duration requestTimeout = Duration(seconds: 8);

  WeatherOutfit? _cached;

  /// 日限计数按本地日期翻篇；跨天自动重置。
  String _fetchedDay = '';
  int _fetchedToday = 0;

  /// 当前天气装扮：缓存新鲜直接用，过期且未超日限才发请求。
  Future<WeatherOutfit?> current() async {
    final now = _clock();
    final cached = _cached;
    if (cached != null && now.difference(cached.fetchedAt) < cacheTtl) {
      return cached;
    }
    final dayKey = '${now.year}-${now.month}-${now.day}';
    if (_fetchedDay != dayKey) {
      _fetchedDay = dayKey;
      _fetchedToday = 0;
    }
    if (_fetchedToday >= dailyFetchLimit) return cached;
    _fetchedToday++;
    try {
      final response = await _client.get(_endpoint).timeout(requestTimeout);
      if (response.statusCode != 200) return cached;
      return _cached = WeatherOutfit(
        outfit: mapWeatherCode(_weatherCodeOf(response.body)),
        fetchedAt: now,
      );
    } catch (_) {
      // 静默失败：装扮建议缺席，宠物行为不受影响。
      return cached;
    }
  }

  static int? _weatherCodeOf(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return null;
    final conditions = decoded['current_condition'];
    if (conditions is! List || conditions.isEmpty) return null;
    final first = conditions.first;
    if (first is! Map) return null;
    return int.tryParse('${first['weatherCode']}');
  }

  /// wttr.in 天气代码 → 装扮名。
  ///
  /// 只挑「换装有感」的天气：晴 / 雨（含毛毛雨冻雨雷雨）/ 雪（含雨夹雪）；
  /// 多云与雾不换装（null），避免建议频繁打扰。
  static String? mapWeatherCode(int? code) {
    if (code == null) return null;
    if (code == 113) return 'sunny';
    // 多云 116/119/122、雾 143/248/260：不换装。
    if ({116, 119, 122, 143, 248, 260}.contains(code)) return null;
    // 雪 / 雨夹雪系。
    if (const {
      179, 182, 185, 227, 230, 320, 323, 326, 329, 332, 335, 338, 350, 368,
      374, 377,
    }.contains(code)) {
      return 'snow';
    }
    // 其余降水系（毛毛雨 176/263/266、雨 293-302/305-356、雷雨 389+）→ 雨具。
    if (code >= 176 && code <= 395) return 'rain';
    return null;
  }
}
