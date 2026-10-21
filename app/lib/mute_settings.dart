import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kGlobalMuted = 'mute_global_enabled';
const _kQuietEnabled = 'mute_quiet_hours_enabled';
const _kQuietStart = 'mute_quiet_start';
const _kQuietEnd = 'mute_quiet_end';
const _kUrgentPassthrough = 'mute_urgent_passthrough';
const _kMutedAgentsPrefix = 'mute_agent_';

const String kDefaultQuietStart = '23:00';
const String kDefaultQuietEnd = '08:00';

int parseHm(String hm) {
  final parts = hm.split(':');
  if (parts.length != 2) return 0;
  final h = int.tryParse(parts[0]) ?? 0;
  final m = int.tryParse(parts[1]) ?? 0;
  return (h.clamp(0, 23)) * 60 + (m.clamp(0, 59));
}

bool isWithinQuietHours(String start, String end, DateTime now) {
  final s = parseHm(start);
  final e = parseHm(end);
  if (s == e) return false;
  final nowMin = now.hour * 60 + now.minute;
  if (s < e) {
    return nowMin >= s && nowMin < e;
  }
  return nowMin >= s || nowMin < e;
}

bool computeSilent({
  required bool globalMuted,
  required bool quietHoursEnabled,
  required String quietStart,
  required String quietEnd,
  required bool roleMuted,
  required String? level,
  required bool urgentPassthrough,
  required DateTime now,
  required bool systemDndOn,
}) {
  if (systemDndOn) return true;
  final inQuiet =
      quietHoursEnabled && isWithinQuietHours(quietStart, quietEnd, now);
  final userMuted = globalMuted || roleMuted || inQuiet;
  if (!userMuted) return false;
  if (level == 'err' && urgentPassthrough) return false;
  return true;
}

class SystemDnd {
  static const MethodChannel _channel = MethodChannel(
    'org.phoneagent.app/push',
  );

  static Future<bool> isOn() async {
    try {
      final filter = await _channel.invokeMethod<int>(
        'getSystemInterruptionFilter',
      );
      return filter != null && filter != 1;
    } catch (_) {
      return false;
    }
  }
}

class MuteSettings extends ChangeNotifier {
  MuteSettings._();
  static final MuteSettings instance = MuteSettings._();

  bool globalMuted = false;
  bool quietHoursEnabled = false;
  String quietStart = kDefaultQuietStart;
  String quietEnd = kDefaultQuietEnd;
  bool urgentPassthrough = true;
  final Set<String> mutedAgents = {};
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    globalMuted = prefs.getBool(_kGlobalMuted) ?? false;
    quietHoursEnabled = prefs.getBool(_kQuietEnabled) ?? false;
    quietStart = prefs.getString(_kQuietStart) ?? kDefaultQuietStart;
    quietEnd = prefs.getString(_kQuietEnd) ?? kDefaultQuietEnd;
    urgentPassthrough = prefs.getBool(_kUrgentPassthrough) ?? true;
    mutedAgents
      ..clear()
      ..addAll(
        prefs
            .getKeys()
            .where(
              (k) =>
                  k.startsWith(_kMutedAgentsPrefix) &&
                  (prefs.getBool(k) ?? false),
            )
            .map((k) => k.substring(_kMutedAgentsPrefix.length)),
      );
    _loaded = true;
    notifyListeners();
  }

  Future<void> setGlobalMuted(bool v) async {
    globalMuted = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kGlobalMuted, v);
    notifyListeners();
  }

  Future<void> setQuietHoursEnabled(bool v) async {
    quietHoursEnabled = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kQuietEnabled, v);
    notifyListeners();
  }

  Future<void> setQuietRange(String start, String end) async {
    quietStart = start;
    quietEnd = end;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kQuietStart, start);
    await prefs.setString(_kQuietEnd, end);
    notifyListeners();
  }

  Future<void> setUrgentPassthrough(bool v) async {
    urgentPassthrough = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kUrgentPassthrough, v);
    notifyListeners();
  }

  Future<void> setAgentMuted(String agentId, bool v) async {
    final prefs = await SharedPreferences.getInstance();
    if (v) {
      mutedAgents.add(agentId);
    } else {
      mutedAgents.remove(agentId);
    }
    await prefs.setBool('$_kMutedAgentsPrefix$agentId', v);
    notifyListeners();
  }

  bool isAgentMuted(String agentId) => mutedAgents.contains(agentId);

  Future<bool> resolveSilent({
    required String agentId,
    required String? level,
  }) async {
    final systemDndOn = await SystemDnd.isOn();
    final roleMuted = isAgentMuted(agentId);
    final silent = computeSilent(
      globalMuted: globalMuted,
      quietHoursEnabled: quietHoursEnabled,
      quietStart: quietStart,
      quietEnd: quietEnd,
      roleMuted: roleMuted,
      level: level,
      urgentPassthrough: urgentPassthrough,
      now: DateTime.now(),
      systemDndOn: systemDndOn,
    );

    developer.log(
      'resolveSilent agent=$agentId level=$level -> silent=$silent '
      '(global=$globalMuted role=$roleMuted quietEnabled=$quietHoursEnabled '
      'quiet=$quietStart-$quietEnd inQuiet=${quietHoursEnabled && isWithinQuietHours(quietStart, quietEnd, DateTime.now())} '
      'systemDnd=$systemDndOn urgentPassthrough=$urgentPassthrough)',
      name: 'PhoneAgentMute',
    );
    return silent;
  }

  bool get anyUserMuteActive =>
      globalMuted ||
      (quietHoursEnabled &&
          isWithinQuietHours(quietStart, quietEnd, DateTime.now()));
}
