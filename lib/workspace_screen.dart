import 'dart:async';

import 'package:flutter/material.dart';

import 'data/flowstate_database.dart';
import 'data/focus_sessions_repository.dart';
import 'data/tasks_repository.dart';
import 'focus_timer.dart';

const _surface = Color(0xFF19191F);
const _violet = Color(0xFFA78BFA);
const _muted = Color(0xFF9996A5);
const _eyebrow = TextStyle(
  color: _muted,
  fontSize: 10,
  letterSpacing: 1.15,
  fontWeight: FontWeight.w700,
);

class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({super.key, this.database});

  final FlowStateDatabase? database;

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen>
    with WidgetsBindingObserver {
  final _timer = FocusTimer();
  FlowStateDatabase? _database;
  bool _ownsDatabase = false;
  TasksRepository? _tasks;
  Stream<List<Task>>? _taskStream;
  Future<Duration>? _todayFocusTime;
  Future<List<FocusSession>>? _todaySessions;
  FocusSessionsRepository? _sessions;
  Timer? _ticker;
  int _selected = 0;
  bool _loading = true;
  String? _error;
  String? _lastSession;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final db = widget.database ?? FlowStateDatabase();
      _ownsDatabase = widget.database == null;
      final sessions = FocusSessionsRepository(db);
      final recovered = await sessions.recover();
      if (!mounted) {
        await db.close();
        return;
      }
      _database = db;
      _tasks = TasksRepository(db);
      _taskStream = _tasks!.watchTasks();
      _sessions = sessions;
      _refreshDashboardStats();
      if (recovered != null) {
        _timer.restore(recovered.elapsed, running: recovered.isRunning);
        if (recovered.isRunning) _startTicker();
      }
      setState(() => _loading = false);
    } catch (error) {
      if (mounted)
        setState(() {
          _error = error.toString();
          _loading = false;
        });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive && _timer.isRunning) {
      _sessions?.checkpoint();
    } else if (state == AppLifecycleState.resumed && _timer.isRunning) {
      _recoverRunningSession();
    }
  }

  Future<void> _recoverRunningSession() async {
    final recovered = await _sessions?.recover();
    if (!mounted || recovered == null || !recovered.isRunning) return;
    setState(() {
      _timer.restore(recovered.elapsed, running: true);
      _refreshDashboardStats();
    });
  }

  void _refreshDashboardStats() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final end = start.add(const Duration(days: 1));
    _todayFocusTime = _sessions?.completedDurationBetween(start, end);
    _todaySessions = _sessions?.completedBetween(start, end);
  }

  void _startTicker() {
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _timer.isRunning) setState(() {});
    });
  }

  Future<void> _startOrResume() async {
    if (_timer.isRunning || _sessions == null) return;
    await _sessions!.start();
    if (!mounted) return;
    setState(() {
      _timer.startOrResume();
      _startTicker();
    });
  }

  Future<void> _pause() async {
    if (!_timer.isRunning) return;
    final saved = await _sessions?.pause();
    if (!mounted || saved == null) return;
    _ticker?.cancel();
    _ticker = null;
    setState(_timer.pause);
  }

  Future<void> _finish() async {
    if (!_timer.hasStarted) return;
    final session = await _sessions?.finish();
    if (!mounted || session == null) return;
    _ticker?.cancel();
    _ticker = null;
    setState(() {
      _timer.finish();
      _lastSession = 'Completed · ${_durationLabel(session.elapsed)}';
      _refreshDashboardStats();
    });
  }

  Future<void> _cancel() async {
    if (!_timer.hasStarted) return;
    final session = await _sessions?.cancel();
    if (!mounted || session == null) return;
    _ticker?.cancel();
    _ticker = null;
    setState(() {
      _timer.cancel();
      _lastSession = 'Interrupted · ${_durationLabel(session.elapsed)}';
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    if (_ownsDatabase) _database?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: Text('Opening your local workspace…')),
      );
    }
    if (_error != null || _tasks == null || _sessions == null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Local data could not be opened.\n${_error ?? ''}',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final compact = MediaQuery.sizeOf(context).width < 760;
    final page = switch (_selected) {
      0 => _HomePage(
        tasks: _tasks!,
        taskStream: _taskStream!,
        todayFocusTime: _todayFocusTime!,
        todaySessions: _todaySessions!,
        onOpenTasks: () => setState(() => _selected = 1),
        onOpenFocus: () => setState(() => _selected = 2),
        timerElapsed: _timer.elapsed,
        timerRunning: _timer.isRunning,
      ),
      1 => _TasksPage(repository: _tasks!, taskStream: _taskStream!),
      _ => _FocusPage(
        elapsed: _timer.elapsed,
        hasStarted: _timer.hasStarted,
        isRunning: _timer.isRunning,
        lastSession: _lastSession,
        onStart: _startOrResume,
        onPause: _pause,
        onFinish: _finish,
        onCancel: _cancel,
      ),
    };

    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            if (!compact)
              _Sidebar(
                selected: _selected,
                onSelected: (value) => setState(() => _selected = value),
              ),
            Expanded(child: page),
          ],
        ),
      ),
      bottomNavigationBar: compact
          ? NavigationBar(
              selectedIndex: _selected,
              onDestinationSelected: (value) =>
                  setState(() => _selected = value),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home_rounded),
                  label: 'Home',
                ),
                NavigationDestination(
                  icon: Icon(Icons.checklist_outlined),
                  selectedIcon: Icon(Icons.checklist_rounded),
                  label: 'Tasks',
                ),
                NavigationDestination(
                  icon: Icon(Icons.bolt_outlined),
                  selectedIcon: Icon(Icons.bolt_rounded),
                  label: 'Focus',
                ),
              ],
            )
          : null,
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.selected, required this.onSelected});
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) => Container(
    width: 224,
    color: const Color(0xFF141418),
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 27),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.bubble_chart_rounded, color: _violet),
            SizedBox(width: 10),
            Text('FlowState', style: TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
        const SizedBox(height: 42),
        for (var index = 0; index < 3; index++)
          Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: Material(
              color: selected == index
                  ? const Color(0xFF292335)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                dense: true,
                leading: Icon(
                  [
                    Icons.home_rounded,
                    Icons.checklist_rounded,
                    Icons.hourglass_bottom_rounded,
                  ][index],
                  size: 19,
                  color: selected == index ? _violet : _muted,
                ),
                title: Text(
                  ['Home', 'Tasks', 'Focus'][index],
                  style: TextStyle(
                    fontSize: 13,
                    color: selected == index ? Colors.white : _muted,
                  ),
                ),
                onTap: () => onSelected(index),
                contentPadding: const EdgeInsets.symmetric(horizontal: 11),
                minLeadingWidth: 22,
              ),
            ),
          ),
        const Spacer(),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 11),
          child: Text('LOCAL · OFFLINE READY', style: _eyebrow),
        ),
      ],
    ),
  );
}

class _PageFrame extends StatelessWidget {
  const _PageFrame({
    required this.title,
    required this.subtitle,
    required this.child,
    this.action,
  });
  final String title;
  final String subtitle;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 760;
    return SingleChildScrollView(
      padding: EdgeInsets.all(compact ? 20 : 42),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.8,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          subtitle,
                          style: const TextStyle(color: _muted, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  if (action != null) action!,
                ],
              ),
              const SizedBox(height: 28),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

class _HomePage extends StatelessWidget {
  const _HomePage({
    required this.tasks,
    required this.taskStream,
    required this.todayFocusTime,
    required this.todaySessions,
    required this.onOpenTasks,
    required this.onOpenFocus,
    required this.timerElapsed,
    required this.timerRunning,
  });
  final TasksRepository tasks;
  final Stream<List<Task>> taskStream;
  final Future<Duration> todayFocusTime;
  final Future<List<FocusSession>> todaySessions;
  final VoidCallback onOpenTasks;
  final VoidCallback onOpenFocus;
  final Duration timerElapsed;
  final bool timerRunning;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final end = start.add(const Duration(days: 1));
    return _PageFrame(
      title: 'Today',
      subtitle: 'Make room for what matters.',
      action: TextButton.icon(
        onPressed: onOpenTasks,
        icon: const Icon(Icons.arrow_forward_rounded),
        label: const Text('View tasks'),
      ),
      child: StreamBuilder<List<Task>>(
        stream: taskStream,
        builder: (context, snapshot) {
          final allTasks = snapshot.data ?? const <Task>[];
          final due = allTasks
              .where(
                (task) =>
                    !task.isCompleted &&
                    (task.dueAt == null ||
                        (!task.dueAt!.isBefore(start) &&
                            task.dueAt!.isBefore(end))),
              )
              .take(4)
              .toList();
          final completed = allTasks
              .where(
                (task) =>
                    task.isCompleted &&
                    task.completedAt != null &&
                    !task.completedAt!.isBefore(start) &&
                    task.completedAt!.isBefore(end),
              )
              .length;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final narrow = constraints.maxWidth < 560;
                  final stats = [
                    FutureBuilder<Duration>(
                      future: todayFocusTime,
                      builder: (_, data) => _StatCard(
                        icon: Icons.schedule_rounded,
                        label: 'Focus time',
                        value: data.hasData ? _durationLabel(data.data!) : '…',
                      ),
                    ),
                    _StatCard(
                      icon: Icons.check_circle_outline_rounded,
                      label: 'Tasks completed',
                      value: '$completed',
                    ),
                    FutureBuilder<List<FocusSession>>(
                      future: todaySessions,
                      builder: (_, data) => _StatCard(
                        icon: Icons.auto_awesome_outlined,
                        label: 'Completed sessions',
                        value: data.hasData ? '${data.data!.length}' : '…',
                      ),
                    ),
                  ];
                  if (narrow)
                    return Column(
                      children: [
                        for (final stat in stats)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: stat,
                          ),
                      ],
                    );
                  return Row(
                    children: [
                      for (var i = 0; i < stats.length; i++)
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(
                              right: i == stats.length - 1 ? 0 : 12,
                            ),
                            child: stats[i],
                          ),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 20),
              _Panel(
                child: InkWell(
                  onTap: onOpenFocus,
                  borderRadius: BorderRadius.circular(16),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.bolt_rounded,
                          color: _violet,
                          size: 24,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                timerRunning
                                    ? 'Focus session in progress'
                                    : 'Ready for a focus session?',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                timerRunning
                                    ? _durationLabel(timerElapsed)
                                    : 'Your sessions are saved on this device.',
                                style: const TextStyle(
                                  color: _muted,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.arrow_forward_rounded, color: _muted),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Today’s tasks',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: onOpenTasks,
                    child: const Text('All tasks'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (snapshot.connectionState == ConnectionState.waiting)
                const _Panel(
                  child: Padding(
                    padding: EdgeInsets.all(18),
                    child: LinearProgressIndicator(),
                  ),
                )
              else if (due.isEmpty)
                _Panel(
                  child: Padding(
                    padding: const EdgeInsets.all(22),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.check_circle_outline_rounded,
                          color: _violet,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            allTasks.isEmpty
                                ? 'Nothing on your list yet. Add a task when you’re ready.'
                                : 'You’re all caught up for today.',
                            style: const TextStyle(color: _muted),
                          ),
                        ),
                        TextButton(
                          onPressed: onOpenTasks,
                          child: const Text('Add task'),
                        ),
                      ],
                    ),
                  ),
                )
              else
                _Panel(
                  child: Column(
                    children: [
                      for (var index = 0; index < due.length; index++)
                        _TaskRow(
                          task: due[index],
                          repository: tasks,
                          divider: index != due.length - 1,
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 20),
              const Text(
                'Your data stays on this device. Focus Lock is not implemented.',
                style: TextStyle(color: _muted, fontSize: 11),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => _Panel(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: const Color(0xFF292335),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: _violet),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(color: _muted, fontSize: 11),
                ),
                const SizedBox(height: 5),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 19,
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

class _TasksPage extends StatelessWidget {
  const _TasksPage({required this.repository, required this.taskStream});
  final TasksRepository repository;
  final Stream<List<Task>> taskStream;

  Future<void> _edit(BuildContext context, {Task? task}) async {
    final draft = await showDialog<_TaskDraft>(
      context: context,
      builder: (context) => _TaskEditorDialog(task: task),
    );
    if (draft == null) return;
    if (task == null) {
      await repository.create(
        title: draft.title,
        description: draft.description,
        dueAt: draft.dueAt,
        priority: draft.priority,
      );
    } else {
      await repository.updateTask(
        task,
        title: draft.title,
        description: draft.description,
        dueAt: draft.dueAt,
        priority: draft.priority,
      );
    }
  }

  Future<void> _delete(BuildContext context, Task task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete task?'),
        content: Text('“${task.title}” will be removed from this device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep task'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await repository.delete(task.id);
  }

  @override
  Widget build(BuildContext context) => _PageFrame(
    title: 'Tasks',
    subtitle: 'A clear list for the things you want to do.',
    action: FilledButton.icon(
      onPressed: () => _edit(context),
      icon: const Icon(Icons.add_rounded),
      label: const Text('Add task'),
    ),
    child: StreamBuilder<List<Task>>(
      stream: taskStream,
      builder: (context, snapshot) {
        final tasks = snapshot.data ?? const <Task>[];
        if (tasks.isEmpty)
          return const _Panel(
            child: Padding(
              padding: EdgeInsets.all(30),
              child: Center(
                child: Column(
                  children: [
                    Icon(Icons.checklist_rounded, size: 34, color: _violet),
                    SizedBox(height: 12),
                    Text(
                      'Your task list is empty',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    SizedBox(height: 5),
                    Text(
                      'Add a task to make a little progress.',
                      style: TextStyle(color: _muted),
                    ),
                  ],
                ),
              ),
            ),
          );
        final open = tasks.where((task) => !task.isCompleted).toList();
        final done = tasks.where((task) => task.isCompleted).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (open.isNotEmpty) ...[
              Text('TO DO · ${open.length}', style: _eyebrow),
              const SizedBox(height: 10),
              _Panel(
                child: Column(
                  children: [
                    for (var i = 0; i < open.length; i++)
                      _TaskRow(
                        task: open[i],
                        repository: repository,
                        divider: i < open.length - 1,
                        onEdit: () => _edit(context, task: open[i]),
                        onDelete: () => _delete(context, open[i]),
                      ),
                  ],
                ),
              ),
            ],
            if (done.isNotEmpty) ...[
              const SizedBox(height: 22),
              Text('COMPLETED · ${done.length}', style: _eyebrow),
              const SizedBox(height: 10),
              _Panel(
                child: Column(
                  children: [
                    for (var i = 0; i < done.length; i++)
                      _TaskRow(
                        task: done[i],
                        repository: repository,
                        divider: i < done.length - 1,
                        onEdit: () => _edit(context, task: done[i]),
                        onDelete: () => _delete(context, done[i]),
                      ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    ),
  );
}

class _TaskDraft {
  const _TaskDraft({
    required this.title,
    required this.description,
    required this.dueAt,
    required this.priority,
  });

  final String title;
  final String description;
  final DateTime? dueAt;
  final int priority;
}

/// Owns its text controllers so they outlive the dialog's closing animation.
class _TaskEditorDialog extends StatefulWidget {
  const _TaskEditorDialog({this.task});

  final Task? task;

  @override
  State<_TaskEditorDialog> createState() => _TaskEditorDialogState();
}

class _TaskEditorDialogState extends State<_TaskEditorDialog> {
  late final TextEditingController _titleController = TextEditingController(
    text: widget.task?.title ?? '',
  );
  late final TextEditingController _descriptionController =
      TextEditingController(text: widget.task?.description ?? '');
  late int _priority = widget.task?.priority ?? 0;
  late DateTime? _dueAt = widget.task?.dueAt;

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _save() {
    if (_titleController.text.trim().isEmpty) return;
    Navigator.pop(
      context,
      _TaskDraft(
        title: _titleController.text,
        description: _descriptionController.text,
        dueAt: _dueAt,
        priority: _priority,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.task == null ? 'New task' : 'Edit task'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _titleController,
              autofocus: true,
              maxLength: 200,
              onSubmitted: (_) => _save(),
              decoration: const InputDecoration(
                labelText: 'Task name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descriptionController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<int>(
              initialValue: _priority,
              decoration: const InputDecoration(
                labelText: 'Priority',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 0, child: Text('Normal')),
                DropdownMenuItem(value: 1, child: Text('High')),
                DropdownMenuItem(value: 2, child: Text('Urgent')),
              ],
              onChanged: (value) => setState(() => _priority = value ?? 0),
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event_outlined),
              title: Text(
                _dueAt == null ? 'No due date' : 'Due ${_dateLabel(_dueAt!)}',
              ),
              trailing: TextButton(
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _dueAt ?? DateTime.now(),
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null) setState(() => _dueAt = picked);
                },
                child: const Text('Choose'),
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({
    required this.task,
    required this.repository,
    required this.divider,
    this.onEdit,
    this.onDelete,
  });

  final Task task;
  final TasksRepository repository;
  final bool divider;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          children: [
            Checkbox(
              value: task.isCompleted,
              onChanged: (value) =>
                  repository.setCompleted(task, value ?? false),
            ),
            Expanded(
              child: InkWell(
                onTap: onEdit,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.title,
                        style: TextStyle(
                          decoration: task.isCompleted
                              ? TextDecoration.lineThrough
                              : null,
                          color: task.isCompleted ? _muted : Colors.white,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (task.description != null || task.dueAt != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          [
                            if (task.description != null) task.description!,
                            if (task.dueAt != null)
                              'Due ${_dateLabel(task.dueAt!)}',
                          ].join(' · '),
                          style: const TextStyle(color: _muted, fontSize: 11),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (task.priority > 0)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(
                  Icons.flag_rounded,
                  size: 17,
                  color: task.priority == 2 ? const Color(0xFFFF8A80) : _violet,
                ),
              ),
            if (onEdit != null)
              PopupMenuButton<String>(
                tooltip: 'Task actions',
                onSelected: (value) =>
                    value == 'edit' ? onEdit?.call() : onDelete?.call(),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
          ],
        ),
      ),
      if (divider)
        const Divider(
          height: 1,
          indent: 58,
          endIndent: 14,
          color: Color(0xFF302E37),
        ),
    ],
  );
}

class _FocusPage extends StatelessWidget {
  const _FocusPage({
    required this.elapsed,
    required this.hasStarted,
    required this.isRunning,
    required this.lastSession,
    required this.onStart,
    required this.onPause,
    required this.onFinish,
    required this.onCancel,
  });
  final Duration elapsed;
  final bool hasStarted;
  final bool isRunning;
  final String? lastSession;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onFinish;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => _PageFrame(
    title: 'Focus',
    subtitle: 'A little progress is still progress.',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Panel(
          child: Padding(
            padding: const EdgeInsets.all(26),
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.bolt_rounded, color: _violet),
                    const SizedBox(width: 8),
                    Text(
                      isRunning ? 'FOCUS IN PROGRESS' : 'FOCUS STOPWATCH',
                      style: _eyebrow,
                    ),
                    const Spacer(),
                    Text(
                      isRunning ? 'Active' : 'Offline timer',
                      style: const TextStyle(color: _muted, fontSize: 11),
                    ),
                  ],
                ),
                const SizedBox(height: 36),
                Text(
                  _durationLabel(elapsed),
                  semanticsLabel: 'Elapsed ${_durationLabel(elapsed)}',
                  style: const TextStyle(
                    fontFeatures: [FontFeature.tabularFigures()],
                    fontSize: 56,
                    letterSpacing: -2,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  isRunning
                      ? 'Every minute counts.'
                      : hasStarted
                      ? 'Paused — resume when you’re ready.'
                      : 'Start when you’re ready.',
                  style: const TextStyle(color: _muted, fontSize: 13),
                ),
                const SizedBox(height: 30),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: isRunning ? onPause : onStart,
                        icon: Icon(
                          isRunning
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                        label: Text(
                          isRunning
                              ? 'Pause'
                              : hasStarted
                              ? 'Resume'
                              : 'Start focus',
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: _violet,
                          foregroundColor: const Color(0xFF17131F),
                          minimumSize: const Size(0, 48),
                        ),
                      ),
                    ),
                    if (hasStarted) ...[
                      const SizedBox(width: 10),
                      IconButton.filledTonal(
                        tooltip: 'Finish session',
                        onPressed: onFinish,
                        icon: const Icon(Icons.check_rounded),
                      ),
                      IconButton(
                        tooltip: 'Cancel session',
                        onPressed: onCancel,
                        icon: const Icon(Icons.close_rounded, color: _muted),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
        if (lastSession != null) ...[
          const SizedBox(height: 14),
          _Panel(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  const Icon(Icons.history_rounded, color: _violet),
                  const SizedBox(width: 10),
                  Text(
                    'Last session: $lastSession',
                    style: const TextStyle(color: _muted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        const Text(
          'Sessions are saved locally. Interrupting a session records it as interrupted; only completed sessions count toward focus statistics. Focus Lock is not implemented.',
          style: TextStyle(color: _muted, fontSize: 12, height: 1.5),
        ),
      ],
    ),
  );
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    decoration: BoxDecoration(
      color: _surface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFF2B2933)),
    ),
    child: child,
  );
}

String _durationLabel(Duration value) {
  final hours = value.inHours.toString().padLeft(2, '0');
  final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
  return '$hours:$minutes:$seconds';
}

String _dateLabel(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
