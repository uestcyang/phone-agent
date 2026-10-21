import 'transport_routes.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'device_credentials.dart';
import 'agent_registry.dart';

class TaskRailColors {
  static const running = Color(0xFF3B82F6);
  static const done = Color(0xFF22C55E);
  static const failed = Color(0xFFEF4444);
  static const agent_cron = Color(0xFFEAB308);

  static Color of(TaskSlot t) {
    if (t.slotKind == 'agent_cron') return agent_cron;
    switch (t.status) {
      case 'running':
        return running;
      case 'done':
        return done;
      case 'failed':
        return failed;
      default:
        return running;
    }
  }
}

class TaskSlot {
  TaskSlot({
    required this.slot,
    required this.slotKind,
    required this.id,
    required this.status,
    this.label,
    this.host,
    this.model,
    this.engine,
    this.elapsedS,
    this.pidAlive,
    this.summaryShort,
    this.schedule,
    this.lastStatus,
    this.desc,
    this.provider,
    this.noAgent,
    this.modelUsage,
    this.modelCondition,
    this.script,
    this.nextRun,
    this.enabled,
    this.cycleMinutes,
    this.gptActivity,
  });

  final String slot;
  final String slotKind;
  final String id;
  final String status;
  final String? label;
  final String? host;
  final String? model;
  final String? engine;
  final int? elapsedS;
  final bool? pidAlive;
  final String? summaryShort;
  final int? cycleMinutes;
  final String? schedule;
  final String? lastStatus;
  final String? desc;
  final String? provider;
  final bool? noAgent;
  final String? modelUsage;
  final String? modelCondition;
  final String? script;
  final String? nextRun;
  final bool? enabled;

  final Map<String, dynamic>? gptActivity;

  static TaskSlot? tryParse(Map<String, dynamic> m) {
    final slot = m['slot'];
    if (slot is! String || slot.isEmpty) return null;
    return TaskSlot(
      slot: slot,
      slotKind:
          (m['slot_kind'] as String?) ??
          (slot.startsWith('agent_cron') ? 'agent_cron' : 'pai'),
      id: (m['id'] as String?) ?? '',
      status: (m['status'] as String?) ?? 'running',
      label: (m['label'] ?? m['name']) as String?,
      host: m['host'] as String?,
      model: m['model'] as String?,
      engine: m['engine'] as String?,
      elapsedS: (m['elapsed_s'] as num?)?.round(),
      pidAlive: m['pid_alive'] as bool?,
      summaryShort: m['summary_short'] as String?,
      schedule: m['schedule'] as String?,
      cycleMinutes: (m['cycle_minutes'] as num?)?.round(),
      lastStatus: m['last_status'] as String?,
      desc: m['desc'] as String?,
      provider: m['provider'] as String?,
      noAgent: m['no_agent'] as bool?,
      modelUsage: m['model_usage'] as String?,
      modelCondition: m['model_condition'] as String?,
      script: m['script'] as String?,
      nextRun: m['next_run'] as String?,
      enabled: m['enabled'] as bool?,
      gptActivity:
          m['gpt_activity'] is Map &&
              m['gpt_activity']['schema'] == 'gpt-agent_cron/v1'
          ? Map<String, dynamic>.from(m['gpt_activity'] as Map)
          : null,
    );
  }

  String get pillText => slot;

  String get workerLabel {
    if (slotKind == 'agent_cron') {
      final m = (model ?? '').trim();
      final p = (provider ?? '').trim();
      if (m.isNotEmpty && p.isNotEmpty) return '$m/$p';
      if (m.isNotEmpty) return m;
      if (modelUsage == 'none') return '纯脚本';
      return '模型未核实';
    }
    final m = (model ?? '').trim();
    final e = (engine ?? '').trim();
    if (e == 'shell') return '脚本执行（模型未核实）';
    if (m.isNotEmpty) return m;
    if (e.isNotEmpty) return e;
    return '';
  }

  String get nextRunLocal {
    final s = (nextRun ?? '').trim();
    if (s.isEmpty) return '';
    try {
      final dt = DateTime.parse(s).toLocal();
      String two(int v) => v < 10 ? '0$v' : '$v';
      return '${dt.month.toString().padLeft(2, '0')}-${two(dt.day)} '
          '${two(dt.hour)}:${two(dt.minute)}';
    } catch (_) {
      return '时间未识别';
    }
  }

  String get scheduleShort {
    final s = (schedule ?? '').trim();
    if (s.isEmpty) return '';
    final bare = s.split('(').first.trim();
    final match = RegExp(r'^every\s+(\d+)\s*([mhsd])$').firstMatch(bare);
    if (match == null) return bare;
    final unit = {'m': '分钟', 'h': '小时', 's': '秒', 'd': '天'}[match.group(2)]!;
    return '每${match.group(1)}$unit';
  }
}

class AgentTaskState {
  const AgentTaskState({
    required this.slots,
    required this.unavailable,
    this.routingLabel,
    this.sourceWarning,
    this.fetchedAt,
    this.sampledAt,
    this.gptSchema,
  });
  final String? routingLabel;
  final String? sourceWarning;
  final List<TaskSlot> slots;
  final bool unavailable;
  final DateTime? fetchedAt, sampledAt;
  final String? gptSchema;

  static const initial = AgentTaskState(
    slots: <TaskSlot>[],
    unavailable: false,
  );
}

class TaskRailStore {
  TaskRailStore._();

  static final http.Client _readClient = http.Client();
  static bool dashboardVisible = false;
  static AgentSpec? dashboardEndpoint;
  static final Map<String, ValueNotifier<AgentTaskState>> _byAgent = {};
  static final Map<String, DateTime> _lastOkByAgent = {};
  static final Map<String, Future<void>> _inFlightByAgent = {};
  static final Map<String, int> _generation = {};

  static ValueNotifier<AgentTaskState> stateFor(String agentId) =>
      _byAgent.putIfAbsent(
        agentId,
        () => ValueNotifier<AgentTaskState>(AgentTaskState.initial),
      );

  static const Duration _minInterval = Duration(seconds: 20);

  static Future<void> refresh({
    required String agentId,
    required String host,
    required int port,
    bool force = false,
    String? scope,
    http.Client? client,
    Future<String?> Function(String, int)? credentialLoader,
  }) {
    final key = '$agentId|$host|$port|$scope';
    final pending = _inFlightByAgent[key];
    if (pending != null) return pending;
    final lastOk =
        _lastOkByAgent[key] ?? DateTime.fromMillisecondsSinceEpoch(0);
    if (!force && DateTime.now().difference(lastOk) < _minInterval) {
      return Future<void>.value();
    }
    final generation = (_generation[agentId] ?? 0) + 1;
    _generation[agentId] = generation;
    final future =
        _fetch(
          agentId: agentId,
          host: host,
          port: port,
          scope: scope,
          key: key,
          generation: generation,
          client: client,
          credentialLoader: credentialLoader,
        ).whenComplete(() {
          _inFlightByAgent.remove(key);
        });
    _inFlightByAgent[key] = future;
    return future;
  }

  static Future<void> _fetch({
    required String agentId,
    required String host,
    required int port,
    required String key,
    required int generation,
    String? scope,
    http.Client? client,
    Future<String?> Function(String, int)? credentialLoader,
  }) async {
    final notifier = stateFor(agentId);
    final connection = client ?? _readClient;
    void unavailable() {
      if (_generation[agentId] != generation) return;
      final old = notifier.value;
      notifier.value = AgentTaskState(
        slots: old.slots,
        unavailable: true,
        sourceWarning: '连接暂不可用，显示上次读取的数据。',
        routingLabel: old.routingLabel,
        fetchedAt: old.fetchedAt,
        sampledAt: old.sampledAt,
        gptSchema: old.gptSchema,
      );
    }

    try {
      final token = await (credentialLoader ?? DeviceCredentials.load)(
        host,
        port,
      ).timeout(const Duration(seconds: 2));
      final resp = await TransportRoutes.instance
          .get(
            host,
            port,
            '/tasks?others=0${scope == null ? "" : "&scope=$scope"}',
            headers: {
              'Authorization': 'Bearer ${token ?? ""}',
              'Cache-Control': 'no-cache',
            },
            timeout: const Duration(seconds: 5),
            client: connection,
          )
          .timeout(const Duration(seconds: 8));
      if (_generation[agentId] != generation) return;
      if (resp.statusCode != 200) {
        unavailable();
        return;
      }
      final body = jsonDecode(utf8.decode(resp.bodyBytes));
      if (body is! Map || body['ok'] != true || body['tasks'] is! List) {
        unavailable();
        return;
      }
      final meta = body['meta'] as Map?;
      if (scope == 'dashboard' &&
          (meta?['scope'] != 'dashboard' ||
              meta?['role'] != 'agent_cron' ||
              meta?['summary_schema'] != 'task-summary/v2')) {
        throw StateError('看板端尚未更新');
      }
      final parsed = <TaskSlot>[];
      for (final item in body['tasks'] as List) {
        if (item is Map<String, dynamic>) {
          final task = TaskSlot.tryParse(item);
          if (task != null) parsed.add(task);
        }
      }
      parsed.sort(railOrder);
      final routing = meta?['model_route'] as Map?;
      notifier.value = AgentTaskState(
        slots: parsed,
        unavailable: false,
        fetchedAt: DateTime.now(),
        sampledAt: meta?['generated_at'] is num
            ? DateTime.fromMillisecondsSinceEpoch(
                ((meta!['generated_at'] as num) * 1000).round(),
              )
            : null,
        gptSchema: meta?['gpt_cron_schema'] as String?,
        sourceWarning:
            scope == 'dashboard' &&
                meta?['remote_host'] != null &&
                meta?['remote_ok'] != true
            ? '部分跨机数据暂未更新，显示已读取部分。'
            : null,
        routingLabel: routing == null
            ? null
            : '${routing['policy']} · 当前 ${routing['status'] == 'READY' ? routing['model'] : '待额度恢复'}',
      );
      _lastOkByAgent[key] = DateTime.now();
    } catch (_) {
      unavailable();
    }
  }

  static int railOrder(TaskSlot a, TaskSlot b) {
    final ka = a.slotKind == 'agent_cron' ? 1 : 0;
    final kb = b.slotKind == 'agent_cron' ? 1 : 0;
    if (ka != kb) return ka - kb;
    return _num(a.slot).compareTo(_num(b.slot));
  }

  static int _num(String slot) {
    final m = RegExp(r'(\d+)$').firstMatch(slot);
    return m == null ? 0 : int.parse(m.group(1)!);
  }

  static Future<Map<String, dynamic>?> detail({
    required String host,
    required int port,
    required String slot,
    String? scope,
  }) async {
    try {
      final uri = backendUri(
        host,
        port,
        '/tasks/$slot${scope == null ? "" : "?scope=$scope"}',
      );
      final resp = await http
          .get(
            uri,
            headers: {
              'Authorization':
                  "Bearer ${await DeviceCredentials.load(host, port) ?? ''}",
            },
          )
          .timeout(const Duration(seconds: 10));
      final body = jsonDecode(utf8.decode(resp.bodyBytes));
      if (body is Map<String, dynamic>) return body;
    } catch (_) {}
    return null;
  }
}

class TaskRail extends StatefulWidget {
  const TaskRail({
    super.key,
    required this.agentId,
    required this.host,
    required this.port,
  });

  final String agentId;
  final String host;
  final int port;

  @override
  State<TaskRail> createState() => _TaskRailState();
}

class _TaskRailState extends State<TaskRail> {
  bool _expanded = false;

  static const double _panelBottomGap = 110;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AgentTaskState>(
      valueListenable: TaskRailStore.stateFor(widget.agentId),
      builder: (context, state, _) {
        if (!_expanded) {
          if (state.slots.isEmpty && !state.unavailable) {
            return const SizedBox.shrink();
          }
          return Positioned(
            top: 8,
            right: 8,
            child: _CollapsedBadge(
              state: state,
              onTap: () => setState(() => _expanded = true),
            ),
          );
        }
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => setState(() => _expanded = false),
                child: Container(color: Colors.black.withValues(alpha: 0.12)),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              left: 56,
              bottom: _panelBottomGap,
              child: _ExpandedPanel(
                agentId: widget.agentId,
                host: widget.host,
                port: widget.port,
                state: state,
                onClose: () => setState(() => _expanded = false),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CollapsedBadge extends StatelessWidget {
  const _CollapsedBadge({required this.state, required this.onTap});

  final AgentTaskState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = state.unavailable ? '－' : '▶${state.slots.length}';
    final color = state.unavailable ? Colors.grey : TaskRailColors.running;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Container(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: color.withValues(alpha: state.unavailable ? 0.55 : 0.92),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }
}

class _ExpandedPanel extends StatelessWidget {
  const _ExpandedPanel({
    required this.agentId,
    required this.host,
    required this.port,
    required this.state,
    required this.onClose,
  });

  final String agentId;
  final String host;
  final int port;
  final AgentTaskState state;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(16),
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '任务台账',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                ),
                IconButton(
                  tooltip: '收起',
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  icon: const Icon(Icons.close),
                  onPressed: onClose,
                ),
              ],
            ),
            const Divider(height: 4),
            Flexible(
              child: state.slots.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        state.unavailable ? '该角色暂无台账' : '暂无任务',
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.grey,
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final t in state.slots)
                            _TaskPill(task: t, host: host, port: port),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskPill extends StatelessWidget {
  const _TaskPill({required this.task, required this.host, required this.port});

  final TaskSlot task;
  final String host;
  final int port;

  @override
  Widget build(BuildContext context) {
    final color = TaskRailColors.of(task);
    final isCron = task.slotKind == 'agent_cron';

    final worker = task.workerLabel;
    final schedule = task.scheduleShort;
    final next = task.nextRunLocal;
    String line3;
    if (isCron) {
      final stopped = task.enabled == false;
      final segs = <String>[];
      if (schedule.isNotEmpty) {
        segs.add('${task.noAgent == true ? "脚本周期" : "苏醒"} $schedule');
      }
      final condition = (task.modelCondition ?? '').trim();
      if (condition.isNotEmpty) segs.add(condition);
      if (stopped) {
        segs.add('已停');
      } else if (next.isNotEmpty) {
        segs.add('下次 $next');
      } else {
        segs.add('下次未预约');
      }
      line3 = segs.join(' · ');
    } else {
      final st = task.status;
      final el = task.elapsedS;
      String dur;
      if (el == null) {
        dur = '';
      } else if (el < 60) {
        dur = '$el 秒';
      } else if (el < 3600) {
        dur = '${(el / 60).round()} 分';
      } else {
        dur = '${(el / 3600).round()}h${((el % 3600) / 60).round()}m';
      }
      final segs = <String>[];
      if (dur.isNotEmpty) segs.add(dur);
      if (task.pidAlive == false) segs.add('进程已不在');
      line3 = segs.isEmpty ? st : '$st · ${segs.join(" · ")}';
    }

    final shortName = isCron
        ? (task.desc ?? task.label ?? '未命名巡检')
        : (task.label ?? '(无标签)');
    return GestureDetector(
      onTap: () => _openDetail(context),
      onLongPress: () async {
        if (task.id.isEmpty) return;
        await Clipboard.setData(ClipboardData(text: task.id));
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已复制 ${task.id}'),
            duration: const Duration(seconds: 2),
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.45),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                task.pillText,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                  shadows: [
                    Shadow(
                      color: Color(0x99000000),
                      blurRadius: 2,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),

            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    shortName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      shadows: [
                        Shadow(
                          color: Color(0x99000000),
                          blurRadius: 2,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                  if (worker.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      worker,
                      softWrap: true,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        shadows: [
                          Shadow(
                            color: Color(0x99000000),
                            blurRadius: 2,
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (line3.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      line3,
                      softWrap: true,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                        shadows: [
                          Shadow(
                            color: Color(0x99000000),
                            blurRadius: 2,
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openDetail(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _TaskDetailSheet(task: task, host: host, port: port),
    );
  }
}

class _TaskDetailSheet extends StatelessWidget {
  const _TaskDetailSheet({
    required this.task,
    required this.host,
    required this.port,
  });

  final TaskSlot task;
  final String host;
  final int port;

  @override
  Widget build(BuildContext context) {
    final color = TaskRailColors.of(task);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        task.slot,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 13,
                          shadows: [
                            Shadow(
                              color: Color(0x99000000),
                              blurRadius: 2,
                              offset: Offset(0, 1),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        (task.slotKind == 'agent_cron' ? task.desc : null) ??
                            task.label ??
                            '(无标签)',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                SelectableText(
                  task.id,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
                const Divider(height: 18),
                FutureBuilder<Map<String, dynamic>?>(
                  future: TaskRailStore.detail(
                    host: host,
                    port: port,
                    slot: task.slot,
                  ),
                  builder: (context, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 18),
                        child: Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      );
                    }
                    final body = snap.data;
                    final t = (body?['task'] as Map?)?.cast<String, dynamic>();
                    if (t == null) {
                      return const Text(
                        '详情拉取失败(台账已刷新?)',
                        style: TextStyle(fontSize: 12, color: Colors.orange),
                      );
                    }
                    final meta = (body?['meta'] as Map?)
                        ?.cast<String, dynamic>();
                    final scopeNote = task.slotKind == 'agent_cron'
                        ? (meta?['cron_scope_note'] as String?)
                        : null;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ..._detailRows(t),
                        if (scopeNote != null && scopeNote.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            scopeNote,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _detailRows(Map<String, dynamic> t) {
    final rows = <Widget>[];
    void add(String k, Object? v) {
      if (v == null) return;
      final s = v is String ? v : v.toString();
      if (s.isEmpty) return;
      rows.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 74,
                child: Text(
                  k,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
              Expanded(
                child: SelectableText(s, style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
      );
    }

    if (task.slotKind == 'agent_cron') {
      add('说明', t['desc']);
      add('任务名', t['name']);

      final current = TaskSlot.tryParse({...t, 'slot': task.slot}) ?? task;
      add('工作模型', current.workerLabel);
      add('模型触发', current.modelCondition);
      add('脚本', t['script']);
      add('状态', '定时任务${t['enabled'] == false ? '(已停)' : ''}');
      add('周期', t['schedule']);
      add('机器', t['host']);
      add('下次', t['next_run']);
      add('上次', t['last_run']);
      add('上次结果', t['last_status']);
    } else {
      add('状态', t['status']);
      add('机器', t['host']);
      add('模型', [t['model'], t['engine']].where((e) => e != null).join(' / '));
      final el = (t['elapsed_s'] as num?)?.round();
      if (el != null) add('用时', el >= 60 ? '${(el / 60).round()} 分钟' : '$el 秒');
      add('进程存活', t['pid_alive'] == true ? '是' : '否');
      final ago = (t['last_write_s_ago'] as num?)?.round();
      if (ago != null) add('最后写入', '$ago 秒前');
      add('产出摘要', t['result_excerpt'] ?? t['summary_short']);
      add('工作目录', t['work_dir']);
      add('说明', t['detail_note']);
      final tail = t['out_tail'];
      if (tail is List && tail.isNotEmpty) {
        add('最近输出', tail.map((e) => e.toString()).join('\n'));
      }
    }
    add('简报', t['prompt_path']);
    return rows;
  }
}
