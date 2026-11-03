/// 人格分区：名字/称呼/语气/主动性可编辑，底线只读。
///
/// 与情绪/形象不同，人格 DNA 是学习层不可改的安全边界：
/// 这里只提供用户手动编辑，不接收任何自动提案。
library;

import 'package:flutter/material.dart';

import '../../../core/result.dart';
import '../../../persona/persona_dna.dart';
import 'settings_controls.dart';

class PersonaSection extends StatefulWidget {
  const PersonaSection({
    super.key,
    required this.persona,
    required this.onSave,
  });

  final PersonaDna persona;

  /// 保存到 persona_dna.json；返回 Failure 时原地展示原因。
  final Result<void> Function(PersonaDna) onSave;

  @override
  State<PersonaSection> createState() => _PersonaSectionState();
}

class _PersonaSectionState extends State<PersonaSection> {
  late final TextEditingController _name;
  late final TextEditingController _address;
  late final TextEditingController _tone;
  late PersonaDna _current;
  late double _proactiveness;
  String _hint = '';

  @override
  void initState() {
    super.initState();
    _current = widget.persona;
    _name = TextEditingController(text: widget.persona.name);
    _address = TextEditingController(text: widget.persona.address);
    _tone = TextEditingController(text: widget.persona.toneCore);
    _proactiveness = widget.persona.proactiveness;
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _tone.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    final address = _address.text.trim();
    final tone = _tone.text.trim();
    if (name.isEmpty || address.isEmpty || tone.isEmpty) {
      setState(() => _hint = '名字、称呼、语气都不能为空');
      return;
    }
    final next = _current.copyWith(
      name: name,
      address: address,
      toneCore: tone,
      proactiveness: _proactiveness,
    );
    final result = widget.onSave(next);
    setState(() {
      _hint = switch (result) {
        Success() => '人格已保存，新会话立即生效',
        Failure(:final reason) => reason,
      };
      if (result is Success<void>) _current = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SettingsDivider('身份与表达'),
        const SettingsLabel('名字（自称）'),
        SettingsField(controller: _name, hint: '例如 大肥鱼'),
        const SettingsLabel('对用户的称呼'),
        SettingsField(controller: _address, hint: '例如 主人 / 老板'),
        const SettingsLabel('语气核心'),
        SettingsField(controller: _tone, hint: '例如 温暖、简洁、诚实'),
        const SettingsLabel('主动程度（0 = 完全被动，1 = 最主动）'),
        Row(
          children: [
            Expanded(
              child: Slider(
                value: _proactiveness,
                min: 0,
                max: 1,
                divisions: 20,
                label: _proactiveness.toStringAsFixed(2),
                onChanged: (value) => setState(() => _proactiveness = value),
              ),
            ),
            SizedBox(
              width: 42,
              child: Text(
                _proactiveness.toStringAsFixed(2),
                textAlign: TextAlign.right,
                style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 11),
              ),
            ),
          ],
        ),
        const SettingsDivider('不可由学习改变的底线'),
        for (final line in widget.persona.bottomLines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                const Icon(
                  Icons.lock_outline,
                  size: 13,
                  color: Color(0x66FFFFFF),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    line,
                    style: const TextStyle(
                      color: Color(0x99FFFFFF),
                      fontSize: 11.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 6),
        const Text(
          '身份、价值观、隐私权限、打扰上限与底线由你手动维护；'
          '反馈学习与形象演化都不能自动改写这些字段。',
          style: TextStyle(
            color: Color(0x66FFFFFF),
            fontSize: 10.5,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                _hint,
                style: const TextStyle(color: Color(0xB3FFFFFF), fontSize: 11),
              ),
            ),
            FilledButton(onPressed: _save, child: const Text('保存人格')),
          ],
        ),
      ],
    );
  }
}
