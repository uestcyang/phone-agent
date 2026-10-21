import 'dart:async';
import 'package:flutter/material.dart';
import 'agent_registry.dart';
import 'task_rail.dart';

const globalTaskStateId = 'global-tasks';
bool get ownerTaskSummaryEnabled =>
    kAgentRegistryFallback.any((a) => a.id == 'agent_c');

bool isModelWakeCron(TaskSlot task) =>
    task.slotKind == 'agent_cron' &&
    task.enabled != false &&
    RegExp(r'^gpt-', caseSensitive: false).hasMatch(task.model ?? '') &&
    (task.modelUsage == 'direct' || task.modelUsage == 'conditional');

String cycleLabel(TaskSlot task) {
  final activity = task.gptActivity;
  if (activity?['mode'] == 'event') return '按事件';
  if (activity?['mode'] == 'routine') {
    final seconds = activity?['routine_seconds'];
    if (seconds is num && seconds > 0) return '例行≥${seconds ~/ 3600}小时';
  }
  if (task.modelUsage == 'conditional') return '触发待核实';
  final minutes = task.cycleMinutes;
  if (minutes != null && minutes > 0) {
    return minutes % 60 == 0 ? '每${minutes ~/ 60}小时' : '每$minutes分钟';
  }
  return (task.schedule ?? '').isEmpty ? '间隔未读取' : task.schedule!;
}

String _clock(DateTime time) {
  final local = time.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

String gptActivityLabel(TaskSlot task) {
  final a = task.gptActivity;
  if (a == null || a['record_status'] == 'unavailable') return 'GPT启动记录尚未接入';
  final started = a['gpt_started_24h'];
  final queued = a['queued_24h'];
  final unknown = a['unverified_queued_24h'];
  final pieces = <String>[
    started is num ? '24h 已核实启动 $started' : 'GPT启动待核实',
    if (queued is num) '入队 $queued',
    if (unknown is num && unknown > 0) '待核实 $unknown',
  ];
  return pieces.join(' · ');
}

String lastGptActivity(TaskSlot task) {
  final epoch = task.gptActivity?['last_gpt_started_at'];
  if (epoch is! num) return '最近24h暂无已核实的GPT启动';
  final time = DateTime.fromMillisecondsSinceEpoch((epoch * 1000).round());
  return '最近参与 ${_clock(time)}';
}

List<AgentSpec> summaryEndpoints(AgentSpec current, AgentSpec preferred) {
  final backup = current.id != preferred.id
      ? current
      : kAgentRegistryFallback.firstWhere(
          (a) => a.id != preferred.id,
          orElse: () => current,
        );
  return [preferred, if (backup.id != preferred.id) backup];
}

Map<String, ({int running, int failed})> paiModelTotals(List<TaskSlot> tasks) {
  final totals = <String, ({int running, int failed})>{};
  for (final task in tasks.where((t) => t.slotKind == 'pai')) {
    final key = task.workerLabel;
    final old = totals[key] ?? (running: 0, failed: 0);
    totals[key] = (
      running:
          old.running +
          ((task.status == 'running' || task.status == 'queued') ? 1 : 0),
      failed: old.failed + (task.status == 'failed' ? 1 : 0),
    );
  }
  return totals;
}

Future<void> showTaskSummary(
  BuildContext context,
  AgentSpec agent,
  String category, {
  bool backgroundRunning = false,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: '收起任务摘要',
  transitionDuration: const Duration(milliseconds: 120),
  pageBuilder: (ctx, _, _) => SafeArea(
    child: Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 44, left: 8, right: 8),
        child: Material(
          color: Theme.of(ctx).colorScheme.surface,
          elevation: 8,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 520,
              maxHeight: MediaQuery.sizeOf(ctx).height * .65,
            ),
            child: TaskSummaryPanel(
              agent: agent,
              category: category,
              backgroundRunning: backgroundRunning,
            ),
          ),
        ),
      ),
    ),
  ),
);

class TaskSummaryMenu extends StatelessWidget {
  const TaskSummaryMenu({
    super.key,
    required this.agent,
    this.backgroundRunning = false,
  });
  final AgentSpec agent;
  final bool backgroundRunning;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final category in const ['agent_cron', 'pai'])
        TextButton(
          key: ValueKey('task-menu-$category'),
          style: TextButton.styleFrom(
            minimumSize: const Size(38, 32),
            padding: const EdgeInsets.symmetric(horizontal: 5),
          ),
          onPressed: () => unawaited(
            showTaskSummary(
              context,
              agent,
              category,
              backgroundRunning: backgroundRunning,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(category),
              if (category == 'pai' && backgroundRunning)
                const Padding(
                  padding: EdgeInsets.only(left: 3),
                  child: Tooltip(
                    message: '有任务在后台运行',
                    child: Icon(Icons.more_time, size: 12, color: Colors.amber),
                  ),
                ),
            ],
          ),
        ),
    ],
  );
}

class TaskSummaryPanel extends StatefulWidget {
  const TaskSummaryPanel({
    super.key,
    required this.agent,
    required this.category,
    this.backgroundRunning = false,
    this.loadOnOpen = true,
    this.refreshAction,
  });
  final AgentSpec agent;
  final String category;
  final bool backgroundRunning, loadOnOpen;
  final Future<void> Function()? refreshAction;
  @override
  State<TaskSummaryPanel> createState() => _TaskSummaryPanelState();
}

class _TaskSummaryPanelState extends State<TaskSummaryPanel>
    with WidgetsBindingObserver {
  bool _loading = false;
  Timer? _refreshTimer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    TaskRailStore.dashboardVisible = true;
    if (widget.loadOnOpen) {
      unawaited(_refresh());
      _startRefreshTimer();
    }
  }

  void _startRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && !_loading) unawaited(_refresh());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _refreshTimer?.cancel();
    if (state == AppLifecycleState.resumed && widget.loadOnOpen) {
      unawaited(_refresh());
      _startRefreshTimer();
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    TaskRailStore.dashboardVisible = false;
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      if (widget.refreshAction != null) {
        await widget.refreshAction!();
        return;
      }
      final preferred =
          TaskRailStore.dashboardEndpoint ??
          kAgentRegistryFallback.firstWhere(
            (a) => a.id == 'agent_c',
            orElse: () => widget.agent,
          );

      final endpoints = summaryEndpoints(widget.agent, preferred);
      AgentTaskState? best;
      for (final agent in endpoints) {
        if (!mounted) break;
        await TaskRailStore.refresh(
          agentId: globalTaskStateId,
          host: agent.host,
          port: agent.port,
          force: true,
          scope: 'dashboard',
        );
        final state = TaskRailStore.stateFor(globalTaskStateId).value;
        if (!state.unavailable) {
          best = state;
          TaskRailStore.dashboardEndpoint = agent;
          if (widget.category != 'agent_cron' ||
              state.gptSchema == 'gpt-agent_cron/v1') {
            break;
          }
        }
      }
      if (best != null) TaskRailStore.stateFor(globalTaskStateId).value = best;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _cronName(TaskSlot task) =>
      (task.desc ?? task.label ?? 'Task').replaceFirst('heartbeat:', '');
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AgentTaskState>(
    valueListenable: TaskRailStore.stateFor(globalTaskStateId),
    builder: (context, state, _) {
      final crons = state.slots.where(isModelWakeCron).toList();
      final totals = paiModelTotals(state.slots);
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 14, right: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.category == 'agent_cron'
                        ? 'agent_cron · GPT参与'
                        : 'pai · 近24小时',
                  ),
                ),
                IconButton(
                  tooltip: '刷新',
                  onPressed: _loading ? null : _refresh,
                  icon: const Icon(Icons.refresh, size: 18),
                ),
                IconButton(
                  tooltip: '收起',
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                state.fetchedAt == null
                    ? '打开期间自动刷新'
                    : '更新 ${_clock(state.fetchedAt!)} · 打开期间自动刷新',
                key: const ValueKey('task-refreshed-at'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          if (widget.category == 'agent_cron')
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: Text(
                '仅列GPT任务。启动按原始记录核对；入队不等于调用。',
                style: TextStyle(fontSize: 12),
              ),
            ),
          if (state.unavailable || state.sourceWarning != null)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Text(state.sourceWarning ?? '刷新失败，显示上次读取的数据。'),
            ),
          if (widget.category == 'pai' && widget.backgroundRunning)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Text('当前对话有任务在后台运行'),
            ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.category == 'agent_cron') ...[
                    if (crons.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          _loading
                              ? '正在读取…'
                              : (state.unavailable
                                    ? '暂时读不到GPT任务'
                                    : state.sourceWarning != null
                                    ? '尚未读取到GPT任务'
                                    : '没有启用的GPT agent_cron'),
                        ),
                      ),
                    for (final task in crons)
                      ListTile(
                        dense: true,
                        title: Text(_cronName(task)),
                        trailing: Text(
                          cycleLabel(task),
                          style: const TextStyle(color: Colors.tealAccent),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${task.gptActivity?['owner'] ?? ""} · ${task.model ?? ""}',
                              style: const TextStyle(fontSize: 11),
                            ),
                            Text(
                              task.gptActivity?['text'] as String? ??
                                  (task.modelUsage == 'conditional'
                                      ? '模型触发方式待核实'
                                      : cycleLabel(task)),
                            ),
                            Text(
                              gptActivityLabel(task),
                              style: const TextStyle(fontSize: 12),
                            ),
                            Text(
                              lastGptActivity(task),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                  ] else ...[
                    if (totals.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          _loading
                              ? '正在读取…'
                              : (state.unavailable
                                    ? '暂时读不到派单'
                                    : state.sourceWarning != null
                                    ? '尚未读取到派单'
                                    : '近24小时没有派单'),
                        ),
                      ),
                    for (final entry in totals.entries)
                      ListTile(
                        dense: true,
                        title: Text(entry.key),
                        subtitle: Text(
                          '进行中 ${entry.value.running} · 失败 ${entry.value.failed}',
                          style: TextStyle(
                            color: entry.value.failed > 0
                                ? Colors.redAccent
                                : null,
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ],
      );
    },
  );
}
