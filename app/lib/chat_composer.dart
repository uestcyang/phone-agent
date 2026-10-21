import 'package:flutter/material.dart';

class ChatComposer extends StatelessWidget {
  const ChatComposer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.maxHeight,
    required this.onMic,
    required this.onSend,
    required this.recording,
    required this.voiceBusy,
    required this.thinking,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final double maxHeight;
  final VoidCallback onMic;
  final VoidCallback onSend;
  final bool recording, voiceBusy, thinking;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      Expanded(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: 76,
            maxHeight: maxHeight < 76 ? 76 : maxHeight,
          ),
          child: TextField(
            key: const ValueKey('draft-input'),
            controller: controller,
            focusNode: focusNode,
            minLines: 2,
            maxLines: null,
            decoration: InputDecoration(
              hintText: thinking ? '插话（排队）…' : '输入消息…',
              border: const OutlineInputBorder(),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
            onSubmitted: (_) => onSend(),
          ),
        ),
      ),
      const SizedBox(width: 6),
      SizedBox(
        width: 38,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              key: const ValueKey('composer-mic'),
              tooltip: recording
                  ? '停止录音并转文字'
                  : voiceBusy
                  ? '正在转文字'
                  : '录音转文字',
              constraints: const BoxConstraints.tightFor(width: 38, height: 36),
              padding: EdgeInsets.zero,
              onPressed: voiceBusy ? null : onMic,
              color: recording ? Colors.redAccent : null,
              icon: Icon(recording ? Icons.mic : Icons.mic_none, size: 23),
            ),
            const SizedBox(height: 2),
            IconButton.filled(
              key: const ValueKey('composer-send'),
              tooltip: thinking ? '插话：排队' : '发送',
              constraints: const BoxConstraints.tightFor(width: 38, height: 36),
              padding: EdgeInsets.zero,
              onPressed: onSend,
              icon: const Icon(Icons.send, size: 21),
            ),
          ],
        ),
      ),
    ],
  );
}
