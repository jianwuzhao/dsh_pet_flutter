/// 形态提案：最显眼的外观变化不自动应用，等用户接受后才落盘。
///
/// 提案只描述目标形态与理由，不携带整份形象状态——用户拒绝时无需回滚，
/// 接受时以「当前形象 + 目标形态」生成新版本，避免基于陈旧快照覆盖其它维度。
library;

import 'appearance_state.dart';

class AppearanceProposal {
  const AppearanceProposal({
    required this.id,
    required this.targetForm,
    required this.reason,
    required this.createdAtMs,
  });

  final String id;
  final AppearanceForm targetForm;

  /// 为什么建议变：推演依据，设置页原样展示。
  final String reason;
  final int createdAtMs;

  DateTime get createdAt => DateTime.fromMillisecondsSinceEpoch(createdAtMs);

  Map<String, dynamic> toJson() => {
    'id': id,
    'targetForm': targetForm.name,
    'reason': reason,
    'createdAt': createdAt.toIso8601String(),
  };

  factory AppearanceProposal.fromJson(Map<String, dynamic> json) {
    final target = json['targetForm'];
    var form = AppearanceForm.round;
    if (target is String) {
      for (final value in AppearanceForm.values) {
        if (value.name == target) {
          form = value;
          break;
        }
      }
    }
    return AppearanceProposal(
      id: json['id'] as String? ?? '',
      targetForm: form,
      reason: json['reason'] as String? ?? '',
      createdAtMs:
          DateTime.tryParse(json['createdAt'] as String? ?? '')
              ?.millisecondsSinceEpoch ??
          0,
    );
  }
}
