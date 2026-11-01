import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'data/backup_service.dart';
import 'data/settings_repository.dart';
import 'ui.dart';

const _jsonGroup = XTypeGroup(label: 'JSON backup', extensions: ['json']);

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.settings,
    required this.repository,
    required this.backup,
    required this.onDataReplaced,
  });

  final AppSettings settings;
  final SettingsRepository repository;
  final BackupService backup;

  /// Called after a restore or reset so the workspace can drop live state.
  final VoidCallback onDataReplaced;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String? _dataPath;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    getApplicationSupportDirectory().then((directory) {
      if (mounted) setState(() => _dataPath = directory.path);
    });
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final stamp = DateTime.now().toIso8601String().substring(0, 10);
      final location = await getSaveLocation(
        suggestedName: 'flowstate-backup-$stamp.json',
        acceptedTypeGroups: const [_jsonGroup],
      );
      if (location == null) return;
      await widget.backup.writeBackup(File(location.path));
      _notify('Backup saved to ${location.path}');
    } catch (error) {
      _notify('Backup failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    setState(() => _busy = true);
    try {
      final file = await openFile(acceptedTypeGroups: const [_jsonGroup]);
      if (file == null) return;
      final source = await file.readAsString();
      final BackupPreview preview;
      try {
        preview = widget.backup.inspect(source);
      } on BackupException catch (error) {
        _notify(error.message);
        return;
      }
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => _RestoreDialog(preview: preview),
      );
      if (confirmed != true) return;
      final result = await widget.backup.restore(source);
      widget.onDataReplaced();
      _notify(
        'Restored ${result.counts.total} records. '
        '${result.safetyBackupPath == null ? '' : 'Previous data saved as a safety backup.'}',
      );
    } catch (error) {
      _notify('Restore failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => const _ResetDialog(),
    );
    if (confirmed != true) return;
    await widget.backup.resetAllData();
    widget.onDataReplaced();
    _notify('All local data was deleted.');
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'Settings',
    subtitle: 'Local preferences, your data, and what this app does.',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('APPEARANCE'),
        Panel(
          child: ListTile(
            leading: const Icon(Icons.dark_mode_outlined, color: kViolet),
            title: const Text('Dark theme'),
            subtitle: const Text(
              'FlowState is dark by default. A light theme is planned, so no '
              'theme switch is offered yet.',
            ),
          ),
        ),
        const SizedBox(height: 18),
        const _SectionLabel('HABITS & WEEK'),
        Panel(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Week starts on',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Used for habit weeks and weekly insights. Days are still '
                  'counted in your local time.',
                  style: TextStyle(color: kMuted, fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 12),
                SegmentedButton<WeekStart>(
                  segments: const [
                    ButtonSegment(
                      value: WeekStart.monday,
                      label: Text('Monday'),
                    ),
                    ButtonSegment(
                      value: WeekStart.sunday,
                      label: Text('Sunday'),
                    ),
                  ],
                  selected: {widget.settings.weekStart},
                  onSelectionChanged: (value) =>
                      widget.repository.setWeekStart(value.first),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        const _SectionLabel('FOCUS'),
        Panel(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text(
                        'Daily focus goal',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Drives the goal progress on Insights. The focus timer '
                        'is a stopwatch, so there is no countdown preset to set.',
                        style: TextStyle(
                          color: kMuted,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                DropdownButton<int>(
                  value:
                      _goalValues.contains(
                        widget.settings.dailyFocusGoalMinutes,
                      )
                      ? widget.settings.dailyFocusGoalMinutes
                      : null,
                  hint: Text('${widget.settings.dailyFocusGoalMinutes}m'),
                  items: [
                    for (final minutes in _goalValues)
                      DropdownMenuItem(
                        value: minutes,
                        child: Text('${minutes}m'),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      widget.repository.setDailyFocusGoalMinutes(value);
                    }
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        const _SectionLabel('YOUR DATA'),
        Panel(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.save_alt_rounded, color: kViolet),
                title: const Text('Export a backup'),
                subtitle: const Text(
                  'Writes tasks, habits and their history, notes, focus '
                  'sessions, and preferences to one JSON file.',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                enabled: !_busy,
                onTap: _export,
              ),
              const Divider(height: 1, color: kDivider),
              ListTile(
                leading: const Icon(Icons.settings_backup_restore_rounded),
                title: const Text('Restore from a backup'),
                subtitle: const Text(
                  'Replaces every local record after you confirm. A safety '
                  'backup of the current data is written first. Merging is not '
                  'supported.',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                enabled: !_busy,
                onTap: _restore,
              ),
              const Divider(height: 1, color: kDivider),
              ListTile(
                leading: const Icon(
                  Icons.delete_forever_rounded,
                  color: Color(0xFFFF8A80),
                ),
                title: const Text('Reset application data'),
                subtitle: const Text(
                  'Deletes all local tasks, habits, notes, sessions, and '
                  'preferences. This cannot be undone.',
                ),
                onTap: _reset,
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        const _SectionLabel('ABOUT'),
        Panel(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: [
                const ListTile(
                  leading: Icon(Icons.info_outline_rounded),
                  title: Text('FlowState 0.1.0'),
                  subtitle: Text('Milestone 1C · habits, notes, insights'),
                ),
                ListTile(
                  leading: const Icon(Icons.storage_rounded),
                  title: const Text('Local storage'),
                  subtitle: Text(
                    _dataPath == null
                        ? 'Resolving the app support folder…'
                        : 'SQLite database in $_dataPath',
                  ),
                ),
                const ListTile(
                  leading: Icon(Icons.lock_outline_rounded, color: kViolet),
                  title: Text('Privacy'),
                  subtitle: Text(
                    'Everything you write stays in a local SQLite file. There '
                    'is no account, no cloud sync, and no analytics. Backups '
                    'are only written where you choose to save them.',
                  ),
                ),
                const ListTile(
                  leading: Icon(Icons.shield_outlined),
                  title: Text('Focus Lock'),
                  subtitle: Text(
                    'Website and application blocking is not implemented yet. '
                    'Sessions are local records, not verified focus time.',
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
      ],
    ),
  );
}

const _goalValues = [30, 60, 90, 120, 180, 240];

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8, left: 2),
    child: Text(text, style: kEyebrow),
  );
}

class _RestoreDialog extends StatelessWidget {
  const _RestoreDialog({required this.preview});

  final BackupPreview preview;

  @override
  Widget build(BuildContext context) {
    final counts = preview.counts;
    return AlertDialog(
      title: const Text('Replace all local data?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            preview.exportedAt == null
                ? 'This backup contains:'
                : 'Backup from ${shortDateLabel(preview.exportedAt!)} '
                      '${preview.exportedAt!.toLocal().toIso8601String().substring(11, 16)}:',
          ),
          const SizedBox(height: 10),
          Text(
            '${counts.tasks} tasks · ${counts.focusSessions} focus sessions\n'
            '${counts.habits} habits · ${counts.habitCompletions} check-ins\n'
            '${counts.notes} notes · ${counts.preferences} preferences',
            style: const TextStyle(height: 1.5),
          ),
          const SizedBox(height: 12),
          const Text(
            'Restoring replaces everything currently on this device. Your '
            'current data is backed up automatically first; merging is not '
            'supported.',
            style: TextStyle(color: kMuted, fontSize: 12, height: 1.5),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Replace data'),
        ),
      ],
    );
  }
}

class _ResetDialog extends StatefulWidget {
  const _ResetDialog();

  @override
  State<_ResetDialog> createState() => _ResetDialogState();
}

class _ResetDialogState extends State<_ResetDialog> {
  final _confirmation = TextEditingController();

  @override
  void dispose() {
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Delete all local data?'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Every task, habit, note, focus session, and preference stored on '
            'this device will be deleted. This cannot be undone — export a '
            'backup first if you may want the data later.',
            style: TextStyle(color: kMuted, fontSize: 12, height: 1.5),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _confirmation,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Type RESET to confirm',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _confirmation.text.trim() == 'RESET'
            ? () => Navigator.pop(context, true)
            : null,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFFFF8A80),
          foregroundColor: const Color(0xFF2A1210),
        ),
        child: const Text('Delete everything'),
      ),
    ],
  );
}
