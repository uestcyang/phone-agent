import 'package:flutter/material.dart';

import 'agent_registry.dart';
import 'mute_settings.dart';
import 'onboarding_cards.dart';

class MuteSettingsPage extends StatefulWidget {
  const MuteSettingsPage({super.key});

  @override
  State<MuteSettingsPage> createState() => _MuteSettingsPageState();
}

class _MuteSettingsPageState extends State<MuteSettingsPage> {
  final _settings = MuteSettings.instance;
  bool? _systemDndOn;

  @override
  void initState() {
    super.initState();
    _settings.addListener(_onChanged);
    _loadSystemDnd();
  }

  @override
  void dispose() {
    _settings.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadSystemDnd() async {
    final on = await SystemDnd.isOn();
    if (!mounted) return;
    setState(() => _systemDndOn = on);
  }

  Future<void> _pickTime(bool isStart) async {
    final current = isStart ? _settings.quietStart : _settings.quietEnd;
    final parts = current.split(':');
    final initial = TimeOfDay(
      hour: parts.isNotEmpty ? int.tryParse(parts[0]) ?? 23 : 23,
      minute: parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
    );
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null) return;
    final hm =
        '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    if (isStart) {
      await _settings.setQuietRange(hm, _settings.quietEnd);
    } else {
      await _settings.setQuietRange(_settings.quietStart, hm);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('免打扰')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const NotificationGuideCard(),
          const SizedBox(height: 4),
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.notifications_off_outlined),
              title: const Text('全局免打扰'),
              subtitle: const Text('开启后所有消息仍进通知栏，只是不响不震不弹横幅'),
              value: _settings.globalMuted,
              onChanged: (v) => _settings.setGlobalMuted(v),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.bedtime_outlined),
                  title: const Text('时段免打扰'),
                  subtitle: Text(
                    '${_settings.quietStart} - ${_settings.quietEnd}（跨零点自动处理）',
                  ),
                  value: _settings.quietHoursEnabled,
                  onChanged: (v) => _settings.setQuietHoursEnabled(v),
                ),
                if (_settings.quietHoursEnabled)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => _pickTime(true),
                            child: Text('开始 ${_settings.quietStart}'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => _pickTime(false),
                            child: Text('结束 ${_settings.quietEnd}'),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.priority_high),
              title: const Text('紧急穿透'),
              subtitle: const Text('level=err 的推送(错误/异常)默认穿透免打扰，照样响铃'),
              value: _settings.urgentPassthrough,
              onChanged: (v) => _settings.setUrgentPassthrough(v),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: Icon(
                _systemDndOn == true
                    ? Icons.do_not_disturb_on
                    : Icons.do_not_disturb_off_outlined,
                color: _systemDndOn == true ? Colors.orange : null,
              ),
              title: const Text('跟随系统免打扰'),
              subtitle: Text(
                _systemDndOn == null
                    ? '查询中…'
                    : (_systemDndOn == true
                          ? '当前跟随系统免打扰（系统 DND 已开启）'
                          : '系统 DND 当前关闭'),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _loadSystemDnd,
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text('按角色静音', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: kAgentRegistry
                  .map(
                    (a) => SwitchListTile(
                      title: Text(a.displayName),
                      subtitle: a.machine != null ? Text(a.machine!) : null,
                      value: _settings.isAgentMuted(a.id),
                      onChanged: (v) => _settings.setAgentMuted(a.id, v),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}
