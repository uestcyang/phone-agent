import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'agent_registry.dart';
import 'models.dart';

class SharedFile {
  final String name;
  final String path;
  final String mime;
  final int size;
  const SharedFile({
    required this.name,
    required this.path,
    required this.mime,
    required this.size,
  });

  factory SharedFile.fromJson(Map<dynamic, dynamic> json) => SharedFile(
    name: json['name'] as String,
    path: json['path'] as String,
    mime: json['mime'] as String,
    size: (json['size'] as num).toInt(),
  );
  Map<String, Object> toJson() => {
    'name': name,
    'path': path,
    'mime': mime,
    'size': size,
  };
}

class IncomingShare {
  final String id;
  final String text;
  final List<SharedFile> files;
  final List<String> errors;
  final String? targetAgentId;
  const IncomingShare({
    required this.id,
    required this.text,
    this.files = const [],
    this.errors = const [],
    this.targetAgentId,
  });
  factory IncomingShare.fromJson(Map<dynamic, dynamic> json) => IncomingShare(
    id: json['id'] as String,
    text: json['text'] as String? ?? '',
    files: (json['files'] as List? ?? [])
        .map((e) => SharedFile.fromJson(e as Map))
        .toList(),
    errors: (json['errors'] as List? ?? []).cast<String>(),
    targetAgentId: json['targetAgentId'] as String?,
  );
  bool get hasContent => text.isNotEmpty || files.isNotEmpty;
  AgentSpec? directTarget(List<AgentSpec> agents) {
    if (!hasContent || errors.isNotEmpty || targetAgentId == null) return null;
    for (final agent in agents) {
      if (agent.enabled && agent.id == targetAgentId) return agent;
    }
    return null;
  }
}

class SharedDraft {
  final String text;
  final List<SharedFile> files;
  final Set<String> ids;
  final List<ChatAttachment> attachments;
  final List<Map<String, String>> pathHints;
  final String? quotedText;
  const SharedDraft({
    this.text = '',
    this.files = const [],
    this.ids = const {},
    this.attachments = const [],
    this.pathHints = const [],
    this.quotedText,
  });
  bool get hasContent =>
      text.isNotEmpty ||
      files.isNotEmpty ||
      attachments.isNotEmpty ||
      pathHints.isNotEmpty ||
      (quotedText?.isNotEmpty ?? false);
  SharedDraft merge(IncomingShare share) {
    if (ids.contains(share.id)) {
      return SharedDraft(
        text: text,
        files: List.of(files),
        ids: Set.of(ids),
        attachments: List.of(attachments),
        pathHints: pathHints.map((h) => Map<String, String>.of(h)).toList(),
        quotedText: quotedText,
      );
    }
    return SharedDraft(
      text: [text, share.text].where((s) => s.isNotEmpty).join('\n\n'),
      files: [...files, ...share.files],
      ids: {...ids, share.id},
      attachments: List.of(attachments),
      pathHints: pathHints.map((h) => Map<String, String>.of(h)).toList(),
      quotedText: quotedText,
    );
  }

  Map<String, Object> toJson() => {
    'text': text,
    'files': files.map((f) => f.toJson()).toList(),
    'ids': ids.toList(),
    'attachments': attachments.map((a) => a.toJson()).toList(),
    'pathHints': pathHints,
    'quotedText': ?quotedText,
  };
  factory SharedDraft.fromJson(Map<String, dynamic> json) => SharedDraft(
    text: json['text'] as String? ?? '',
    files: (json['files'] as List? ?? [])
        .map((e) => SharedFile.fromJson(e as Map))
        .toList(),
    ids: (json['ids'] as List? ?? []).cast<String>().toSet(),
    attachments: (json['attachments'] as List? ?? [])
        .map(
          (a) => ChatAttachment.fromJson(Map<String, dynamic>.from(a as Map)),
        )
        .toList(),
    pathHints: (json['pathHints'] as List? ?? [])
        .map((h) => Map<String, String>.from(h as Map))
        .toList(),
    quotedText: json['quotedText'] as String?,
  );
}

class SharedDraftStore {
  static const _prefix = 'incoming_share_draft_v1_';
  static final Map<String, Future<void>> _writes = {};
  static Future<SharedDraft?> load(String agentId) async {
    await _writes[agentId];
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_prefix$agentId');
    return raw == null
        ? null
        : SharedDraft.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  static Future<void> save(String agentId, SharedDraft draft) {
    final previous = _writes[agentId] ?? Future<void>.value();
    final next = previous.catchError((Object _) {}).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      final ok = draft.ids.isEmpty && !draft.hasContent
          ? await prefs.remove('$_prefix$agentId')
          : await prefs.setString(
              '$_prefix$agentId',
              jsonEncode(draft.toJson()),
            );
      if (!ok) throw StateError('分享草稿保存失败');
    });
    _writes[agentId] = next;
    return next;
  }
}

class IncomingShareInbox {
  static const channel = MethodChannel('org.phoneagent.app/incoming_share');

  static Future<void> Function(AgentSpec, IncomingShare)? openDraft;
  static Future<void> publishTargets(List<AgentSpec> agents) =>
      channel.invokeMethod('publishTargets', {
        'agents': agents
            .where((a) => a.enabled)
            .map((a) => {'id': a.id, 'name': a.displayName})
            .toList(),
      });
  static Future<List<IncomingShare>> pending() async {
    final raw = await channel.invokeListMethod<dynamic>('pending') ?? [];
    return raw.map((e) => IncomingShare.fromJson(e as Map)).toList();
  }

  static Future<void> ack(String id) => channel.invokeMethod('ack', {'id': id});
  static Future<void> discard(String id) =>
      channel.invokeMethod('discard', {'id': id});
}
