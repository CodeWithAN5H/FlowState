import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flowstate/data/flowstate_database.dart';
import 'package:flowstate/data/notes_repository.dart';
import 'package:flowstate/data/settings_repository.dart';

File createTempDatabaseFile(String label) => File(
  '${Directory.systemTemp.path}/flowstate-$label-${DateTime.now().microsecondsSinceEpoch}.sqlite',
);

void main() {
  late FlowStateDatabase database;
  late NotesRepository notes;
  late SettingsRepository settings;
  final at = DateTime(2026, 10, 30, 9);

  setUp(() {
    database = FlowStateDatabase.forTesting(NativeDatabase.memory());
    notes = NotesRepository(database);
    settings = SettingsRepository(database);
  });

  tearDown(() async => database.close());

  group('notes', () {
    test('create, edit, delete and keep timestamps', () async {
      final id = await notes.create(
        title: '  Weekly plan  ',
        content: 'Ship milestone 1C',
        now: at,
      );
      var note = (await database.select(database.notes).get()).single;
      expect(note.title, 'Weekly plan');
      expect(note.content, 'Ship milestone 1C');
      expect(note.createdAt, at);
      expect(note.updatedAt, at);

      final later = at.add(const Duration(hours: 2));
      await notes.updateNote(
        note,
        title: 'Weekly plan v2',
        content: '# Focus\n\n- habits\n- notes',
        now: later,
      );
      note = (await database.select(database.notes).get()).single;
      expect(note.title, 'Weekly plan v2');
      expect(note.content, contains('# Focus'));
      expect(note.createdAt, at);
      expect(note.updatedAt, later);
      expect(await notes.byId(id), isA<Note>());

      expect(await notes.delete(id), 1);
      expect(await database.select(database.notes).get(), isEmpty);
    });

    test('blank titles fall back to a readable placeholder', () async {
      await notes.create(title: '   ', now: at);
      expect(
        (await database.select(database.notes).get()).single.title,
        'Untitled note',
      );
    });

    test('search matches title and content, newest first', () async {
      await notes.create(
        title: 'Grocery list',
        content: 'Milk and coffee beans',
        now: at,
      );
      await notes.create(
        title: 'Coffee brewing',
        content: 'Use 18g for a double shot',
        now: at.add(const Duration(minutes: 5)),
      );
      await notes.create(
        title: 'Reading',
        content: 'Finish chapter 4',
        now: at.add(const Duration(minutes: 10)),
      );

      final byTitle = await notes.notes(query: 'coffee');
      expect(byTitle.map((note) => note.title), [
        'Coffee brewing',
        'Grocery list',
      ]);

      final byContent = await notes.notes(query: 'CHAPTER');
      expect(byContent.single.title, 'Reading');

      expect(await notes.notes(query: 'nothing here'), isEmpty);
      expect(await notes.notes(), hasLength(3));
    });

    test('notes survive reopening the database file', () async {
      await database.close();
      final file = await createTempDatabaseFile('notes');
      final first = FlowStateDatabase.forTesting(NativeDatabase(file));
      await NotesRepository(first)
          .create(title: 'Persisted', content: 'Body', now: at);
      await first.close();

      final reopened = FlowStateDatabase.forTesting(NativeDatabase(file));
      addTearDown(() async {
        await reopened.close();
        if (file.existsSync()) file.deleteSync();
      });
      final saved = await reopened.select(reopened.notes).get();
      expect(saved.single.title, 'Persisted');
      expect(saved.single.content, 'Body');
    });
  });

  group('settings', () {
    test(
      'defaults are dark theme, Monday week start and a two-hour goal',
      () async {
        final defaults = await settings.load();
        expect(defaults.theme, AppTheme.dark);
        expect(defaults.weekStart, WeekStart.monday);
        expect(defaults.dailyFocusGoalMinutes, 120);
      },
    );

    test('writes persist and clamp out-of-range values', () async {
      await settings.setTheme(AppTheme.light);
      await settings.setWeekStart(WeekStart.sunday);
      await settings.setDailyFocusGoalMinutes(5);

      var saved = await settings.load();
      expect(saved.theme, AppTheme.light);
      expect(saved.weekStart, WeekStart.sunday);
      expect(
        saved.dailyFocusGoalMinutes,
        SettingsRepository.minFocusGoalMinutes,
      );

      await settings.setDailyFocusGoalMinutes(5000);
      saved = await settings.load();
      expect(
        saved.dailyFocusGoalMinutes,
        SettingsRepository.maxFocusGoalMinutes,
      );

      await settings.setDailyFocusGoalMinutes(90);
      expect((await settings.load()).dailyFocusGoalMinutes, 90);
    });

    test('watch emits updates and unknown stored values fall back', () async {
      await database
          .into(database.preferences)
          .insertOnConflictUpdate(
            PreferencesCompanion.insert(key: 'theme', value: 'sepia'),
          );
      await database
          .into(database.preferences)
          .insertOnConflictUpdate(
            PreferencesCompanion.insert(
              key: 'dailyFocusGoalMinutes',
              value: 'not-a-number',
            ),
          );

      final initial = await settings.load();
      expect(initial.theme, AppTheme.dark);
      expect(initial.dailyFocusGoalMinutes, 120);

      final updates = <AppSettings>[];
      final subscription = settings.watch().listen(updates.add);
      await pumpEventQueue();
      await settings.setTheme(AppTheme.system);
      await pumpEventQueue();
      await subscription.cancel();

      expect(updates.last.theme, AppTheme.system);
    });
  });
}
