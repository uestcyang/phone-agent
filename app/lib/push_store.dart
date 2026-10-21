import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';

const _widgetChannel = MethodChannel('org.phoneagent.app/widget');

class PushMetrics {
  final double remainPct;
  final double elapsedMin;
  final double refreshH;
  final int fetchAtEpoch;
  final int refreshAtEpoch;
  final bool lost;

  const PushMetrics({
    required this.remainPct,
    required this.elapsedMin,
    required this.refreshH,
    this.fetchAtEpoch = 0,
    this.refreshAtEpoch = 0,
    this.lost = false,
  });

  factory PushMetrics.fromJson(Map<String, dynamic> j) => PushMetrics(
    remainPct: (j['remain_pct'] as num?)?.toDouble() ?? 0,
    elapsedMin: (j['elapsed_min'] as num?)?.toDouble() ?? 0,
    refreshH: (j['refresh_h'] as num?)?.toDouble() ?? 0,
    fetchAtEpoch: (j['fetch_at_epoch'] as num?)?.toInt() ?? 0,
    refreshAtEpoch: (j['refresh_at_epoch'] as num?)?.toInt() ?? 0,
    lost: j['lost'] == true,
  );

  Map<String, dynamic> toJson() => {
    'remain_pct': remainPct,
    'elapsed_min': elapsedMin,
    'refresh_h': refreshH,
    'fetch_at_epoch': fetchAtEpoch,
    'refresh_at_epoch': refreshAtEpoch,
    'lost': lost,
  };
}

class AgentPush {
  final String title;
  final String body;
  final String ts;
  final String kind;
  final String? level;
  final String? badge;
  final int? tsEpoch;
  final PushMetrics? metrics;

  const AgentPush({
    required this.title,
    required this.body,
    required this.ts,
    this.kind = 'quota',
    this.level,
    this.badge,
    this.tsEpoch,
    this.metrics,
  });

  factory AgentPush.fromJson(Map<String, dynamic> j) {
    final hasMetrics = j['metrics'] != null;
    final kind = (j['kind'] as String?) ?? (hasMetrics ? 'quota' : 'generic');
    final rawTs = j['ts'];
    return AgentPush(
      title: (j['title'] ?? '') as String,
      body: (j['body'] ?? '') as String,
      ts: rawTs is String ? rawTs : '',
      kind: kind,
      level: j['level'] as String?,
      badge: j['badge'] as String?,
      tsEpoch: rawTs is num ? rawTs.toInt() : null,
      metrics: hasMetrics
          ? PushMetrics.fromJson(Map<String, dynamic>.from(j['metrics'] as Map))
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'title': title,
    'body': body,
    'ts': tsEpoch ?? ts,
    'kind': kind,
    if (level != null) 'level': level,
    if (badge != null) 'badge': badge,
    if (metrics != null) 'metrics': metrics!.toJson(),
  };
}

final ValueNotifier<AgentPush?> latestPush = ValueNotifier(null);

Future<void> savePush(AgentPush push) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('latest_push_title', push.title);
  await prefs.setString('latest_push_body', push.body);
  await prefs.setString('latest_push_ts', push.ts);
  await prefs.setString('latest_push_kind', push.kind);
  await prefs.setString('latest_push_level', push.level ?? '');
  await prefs.setString('latest_push_badge', push.badge ?? '');
  await prefs.setInt('latest_push_ts_epoch', push.tsEpoch ?? 0);
  final m = push.metrics;
  if (m != null) {
    await prefs.setDouble('latest_push_remain_pct', m.remainPct);
    await prefs.setDouble('latest_push_elapsed_min', m.elapsedMin);
    await prefs.setDouble('latest_push_refresh_h', m.refreshH);
    await prefs.setInt('latest_push_fetch_at_epoch', m.fetchAtEpoch);
    await prefs.setInt('latest_push_refresh_at_epoch', m.refreshAtEpoch);
    await prefs.setBool('latest_push_lost', m.lost);
  } else {
    await prefs.setDouble('latest_push_remain_pct', -1);
    await prefs.setDouble('latest_push_elapsed_min', -1);
    await prefs.setDouble('latest_push_refresh_h', -1);
    await prefs.setInt('latest_push_fetch_at_epoch', 0);
    await prefs.setInt('latest_push_refresh_at_epoch', 0);
    await prefs.setBool('latest_push_lost', true);
  }
  await prefs.setString('latest_push_json', jsonEncode(push.toJson()));
}

Future<AgentPush?> loadSavedPush() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('latest_push_json');
  if (raw == null) return null;
  try {
    return AgentPush.fromJson(
      Map<String, dynamic>.from(jsonDecode(raw) as Map),
    );
  } catch (_) {
    return null;
  }
}

Future<void> notifyWidgetUpdate(AgentPush push) async {
  try {
    final m = push.metrics;
    await _widgetChannel.invokeMethod('updatePushWidget', {
      'kind': push.kind,
      'title': push.title,
      'body': push.body,
      'level': push.level ?? '',
      'badge': push.badge ?? '',
      'ts_epoch': push.tsEpoch ?? 0,
      'remain_pct': m?.remainPct ?? -1.0,
      'elapsed_min': m?.elapsedMin ?? -1.0,
      'refresh_h': m?.refreshH ?? -1.0,
      'fetch_at_epoch': m?.fetchAtEpoch ?? 0,
      'refresh_at_epoch': m?.refreshAtEpoch ?? 0,
      'lost': m?.lost ?? true,
    });
  } catch (_) {}
}
