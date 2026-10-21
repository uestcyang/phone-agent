import 'dart:io';

import 'package:flutter/material.dart';

import 'avatar_store.dart';

const List<Color> kAgentColorPalette = [
  Colors.teal,
  Colors.indigo,
  Colors.deepOrange,
  Colors.purple,
  Colors.blueGrey,
  Colors.brown,
  Colors.pink,
  Colors.cyan,
];

Color colorForAgent(String id) {
  var hash = 0;
  for (final c in id.codeUnits) {
    hash = (hash * 31 + c) & 0x7fffffff;
  }
  return kAgentColorPalette[hash % kAgentColorPalette.length];
}

class AgentAvatar extends StatelessWidget {
  final String agentId;
  final String displayName;
  final double radius;

  const AgentAvatar({
    super.key,
    required this.agentId,
    required this.displayName,
    this.radius = 20,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: AgentAvatarStore.notifierFor(agentId),
      builder: (context, path, _) {
        if (path != null && File(path).existsSync()) {
          return CircleAvatar(
            key: ValueKey('av-$path-${AgentAvatarStore.revFor(agentId)}'),
            radius: radius,
            backgroundColor: Colors.transparent,
            backgroundImage: FileImage(File(path)),
          );
        }
        final letter = displayName.isNotEmpty
            ? displayName.substring(0, 1).toUpperCase()
            : '?';
        return CircleAvatar(
          radius: radius,
          backgroundColor: colorForAgent(agentId),
          child: Text(
            letter,
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: radius * 0.9,
            ),
          ),
        );
      },
    );
  }
}
