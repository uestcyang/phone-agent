import 'transport_routes.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'agent_registry.dart';
import 'avatar_store.dart';
import 'avatar_widgets.dart';
import 'background_store.dart';
import 'constants.dart';
import 'device_credentials.dart';
import 'diagnostics_page.dart';
import 'foreground_service.dart';
import 'mute_settings_page.dart';
import 'pairing.dart';
import 'ws_client.dart';

export 'constants.dart';

const String _prefHostPrefix = 'server_host_';
const String _prefPortPrefix = 'server_port_';

Future<(String, int)> loadServerAddress(
  String agentId,
  String fallbackHost,
  int fallbackPort,
) async {
  final prefs = await SharedPreferences.getInstance();
  final host = prefs.getString('$_prefHostPrefix$agentId') ?? fallbackHost;
  final port = prefs.getInt('$_prefPortPrefix$agentId') ?? fallbackPort;
  return (host, port);
}

class SettingsPage extends StatefulWidget {
  final String? agentId;
  final String? initialHost;
  final int? initialPort;
  final WsClient? ws;

  const SettingsPage({
    super.key,
    this.agentId,
    this.initialHost,
    this.initialPort,
    this.ws,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const List<AgentSpec> _agents = kAgentRegistry;

  late final TextEditingController _hostCtrl;
  late final TextEditingController _portCtrl;

  late String _advAgentId;

  String? _testResult;
  Map<String, dynamic>? _healthJson;
  bool _testing = false;
  bool? _batteryIgnoring;
  String? _versionLabel;

  @override
  void initState() {
    super.initState();
    _advAgentId = _resolveAdvAgentId();
    _hostCtrl = TextEditingController(text: widget.initialHost ?? '');
    _portCtrl = TextEditingController(
      text: widget.initialPort?.toString() ?? '',
    );

    if (widget.initialHost == null || widget.initialPort == null) {
      _loadAdvAddress(_advAgentId);
    }
    _refreshAvatars();
    _loadBatteryStatus();
    _loadVersionInfo();
    PairingManager.addListener(_onPairingChanged);
  }

  String _resolveAdvAgentId() {
    final id = widget.agentId;
    if (id != null && _agents.any((s) => s.id == id)) return id;
    return _agents.first.id;
  }

  AgentSpec _specFor(String agentId) =>
      _agents.firstWhere((s) => s.id == agentId, orElse: () => _agents.first);

  Future<void> _refreshAvatars() async {
    await AgentAvatarStore.loadAll(_agents.map((s) => s.id));
  }

  void _onPairingChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadVersionInfo() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() => _versionLabel = '${info.version} (${info.buildNumber})');
  }

  Future<void> _loadBatteryStatus() async {
    final ignoring = await ForegroundKeepAlive.isIgnoringBatteryOptimizations();
    if (!mounted) return;
    setState(() => _batteryIgnoring = ignoring);
  }

  Future<void> _guideBatteryOptimization() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('加入电池优化白名单'),
        content: const Text(
          '接下来会跳转到系统设置页，请选择"不限制/允许后台运行"。\n\n'
          '这样息屏后 App 才能持续保活、不被系统当作空闲进程冻结，'
          '通知和消息才能及时送达。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('去设置'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ForegroundKeepAlive.requestIgnoreBatteryOptimizations();
    if (!mounted) return;

    await _loadBatteryStatus();
  }

  @override
  void dispose() {
    PairingManager.removeListener(_onPairingChanged);
    _hostCtrl.dispose();
    _portCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAdvAddress(String agentId) async {
    final spec = _specFor(agentId);
    final (host, port) = await loadServerAddress(agentId, spec.host, spec.port);
    if (!mounted) return;
    setState(() {
      _hostCtrl.text = host;
      _portCtrl.text = port.toString();

      _testResult = null;
      _healthJson = null;
    });
  }

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _testResult = null;
      _healthJson = null;
    });
    final host = _hostCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim()) ?? kDefaultPort;
    try {
      final resp = await http
          .get(
            backendUri(host, port, '/healthz'),
            headers: {'Authorization': 'Bearer ${tokenFor(host, port)}'},
          )
          .timeout(const Duration(seconds: 8));
      Map<String, dynamic>? parsed;
      try {
        parsed = jsonDecode(resp.body) as Map<String, dynamic>;
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _testResult = '${resp.statusCode}\n${resp.body}';
        _healthJson = parsed;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testResult = '请求失败: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _testing = false;
        });
      }
    }
  }

  Future<void> _save() async {
    final host = _hostCtrl.text.trim();
    final port =
        int.tryParse(_portCtrl.text.trim()) ?? _specFor(_advAgentId).port;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_prefHostPrefix$_advAgentId', host);
    await prefs.setInt('$_prefPortPrefix$_advAgentId', port);
    if (!mounted) return;

    if (widget.agentId != null && _advAgentId == widget.agentId) {
      Navigator.of(context).pop((host, port));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$_advAgentId 地址已保存，下次连接生效'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pairing = _buildPairingSection(context);
    final battery = _buildBatteryOptimizationSection(context);
    final sections = <Widget>[
      ?pairing,
      ?battery,
      _buildAvatarsSection(context),
      _buildBackgroundSection(context),
      _buildMuteSection(context),
      _buildAdvancedSection(context),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          for (final s in sections)
            Padding(padding: const EdgeInsets.only(bottom: 16), child: s),
          if (_versionLabel != null)
            Center(
              child: Text(
                '版本 $_versionLabel',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget? _buildPairingSection(BuildContext context) {
    final recs = PairingManager.pending.values.toList();
    if (recs.isEmpty) return null;
    return Card(
      color: Theme.of(
        context,
      ).colorScheme.primaryContainer.withValues(alpha: 0.3),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final rec in recs)
            ListTile(
              leading: const Icon(Icons.qr_code),
              title: Text('配对码: ${rec.code}'),
              subtitle: Text(() {
                final remaining = rec.expiresAt
                    .difference(DateTime.now())
                    .inSeconds;
                return remaining > 0
                    ? '${rec.displayName} · ${rec.host}:${rec.port} · ${remaining}s 后过期，等待服务器批准'
                    : '${rec.displayName} · ${rec.host}:${rec.port} · 已过期';
              }()),
            ),
        ],
      ),
    );
  }

  Widget? _buildBatteryOptimizationSection(BuildContext context) {
    if (_batteryIgnoring == null || _batteryIgnoring == true) return null;
    return Card(
      color: Theme.of(
        context,
      ).colorScheme.errorContainer.withValues(alpha: 0.3),
      child: ListTile(
        leading: const Icon(Icons.battery_alert_outlined),
        title: const Text('电池优化可能导致后台掉线'),
        subtitle: const Text('点击加入白名单，避免熄屏后被系统限制'),
        trailing: OutlinedButton(
          onPressed: _guideBatteryOptimization,
          child: const Text('去设置'),
        ),
      ),
    );
  }

  String? _avatarBusyId;

  Future<void> _pickAvatar(String agentId) async {
    setState(() => _avatarBusyId = agentId);
    try {
      final ok = await AgentAvatarStore.pick(agentId);
      if (!mounted) return;
      if (ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$agentId 头像已更新'),
            duration: const Duration(seconds: 1),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _avatarBusyId = null);
    }
  }

  Future<void> _clearAvatar(String agentId) async {
    await AgentAvatarStore.clear(agentId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$agentId 已恢复默认头像'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  Widget _buildAvatarsSection(BuildContext context) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 2),
            child: Text('角色头像', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              '点任意一行从相册换图，每个角色各存一张',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          for (final spec in _agents) _buildAvatarRow(context, spec),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget _buildAvatarRow(BuildContext context, AgentSpec spec) {
    final busy = _avatarBusyId == spec.id;
    return ValueListenableBuilder<String?>(
      valueListenable: AgentAvatarStore.notifierFor(spec.id),
      builder: (context, path, _) {
        final custom = path != null;
        return ListTile(
          leading: SizedBox(
            width: 48,
            height: 48,
            child: Stack(
              alignment: Alignment.center,
              children: [
                AgentAvatar(
                  agentId: spec.id,
                  displayName: spec.displayName,
                  radius: 24,
                ),
                if (busy) const CircularProgressIndicator(strokeWidth: 2),
              ],
            ),
          ),
          title: Text(spec.displayName),
          subtitle: Text(
            custom ? '已自定义' : '默认头像',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          trailing: custom
              ? TextButton(
                  onPressed: busy ? null : () => _clearAvatar(spec.id),
                  child: const Text('恢复默认'),
                )
              : const Icon(Icons.image_outlined, size: 20, color: Colors.grey),
          onTap: busy ? null : () => _pickAvatar(spec.id),
        );
      },
    );
  }

  Widget _buildMuteSection(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.notifications_off_outlined),
        title: const Text('免打扰'),
        subtitle: const Text('全局开关 / 时段 / 按角色静音'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const MuteSettingsPage())),
      ),
    );
  }

  bool _bgBusy = false;

  Future<void> _pickBackground() async {
    setState(() => _bgBusy = true);
    try {
      final ok = await pickChatBackground();
      if (!mounted) return;
      if (ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('聊天背景已更新'),
            duration: Duration(seconds: 1),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _bgBusy = false);
    }
  }

  Future<void> _clearBackground() async {
    await clearChatBackground();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已恢复默认背景'), duration: Duration(seconds: 1)),
    );
  }

  Widget _buildBackgroundSection(BuildContext context) {
    return ValueListenableBuilder<ChatBackgroundSettings>(
      valueListenable: chatBackground,
      builder: (context, bg, _) {
        final path = bg.path;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '聊天背景',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                if (path != null && File(path).existsSync())
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Stack(
                      fit: StackFit.passthrough,
                      children: [
                        Image.file(
                          File(path),
                          height: 120,
                          width: double.infinity,
                          fit: BoxFit.cover,
                        ),
                        Positioned.fill(
                          child: Container(
                            color: Colors.black.withValues(alpha: bg.dim),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Container(
                    height: 60,
                    alignment: Alignment.centerLeft,
                    child: const Text(
                      '未设置，使用默认背景',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _bgBusy ? null : _pickBackground,
                      icon: const Icon(Icons.image_outlined, size: 18),
                      label: Text(_bgBusy ? '处理中…' : '从相册选择'),
                    ),
                    const SizedBox(width: 8),
                    if (path != null)
                      TextButton(
                        onPressed: _clearBackground,
                        child: const Text('恢复默认'),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Text('遮罩暗度', style: TextStyle(fontSize: 12)),
                    Expanded(
                      child: Slider(
                        value: bg.dim,
                        min: 0.0,
                        max: kMaxBgDim,
                        divisions: 16,
                        label: bg.dim.toStringAsFixed(2),
                        onChanged: (v) => setChatBackgroundDim(v),
                      ),
                    ),
                    Text(
                      bg.dim.toStringAsFixed(2),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAdvancedSection(BuildContext context) {
    final outline = Theme.of(context).colorScheme.outline;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(
          '高级 / 开发者选项',
          style: TextStyle(fontSize: 13, color: outline),
        ),
        leading: Icon(Icons.tune, size: 18, color: outline),

        onExpansionChanged: (open) {
          if (open && !_testing && _testResult == null) _testConnection();
        },
        childrenPadding: const EdgeInsets.only(bottom: 8),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildAdvAgentPicker(context),
          const SizedBox(height: 12),
          TextField(
            controller: _hostCtrl,
            decoration: const InputDecoration(labelText: 'Server Host'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _portCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Server Port'),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              OutlinedButton(
                onPressed: _testing ? null : _testConnection,
                child: Text(_testing ? '测试中…' : '测试连接'),
              ),
              const SizedBox(width: 12),
              FilledButton(onPressed: _save, child: const Text('保存并重连')),
            ],
          ),
          if (_healthJson != null) ...[
            const SizedBox(height: 12),
            _buildMemoStatus(_healthJson!),
          ],
          if (_testResult != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                _testResult!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ),
          ],
          if (widget.ws != null) ...[
            const SizedBox(height: 12),
            Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: const Icon(Icons.troubleshoot),
                title: const Text('连接诊断'),
                subtitle: ValueListenableBuilder(
                  valueListenable: widget.ws!.diagLog,
                  builder: (context, entries, _) =>
                      Text('最近断连记录 ${entries.length} 条'),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => DiagnosticsPage(ws: widget.ws!),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAdvAgentPicker(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '目标角色',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final spec in _agents)
              ChoiceChip(
                label: Text(spec.displayName),
                selected: _advAgentId == spec.id,
                onSelected: (sel) {
                  if (!sel || _advAgentId == spec.id) return;
                  setState(() => _advAgentId = spec.id);
                  _loadAdvAddress(spec.id);
                },
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildMemoStatus(Map<String, dynamic> h) {
    final memoOk = h['memo_ok'] == true;
    final recallOk = h['memo_recall_ok'] ?? '?';
    final recallFail = h['memo_recall_fail'] ?? '?';
    final storeOk = h['memo_store_ok'] ?? '?';
    final storeFail = h['memo_store_fail'] ?? '?';
    final lastError = (h['memo_last_error'] ?? '') as String;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: (memoOk ? Colors.teal : Colors.redAccent).withValues(
          alpha: 0.12,
        ),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: memoOk ? Colors.teal : Colors.redAccent),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                memoOk ? Icons.check_circle : Icons.error,
                size: 16,
                color: memoOk ? Colors.teal : Colors.redAccent,
              ),
              const SizedBox(width: 6),
              Text(
                '记忆链路: ${memoOk ? "健康" : "异常"}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '召回 成功$recallOk / 失败$recallFail　存储 成功$storeOk / 失败$storeFail',
            style: const TextStyle(fontSize: 12),
          ),
          if (lastError.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '最近错误: $lastError',
                style: const TextStyle(fontSize: 12, color: Colors.redAccent),
              ),
            ),
        ],
      ),
    );
  }
}
