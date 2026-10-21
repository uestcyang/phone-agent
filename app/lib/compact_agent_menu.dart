import 'package:flutter/material.dart';

import 'agent_registry.dart';

class CompactAgentMenu extends StatelessWidget {
  const CompactAgentMenu({
    super.key,
    required this.currentId,
    required this.onSelect,
  });
  final String currentId;
  final ValueChanged<AgentSpec> onSelect;

  @override
  Widget build(BuildContext context) {
    final current = resolveAgent(currentId);
    return PopupMenuButton<AgentSpec>(
      key: const ValueKey('agent-menu'),
      tooltip: '切换角色',
      padding: EdgeInsets.zero,
      onSelected: onSelect,
      itemBuilder: (_) => [
        for (final agent in kAgentRegistryFallback.where((a) => a.enabled))
          PopupMenuItem(value: agent, child: Text(agent.displayName)),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              current?.displayName ?? currentId,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const Icon(Icons.expand_more, size: 16),
          ],
        ),
      ),
    );
  }
}
