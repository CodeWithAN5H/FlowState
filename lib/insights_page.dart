import 'dart:async';
import 'dart:math' as math;

import 'package:drift/drift.dart' show TableUpdate, TableUpdateQuery;
import 'package:flutter/material.dart';

import 'data/flowstate_database.dart';
import 'data/insights_repository.dart';
import 'data/settings_repository.dart';
import 'ui.dart';

class InsightsPage extends StatefulWidget {
  const InsightsPage({
    super.key,
    required this.database,
    required this.settings,
  });

  final FlowStateDatabase database;
  final AppSettings settings;

  @override
  State<InsightsPage> createState() => _InsightsPageState();
}

class _InsightsPageState extends State<InsightsPage> {
  late final InsightsRepository _repository = InsightsRepository(
    widget.database,
  );
  late StreamSubscription<Set<TableUpdate>> _changes;
  Future<InsightsSnapshot>? _snapshot;

  @override
  void initState() {
    super.initState();
    _reload();
    _changes = widget.database
        .tableUpdates(
          TableUpdateQuery.onAllTables([
            widget.database.tasks,
            widget.database.focusSessions,
            widget.database.habits,
            widget.database.habitCompletions,
            widget.database.preferences,
          ]),
        )
        .listen((_) => _reload());
  }

  @override
  void didUpdateWidget(InsightsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings.weekStart != widget.settings.weekStart ||
        oldWidget.settings.dailyFocusGoalMinutes !=
            widget.settings.dailyFocusGoalMinutes) {
      _reload();
    }
  }

  @override
  void dispose() {
    _changes.cancel();
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    setState(() {
      _snapshot = _repository.load(settings: widget.settings);
    });
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'Insights',
    subtitle: 'Measured on this device, from your own records.',
    child: FutureBuilder<InsightsSnapshot>(
      future: _snapshot,
      builder: (context, data) {
        final snapshot = data.data;
        if (snapshot == null) {
          return const Panel(
            child: Padding(
              padding: EdgeInsets.all(18),
              child: LinearProgressIndicator(),
            ),
          );
        }
        if (snapshot.isEmpty) {
          return const EmptyState(
            icon: Icons.insights_rounded,
            title: 'Nothing measured yet',
            message:
                'Finish a focus session, complete a task, or check in a habit. '
                'Insights only use records saved on this device — no sample '
                'data is ever shown.',
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 620;
                final cards = [
                  _Metric(
                    label: 'Today',
                    value: shortDurationLabel(snapshot.todayFocus),
                    detail:
                        '${snapshot.todaySessions} completed '
                        '${snapshot.todaySessions == 1 ? 'session' : 'sessions'}',
                  ),
                  _Metric(
                    label: 'This week',
                    value: shortDurationLabel(snapshot.weekFocus),
                    detail: '${snapshot.weekSessions} sessions',
                  ),
                  _Metric(
                    label: 'This month',
                    value: shortDurationLabel(snapshot.monthFocus),
                    detail: '${snapshot.monthSessions} sessions',
                  ),
                ];
                if (narrow) {
                  return Column(
                    children: [
                      for (final card in cards)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: card,
                        ),
                    ],
                  );
                }
                return Row(
                  children: [
                    for (var i = 0; i < cards.length; i++)
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(
                            right: i == cards.length - 1 ? 0 : 10,
                          ),
                          child: cards[i],
                        ),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 14),
            _GoalPanel(snapshot: snapshot),
            const SizedBox(height: 14),
            Panel(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('LAST 7 DAYS', style: kEyebrow),
                    const SizedBox(height: 16),
                    _FocusBars(days: snapshot.lastSevenDays),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, constraints) {
                final tasks = _Breakdown(
                  title: 'Tasks',
                  rows: [
                    ('Completed today', '${snapshot.tasksCompletedToday}'),
                    ('Completed this week', '${snapshot.tasksCompletedWeek}'),
                    ('Still open', '${snapshot.tasksOpen}'),
                  ],
                );
                final habits = _Breakdown(
                  title: 'Habits',
                  rows: [
                    ('Active habits', '${snapshot.activeHabits}'),
                    ('Checked in today', '${snapshot.habitsDoneToday}'),
                    (
                      'Week consistency',
                      '${(snapshot.habitConsistency * 100).round()}%',
                    ),
                  ],
                );
                if (constraints.maxWidth < 620) {
                  return Column(
                    children: [tasks, const SizedBox(height: 10), habits],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: tasks),
                    const SizedBox(width: 10),
                    Expanded(child: habits),
                  ],
                );
              },
            ),
          ],
        );
      },
    ),
  );
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    required this.detail,
  });

  final String label;
  final String value;
  final String detail;

  @override
  Widget build(BuildContext context) => Panel(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: kMuted, fontSize: 11)),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(detail, style: const TextStyle(color: kMuted, fontSize: 11)),
        ],
      ),
    ),
  );
}

class _GoalPanel extends StatelessWidget {
  const _GoalPanel({required this.snapshot});

  final InsightsSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final goal = Duration(minutes: snapshot.goalMinutes);
    final progress = goal == Duration.zero
        ? 0.0
        : (snapshot.todayFocus.inSeconds / goal.inSeconds).clamp(0.0, 1.0);
    return Panel(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.flag_rounded, size: 17, color: kViolet),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'DAILY GOAL · ${snapshot.goalMinutes}m',
                    style: kEyebrow,
                  ),
                ),
                Text(
                  '${(progress * 100).round()}%',
                  style: const TextStyle(color: kMuted, fontSize: 11),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                backgroundColor: kBorder,
                color: kViolet,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${shortDurationLabel(snapshot.todayFocus)} of '
              '${snapshot.goalMinutes}m focused today',
              style: const TextStyle(color: kMuted, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

class _FocusBars extends StatelessWidget {
  const _FocusBars({required this.days});

  final List<DailyFocus> days;

  @override
  Widget build(BuildContext context) {
    final maxSeconds = days.fold<int>(
      0,
      (value, day) => math.max(value, day.duration.inSeconds),
    );
    return SizedBox(
      height: 132,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final day in days)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      day.duration == Duration.zero
                          ? ''
                          : shortDurationLabel(day.duration),
                      style: const TextStyle(color: kMuted, fontSize: 9),
                    ),
                    const SizedBox(height: 5),
                    Container(
                      height: maxSeconds == 0
                          ? 4
                          : 4 + (84 * (day.duration.inSeconds / maxSeconds)),
                      decoration: BoxDecoration(
                        color: day.duration == Duration.zero
                            ? const Color(0xFF232028)
                            : kViolet,
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      weekdayLabel(day.date).substring(0, 1),
                      style: const TextStyle(color: kMuted, fontSize: 10),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Breakdown extends StatelessWidget {
  const _Breakdown({required this.title, required this.rows});

  final String title;
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) => Panel(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(), style: kEyebrow),
          const SizedBox(height: 10),
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(color: kMuted, fontSize: 12),
                    ),
                  ),
                  Text(
                    value,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
