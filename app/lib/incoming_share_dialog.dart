import 'package:flutter/material.dart';

import 'agent_registry.dart';
import 'incoming_share.dart';

class IncomingShareDialog extends StatefulWidget {
  final IncomingShare share;
  final String? initialAgentId;
  final List<AgentSpec> agents;
  const IncomingShareDialog({
    super.key,
    required this.share,
    required this.agents,
    this.initialAgentId,
  });
  @override
  State<IncomingShareDialog> createState() => _IncomingShareDialogState();
}

class _IncomingShareDialogState extends State<IncomingShareDialog> {
  late AgentSpec selected;
  @override
  void initState() {
    super.initState();
    selected = widget.agents.firstWhere(
      (a) => a.id == widget.initialAgentId,
      orElse: () => widget.agents.first,
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('分享到手机 Agent'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<AgentSpec>(
              initialValue: selected,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '交给哪个 Agent'),
              items: widget.agents
                  .map(
                    (a) =>
                        DropdownMenuItem(value: a, child: Text(a.displayName)),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) setState(() => selected = value);
              },
            ),
            const SizedBox(height: 16),
            if (widget.share.text.isNotEmpty)
              Text(
                widget.share.text,
                maxLines: 8,
                overflow: TextOverflow.ellipsis,
              ),
            for (final file in widget.share.files)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '📎 ${file.name} · ${(file.size / 1024).toStringAsFixed(0)} KB',
                ),
              ),
            for (final error in widget.share.errors)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 16),
            const Text('先加入草稿，可补充要求；点击发送后才交给 Agent。'),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('取消分享'),
      ),
      FilledButton(
        onPressed: widget.share.hasContent
            ? () => Navigator.pop(context, selected)
            : null,
        child: const Text('加入草稿'),
      ),
    ],
  );
}
