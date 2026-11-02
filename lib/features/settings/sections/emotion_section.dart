/// 情绪分区：情绪引擎总开关 + 主动打扰预算 + 话术与雷区编辑。
///
/// 开关只改草稿值（copyWith 回传），文本字段由设置页持有 controller；
/// 预算计数字段（careDate/careCount 等）不在这里展示，保存时原样带回。
library;

import 'package:flutter/material.dart';

import '../../../persona/profile_store.dart';
import 'settings_controls.dart';

class EmotionSection extends StatelessWidget {
  const EmotionSection({
    super.key,
    required this.profile,
    required this.onChanged,
    required this.quietStart,
    required this.quietEnd,
    required this.dailyCareLimit,
    required this.comfortPhrases,
    required this.avoidedTopics,
  });

  final EmotionProfile profile;
  final ValueChanged<EmotionProfile> onChanged;

  final TextEditingController quietStart;
  final TextEditingController quietEnd;
  final TextEditingController dailyCareLimit;

  /// 安慰话术池，每行一条。
  final TextEditingController comfortPhrases;

  /// 回避话题，每行一条；话术包含任一话题即被过滤。
  final TextEditingController avoidedTopics;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSwitch(
          value: profile.emotionEnabled,
          onChanged: (value) =>
              onChanged(profile.copyWith(emotionEnabled: value)),
          title: '情绪引擎',
          subtitle: '关闭后纯联动桌宠：不感知、不表达',
        ),
        const SettingsDivider('主动关心'),
        SettingsSwitch(
          value: profile.careEnabled,
          onChanged: (value) => onChanged(profile.copyWith(careEnabled: value)),
          title: '允许主动关心',
          subtitle: '低落持续超 3 分钟才会开口，还要过预算',
        ),
        SettingsSwitch(
          value: profile.focusMode,
          onChanged: (value) => onChanged(profile.copyWith(focusMode: value)),
          title: '专注模式',
          subtitle: '临时静音一切主动打扰',
        ),
        const SettingsLabel('安静时段（HH:mm，可跨零点，如 22:00–08:00）'),
        Row(
          children: [
            Expanded(child: SettingsField(controller: quietStart, hint: '22:00')),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text('至', style: TextStyle(color: Color(0x80FFFFFF))),
            ),
            Expanded(child: SettingsField(controller: quietEnd, hint: '08:00')),
          ],
        ),
        const SettingsLabel('每日关心上限（次）'),
        SettingsField(controller: dailyCareLimit, hint: '3'),
        const SettingsDivider('话术与雷区'),
        const SettingsLabel('安慰话术（每行一条，留空用默认池）'),
        TextField(
          controller: comfortPhrases,
          maxLines: 3,
          style: const TextStyle(color: Colors.white, fontSize: 12.5),
          decoration: const InputDecoration(
            filled: true,
            fillColor: Color(0x1AFFFFFF),
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(8)),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SettingsLabel('回避话题（每行一条，话术命中即被过滤）'),
        TextField(
          controller: avoidedTopics,
          maxLines: 2,
          style: const TextStyle(color: Colors.white, fontSize: 12.5),
          decoration: const InputDecoration(
            filled: true,
            fillColor: Color(0x1AFFFFFF),
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(8)),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ],
    );
  }
}
