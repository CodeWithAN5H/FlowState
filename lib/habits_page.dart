import 'package:flutter/material.dart';

import 'data/flowstate_database.dart';
import 'data/habits_repository.dart';
import 'data/settings_repository.dart';
import 'ui.dart';

class HabitsPage extends StatefulWidget {
  const HabitsPage({
    super.key,
    required this.repository,
    required this.weekStart,
  });

  final HabitsRepository repository;
  final WeekStart weekStart;

  @override
  State<HabitsPage> createState() => _HabitsPageState();
}

class _HabitsPageState extends State<HabitsPage> {
  late Stream<List<HabitSummary>> _summaries = _watch();

  @override
  void didUpdateWidget(HabitsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.weekStart != widget.weekStart) _summaries = _watch();
  }

  Stream<List<HabitSummary>> _watch() => widget.repository.watchSummaries(
    today: DateTime.now(),
    weekStart: widget.weekStart,
  );

  Future<void> _edit({Habit? habit}) async {
    final draft = await showDialog<_HabitDraft>(
      context: context,
      builder: (_) => _HabitEditorDialog(habit: habit),
    );
    if (draft == null) return;
    if (habit == null) {
      await widget.repository.create(name: draft.name, details: draft.details);
    } else {
      await widget.repository.updateHabit(
        habit,
        name: draft.name,
        details: draft.details,
      );
    }
  }

  Future<void> _delete(Habit habit) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete habit?'),
        content: Text(
          '“${habit.name}” and its whole completion history will be removed '
          'from this device. Archiving keeps the history instead.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep habit'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.repository.delete(habit.id);
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'Habits',
    subtitle: 'Small things, repeated, become who you are.',
    action: FilledButton.icon(
      onPressed: () => _edit(),
      icon: const Icon(Icons.add_rounded),
      label: const Text('New habit'),
    ),
    child: StreamBuilder<List<HabitSummary>>(
      stream: _summaries,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Panel(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text('Habits could not be loaded: ${snapshot.error}'),
            ),
          );
        }
        final all = snapshot.data;
        if (all == null) {
          return const Panel(
            child: Padding(
              padding: EdgeInsets.all(18),
              child: LinearProgressIndicator(),
            ),
          );
        }
        final active = all.where((item) => !item.habit.isArchived).toList();
        final archived = all.where((item) => item.habit.isArchived).toList();
        if (all.isEmpty) {
          return EmptyState(
            icon: Icons.repeat_rounded,
            title: 'No habits yet',
            message:
                'Add a habit you want to repeat. Check in each day to build a '
                'streak; your history stays on this device.',
            action: FilledButton.icon(
              onPressed: () => _edit(),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Create a habit'),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (active.isEmpty)
              const EmptyState(
                icon: Icons.archive_outlined,
                title: 'No active habits',
                message: 'Restore an archived habit below or add a new one.',
              )
            else ...[
              Text(
                'TODAY · ${active.where((i) => i.completedToday).length} '
                'OF ${active.length} DONE',
                style: kEyebrow,
              ),
              const SizedBox(height: 10),
              for (final summary in active)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _HabitCard(
                    summary: summary,
                    onToggle: (done) => widget.repository.setCompletedOn(
                      summary.habit.id,
                      day: DateTime.now(),
                      completed: done,
                    ),
                    onEdit: () => _edit(habit: summary.habit),
                    onArchive: () =>
                        widget.repository.setArchived(summary.habit, true),
                    onDelete: () => _delete(summary.habit),
                  ),
                ),
            ],
            if (archived.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text('ARCHIVED · ${archived.length}', style: kEyebrow),
              const SizedBox(height: 10),
              for (final summary in archived)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _HabitCard(
                    summary: summary,
                    onToggle: null,
                    onEdit: null,
                    onArchive: () =>
                        widget.repository.setArchived(summary.habit, false),
                    onDelete: () => _delete(summary.habit),
                    archived: true,
                  ),
                ),
            ],
          ],
        );
      },
    ),
  );
}

class _HabitCard extends StatelessWidget {
  const _HabitCard({
    required this.summary,
    required this.onToggle,
    required this.onEdit,
    required this.onArchive,
    required this.onDelete,
    this.archived = false,
  });

  final HabitSummary summary;
  final ValueChanged<bool>? onToggle;
  final VoidCallback? onEdit;
  final VoidCallback? onArchive;
  final VoidCallback? onDelete;
  final bool archived;

  @override
  Widget build(BuildContext context) {
    final habit = summary.habit;
    final percentage = (summary.weekConsistency * 100).round();
    return Panel(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Checkbox(
                  value: summary.completedToday,
                  onChanged: onToggle == null
                      ? null
                      : (value) => onToggle!(value ?? false),
                ),
                Expanded(
                  child: InkWell(
                    onTap: onEdit,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            habit.name,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: archived ? kMuted : Colors.white,
                            ),
                          ),
                          if (habit.details != null) ...[
                            const SizedBox(height: 3),
                            Text(
                              habit.details!,
                              style: const TextStyle(
                                color: kMuted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                          const SizedBox(height: 5),
                          Text(
                            archived
                                ? '${summary.totalCompletions} check-ins stored'
                                : '${summary.currentStreak}-day streak · '
                                      '$percentage% this week',
                            style: const TextStyle(color: kMuted, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Habit actions',
                  onSelected: (value) => switch (value) {
                    'edit' => onEdit?.call(),
                    'archive' => onArchive?.call(),
                    _ => onDelete?.call(),
                  },
                  itemBuilder: (_) => [
                    if (onEdit != null)
                      const PopupMenuItem(value: 'edit', child: Text('Edit')),
                    PopupMenuItem(
                      value: 'archive',
                      child: Text(archived ? 'Restore' : 'Archive'),
                    ),
                    const PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: summary.weekConsistency,
                  minHeight: 4,
                  backgroundColor: kBorder,
                  color: kViolet,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Row(
                children: [
                  for (var index = 0; index < 7; index++)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _DayPip(
                        done: summary.weekDays[index],
                        future: index >= summary.weekComputedDays,
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
}

class _DayPip extends StatelessWidget {
  const _DayPip({required this.done, required this.future});

  final bool done;
  final bool future;

  @override
  Widget build(BuildContext context) => Container(
    width: 22,
    height: 22,
    decoration: BoxDecoration(
      color: done ? kViolet : const Color(0xFF232028),
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: future ? const Color(0xFF232028) : kBorder),
    ),
    child: done
        ? const Icon(Icons.check_rounded, size: 14, color: Color(0xFF17131F))
        : null,
  );
}

class _HabitDraft {
  const _HabitDraft({required this.name, required this.details});

  final String name;
  final String? details;
}

class _HabitEditorDialog extends StatefulWidget {
  const _HabitEditorDialog({this.habit});

  final Habit? habit;

  @override
  State<_HabitEditorDialog> createState() => _HabitEditorDialogState();
}

class _HabitEditorDialogState extends State<_HabitEditorDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.habit?.name ?? '',
  );
  late final TextEditingController _details = TextEditingController(
    text: widget.habit?.details ?? '',
  );

  @override
  void dispose() {
    _name.dispose();
    _details.dispose();
    super.dispose();
  }

  void _save() {
    if (_name.text.trim().isEmpty) return;
    Navigator.pop(
      context,
      _HabitDraft(name: _name.text, details: _details.text),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.habit == null ? 'New habit' : 'Edit habit'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            maxLength: 120,
            onSubmitted: (_) => _save(),
            decoration: const InputDecoration(
              labelText: 'Habit name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _details,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Notes (optional)',
              border: OutlineInputBorder(),
            ),
          ),
        ],
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
