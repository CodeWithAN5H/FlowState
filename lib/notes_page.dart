import 'package:flutter/material.dart';

import 'data/flowstate_database.dart';
import 'data/notes_repository.dart';
import 'ui.dart';

class NotesPage extends StatefulWidget {
  const NotesPage({super.key, required this.repository});

  final NotesRepository repository;

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _edit({Note? note}) async {
    final draft = await showDialog<_NoteDraft>(
      context: context,
      builder: (_) => _NoteEditorDialog(note: note),
    );
    if (draft == null) return;
    if (note == null) {
      await widget.repository.create(
        title: draft.title,
        content: draft.content,
      );
    } else {
      await widget.repository.updateNote(
        note,
        title: draft.title,
        content: draft.content,
      );
    }
  }

  Future<void> _delete(Note note) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete note?'),
        content: Text('“${note.title}” will be removed from this device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep note'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.repository.delete(note.id);
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'Notes',
    subtitle: 'A quiet place for things worth keeping.',
    action: FilledButton.icon(
      onPressed: () => _edit(),
      icon: const Icon(Icons.edit_note_rounded),
      label: const Text('New note'),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _search,
          onChanged: (value) => setState(() => _query = value),
          decoration: InputDecoration(
            hintText: 'Search notes',
            prefixIcon: const Icon(Icons.search_rounded, size: 20),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () {
                      _search.clear();
                      setState(() => _query = '');
                    },
                  ),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 16),
        StreamBuilder<List<Note>>(
          stream: widget.repository.watchNotes(query: _query),
          builder: (context, snapshot) {
            final notes = snapshot.data;
            if (notes == null) {
              return const Panel(
                child: Padding(
                  padding: EdgeInsets.all(18),
                  child: LinearProgressIndicator(),
                ),
              );
            }
            if (notes.isEmpty) {
              return _query.trim().isEmpty
                  ? EmptyState(
                      icon: Icons.sticky_note_2_outlined,
                      title: 'No notes yet',
                      message:
                          'Capture a thought, a plan, or a quote. Notes are '
                          'stored only on this device.',
                      action: FilledButton.icon(
                        onPressed: () => _edit(),
                        icon: const Icon(Icons.edit_note_rounded),
                        label: const Text('Write a note'),
                      ),
                    )
                  : const EmptyState(
                      icon: Icons.search_off_rounded,
                      title: 'No matching notes',
                      message:
                          'No note title or content contains that search. '
                          'Try a shorter word.',
                    );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _query.trim().isEmpty
                      ? 'ALL NOTES · ${notes.length}'
                      : 'MATCHES · ${notes.length}',
                  style: kEyebrow,
                ),
                const SizedBox(height: 10),
                Panel(
                  child: Column(
                    children: [
                      for (var index = 0; index < notes.length; index++)
                        _NoteRow(
                          note: notes[index],
                          divider: index < notes.length - 1,
                          onOpen: () => _edit(note: notes[index]),
                          onDelete: () => _delete(notes[index]),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ],
    ),
  );
}

class _NoteRow extends StatelessWidget {
  const _NoteRow({
    required this.note,
    required this.divider,
    required this.onOpen,
    required this.onDelete,
  });

  final Note note;
  final bool divider;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final preview = note.content.trim().replaceAll('\n', ' ');
    return Column(
      children: [
        InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2, right: 12),
                  child: Icon(Icons.article_outlined, size: 17, color: kViolet),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        note.title,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (preview.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          preview,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: kMuted,
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      ],
                      const SizedBox(height: 6),
                      Text(
                        'Created ${shortDateLabel(note.createdAt)} · '
                        'Edited ${shortDateLabel(note.updatedAt)}',
                        style: const TextStyle(color: kMuted, fontSize: 10),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Note actions',
                  onSelected: (value) =>
                      value == 'edit' ? onOpen() : onDelete(),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('Edit')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (divider) const Divider(height: 1, indent: 44, color: kDivider),
      ],
    );
  }
}

class _NoteDraft {
  const _NoteDraft({required this.title, required this.content});

  final String title;
  final String content;
}

class _NoteEditorDialog extends StatefulWidget {
  const _NoteEditorDialog({this.note});

  final Note? note;

  @override
  State<_NoteEditorDialog> createState() => _NoteEditorDialogState();
}

class _NoteEditorDialogState extends State<_NoteEditorDialog> {
  late final TextEditingController _title = TextEditingController(
    text: widget.note?.title ?? '',
  );
  late final TextEditingController _content = TextEditingController(
    text: widget.note?.content ?? '',
  );

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  void _save() {
    if (_title.text.trim().isEmpty && _content.text.trim().isEmpty) {
      Navigator.pop(context);
      return;
    }
    Navigator.pop(
      context,
      _NoteDraft(title: _title.text, content: _content.text),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.note == null ? 'New note' : 'Edit note'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _title,
              autofocus: true,
              maxLength: 120,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _content,
              minLines: 8,
              maxLines: 16,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                labelText: 'Note',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
                helperText: 'Plain text. Markdown is stored exactly as typed.',
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
