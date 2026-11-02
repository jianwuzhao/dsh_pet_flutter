/// 设置页共享控件：统一 label / 输入框 / 下拉 / 开关样式，
/// 三个分区（联动/大脑/隐私）各写一套只会越写越散。
library;

import 'package:flutter/material.dart';

class SettingsLabel extends StatelessWidget {
  const SettingsLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10, bottom: 4),
    child: Text(
      text,
      style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 11),
    ),
  );
}

class SettingsField extends StatelessWidget {
  const SettingsField({
    super.key,
    required this.controller,
    this.hint,
    this.obscure = false,
  });

  final TextEditingController controller;
  final String? hint;
  final bool obscure;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    obscureText: obscure,
    style: const TextStyle(color: Colors.white, fontSize: 13),
    decoration: InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0x59FFFFFF), fontSize: 12),
      filled: true,
      fillColor: const Color(0x1AFFFFFF),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
    ),
  );
}

class SettingsDropdown<T> extends StatelessWidget {
  const SettingsDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  /// 当前值；null 表示还没有任何选项可选中（适配器列表为空时）。
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButton<T>(
    value: value,
    isExpanded: true,
    dropdownColor: const Color(0xFF26262C),
    style: const TextStyle(color: Colors.white, fontSize: 13),
    items: items,
    onChanged: onChanged,
  );
}

class SettingsSwitch extends StatelessWidget {
  const SettingsSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    required this.title,
    this.subtitle,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    value: value,
    onChanged: onChanged,
    title: Text(
      title,
      style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 12),
    ),
    subtitle: subtitle == null
        ? null
        : Text(
            subtitle!,
            style: const TextStyle(color: Color(0x66FFFFFF), fontSize: 10.5),
          ),
  );
}

class SettingsDivider extends StatelessWidget {
  const SettingsDivider(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 2),
    child: Row(
      children: [
        Text(
          title,
          style: const TextStyle(
            color: Color(0xCCFFFFFF),
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 8),
        const Expanded(child: Divider(height: 1, color: Color(0x1FFFFFFF))),
      ],
    ),
  );
}
