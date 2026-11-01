import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowstate/data/flowstate_database.dart';
import 'package:flowstate/data/notes_repository.dart';
import 'package:flowstate/data/settings_repository.dart';

void main() {
  late FlowStateDatabase database;
  late NotesRepository notes;
  late SettingsRepository settings;

  setUp(() {
    database = FlowStateDatabase.forTesting(NativeDatabase.memory());
    notes = NotesRepository(database);
    settings = SettingsRepository(database);
  });

  tearDown(() async => database.close());

  group('notes', () {
    test('create stores timestamps and trims the title', () async {
      final createdAt = DateTime(2026, 11, 1, 9);
      await notes.create(
        title: '  Weekly plan  ',
        content: 'Ship milestone 1C',
        now: createdAt,
      );
      final note = (await notes.notes()).single;
      expect(note.title, 'Weekly plan');
      expect(note.content, 'Ship milestone 1C');
      expect(note.createdAt, createdAt);
      expect(note.updatedAt, createdAt);

      final updatedAt = DateTime(2026, 11, 1, 11);
      await notes.updateNote(
        note,
        title: 'Weekly plan v2',
        content: 'Ship 1C and verify',
        now: updatedAt,
      );
      final updated = (await notes.notes()).single;
      expect(updated.title, 'Weekly plan v2');
      expect(updated.createdAt, createdAt);
      expect(updated.updatedAt, updatedAt);
    });

    test('an empty title becomes a findable "Untitled note"', () async {
      await notes.create(title: '   ', content: 'Just the body');
      expect((await notes.notes()).single.title, NotesRepository.untitled);
    });

    test('search matches title or content, case-insensitively', () async {
      await notes.create(title: 'Weekly plan', content: 'Ship milestone 1C');
      await notes.create(
        title: 'Reading list',
        content: 'Two books about habit',
      );
      await notes.create(title: 'Shopping', content: 'Milk, bread');

      Future<List<String>> search(String query) async => [
        for (final note in await notes.watchNotes(query: query).first)
          note.title,
      ];

      expect(await search('WEEKLY'), ['Weekly plan']);
      expect(await search('habit'), ['Reading list']);
      expect(await search('milk'), ['Shopping']);
      expect(await search('nothing matches'), isEmpty);
      expect(await search(''), hasLength(3));
    });

    test(
      'notes are ordered by most recently edited and can be deleted',
      () async {
        await notes.create(
          title: 'Older',
          content: '',
          now: DateTime(2026, 11, 1, 8),
        );
        await notes.create(
          title: 'Newer',
          content: '',
          now: DateTime(2026, 11, 1, 10),
        );
        final ordered = await notes.watchNotes().first;
        expect(ordered.map((note) => note.title), ['Newer', 'Older']);

        expect(await notes.delete(ordered.first.id), 1);
        expect((await notes.notes()).single.title, 'Older');
      },
    );
  });

  group('settings', () {
    test('defaults are Monday weeks and a two-hour daily goal', () async {
      final value = await settings.load();
      expect(value.weekStart, WeekStart.monday);
      expect(value.dailyFocusGoalMinutes, 120);
    });

    test('preferences persist and are observable', () async {
      final observed = <AppSettings>[];
      final subscription = settings.watch().listen(observed.add);
      await pumpEventQueue();

      await settings.setWeekStart(WeekStart.sunday);
      await settings.setDailyFocusGoalMinutes(90);
      await pumpEventQueue();

      final stored = await settings.load();
      expect(stored.weekStart, WeekStart.sunday);
      expect(stored.dailyFocusGoalMinutes, 90);
      expect(observed.last.weekStart, WeekStart.sunday);
      expect(observed.last.dailyFocusGoalMinutes, 90);
      await subscription.cancel();
    });

    test('goal values are clamped to a usable range', () async {
      await settings.setDailyFocusGoalMinutes(1);
      expect(
        (await settings.load()).dailyFocusGoalMinutes,
        SettingsRepository.minimumGoalMinutes,
      );
      await settings.setDailyFocusGoalMinutes(5000);
      expect(
        (await settings.load()).dailyFocusGoalMinutes,
        SettingsRepository.maximumGoalMinutes,
      );
    });
  });
}
