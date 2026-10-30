/// 宠物输入面板：外置联动时把话投递到关联软件；内置对话时显示来回消息。
///
/// 首版的主通道是用户选择的 AI 软件（Trae CN / ChatGPT / WorkBuddy）；
/// 选择“内置对话”时走 OpenAI 兼容 / Ollama，回复显示在同一张卡片里，
/// 并在宠物头顶同步一条气泡（与 dsh-pet 的聊天体验对齐）。
library;

import 'package:flutter/material.dart';

import '../../core/result.dart';
import '../linkage/assistant_adapters.dart';

class ChatPanel extends StatefulWidget {
  const ChatPanel({
    super.key,
    required this.activeName,
    required this.onSend,
    required this.onClose,
  });

  final String activeName;
  final Future<Result<DispatchOutcome>> Function(String prompt) onSend;
  final VoidCallback onClose;

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<({bool user, String text})> _messages = [];
  bool _busy = false;
  String _hint = '';

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final prompt = _input.text.trim();
    if (prompt.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _hint = '';
      _messages.add((user: true, text: prompt));
    });
    _scrollToEnd();

    final result = await widget.onSend(prompt);
    if (!mounted) return;
    setState(() {
      _busy = false;
      switch (result) {
        case Success(value: final outcome):
          if (outcome.ok) {
            _input.clear();
            if (outcome.reply.trim().isNotEmpty) {
              _messages.add((user: false, text: outcome.reply.trim()));
            } else {
              _hint = '已发送到 ${widget.activeName}';
            }
          } else {
            _hint = outcome.reason;
          }
        case Failure(reason: final reason):
          _hint = reason;
      }
    });
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 420,
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
      decoration: BoxDecoration(
        color: const Color(0xF51B1B20),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x26FFFFFF)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x59000000),
            blurRadius: 28,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '对 ${widget.activeName} 说',
                  style: const TextStyle(
                    color: Color(0xF2FFFFFF),
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                onPressed: widget.onClose,
                icon: const Icon(
                  Icons.close,
                  size: 18,
                  color: Color(0xB3FFFFFF),
                ),
                tooltip: '关闭',
              ),
            ],
          ),
          if (_messages.isNotEmpty) ...[
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 190),
              child: SingleChildScrollView(
                controller: _scroll,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final message in _messages)
                      _MessageBubble(user: message.user, text: message.text),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
          ] else
            const SizedBox(height: 8),
          TextField(
            controller: _input,
            autofocus: true,
            maxLines: 3,
            minLines: 1,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              hintText: '让它帮你做点什么…（Enter 发送，Shift+Enter 换行）',
              hintStyle: const TextStyle(
                color: Color(0x66FFFFFF),
                fontSize: 13,
              ),
              filled: true,
              fillColor: const Color(0x1AFFFFFF),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
            onSubmitted: (_) => _send(),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  _hint,
                  style: const TextStyle(
                    color: Color(0xB3FFFFFF),
                    fontSize: 11,
                  ),
                ),
              ),
              FilledButton(
                onPressed: _busy ? null : _send,
                child: Text(_busy ? '思考中…' : '发送'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.user, required this.text});

  final bool user;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 330),
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
        decoration: BoxDecoration(
          color: user ? const Color(0x334B7CFF) : const Color(0x1AFFFFFF),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(11),
            topRight: const Radius.circular(11),
            bottomLeft: Radius.circular(user ? 11 : 3),
            bottomRight: Radius.circular(user ? 3 : 11),
          ),
        ),
        child: Text(
          text,
          style: const TextStyle(
            color: Color(0xE6FFFFFF),
            fontSize: 12.5,
            height: 1.4,
          ),
        ),
      ),
    );
  }
}
