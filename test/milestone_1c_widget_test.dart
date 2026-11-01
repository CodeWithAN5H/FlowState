import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowstate/data/flowstate_database.dart';
import 'package:flowstate/data/tasks_repository.dart';
import 'package:flowstate/main.dart';

Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (DateTime.now().isBefore(deadline)) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsWidgets);
}

Future<void> pumpUntilGone(WidgetTester tester, Finder finder) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (DateTime.now().isBefore(deadline)) {
    if (finder.evaluate().isEmpty) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsNothing);
}

Future<void> settleAndClose(
  WidgetTester tester,
  FlowStateDatabase database,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 200));
  await database.close();
}

Finder dialogFields() => find.descendant(
  of: find.byType(AlertDialog),
  matching: find.byType(TextField),
);

/// These flows are desktop flows: a phone-sized viewport scrolls the buttons
/// out of view, so taps would land outside the visible area.
void useDesktopWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('a habit can be created, checked in and undone', (tester) async {
    final database = FlowStateDatabase.forTesting(NativeDatabase.memory());
    useDesktopWindow(tester);
    await tester.pumpWidget(FlowStateApp(database: database));
    await pumpUntil(tester, find.text('Today'));

    await tester.tap(find.text('Habits').first);
    await pumpUntil(tester, find.text('No habits yet'));

    await tester.tap(find.text('Create a habit'));
    // The page action is also labelled "New habit", so wait for the dialog.
    await pumpUntil(tester, find.byType(AlertDialog));
    await tester.enterText(dialogFields().first, 'Read 20 pages');
    await tester.tap(find.text('Save'));
    await pumpUntilGone(tester, find.byType(AlertDialog));

    await pumpUntil(tester, find.text('Read 20 pages'));
    expect(find.text('TODAY · 0 OF 1 DONE'), findsOneWidget);

    await tester.ensureVisible(find.byType(Checkbox).first);
    await tester.pump();
    await tester.tap(find.byType(Checkbox).first);
    await pumpUntil(tester, find.text('TODAY · 1 OF 1 DONE'));
    expect(
      await database.select(database.habitCompletions).get(),
      hasLength(1),
    );

    await tester.tap(find.byType(Checkbox).first);
    await pumpUntil(tester, find.text('TODAY · 0 OF 1 DONE'));
    expect(await database.select(database.habitCompletions).get(), isEmpty);

    await settleAndClose(tester, database);
  });

  testWidgets('notes save, search, and insights stay empty until real data', (
    tester,
  ) async {
    final database = FlowStateDatabase.forTesting(NativeDatabase.memory());
    useDesktopWindow(tester);
    await tester.pumpWidget(FlowStateApp(database: database));
    await pumpUntil(tester, find.text('Today'));

    await tester.tap(find.text('Notes').first);
    await pumpUntil(tester, find.text('No notes yet'));

    await tester.ensureVisible(find.text('Write a note'));
    await tester.pump();
    await tester.tap(find.text('Write a note'));
    // The page action is also labelled "New note", so wait for the dialog.
    await pumpUntil(tester, find.byType(AlertDialog));
    await tester.enterText(dialogFields().first, 'Weekly plan');
    await tester.enterText(dialogFields().last, 'Ship milestone 1C');
    await tester.tap(find.text('Save'));
    await pumpUntilGone(tester, find.byType(AlertDialog));

    await pumpUntil(tester, find.text('Weekly plan'));

    await tester.enterText(find.byType(TextField).first, 'nothing matches');
    await pumpUntil(tester, find.text('No matching notes'));
    await tester.tap(find.byTooltip('Clear search'));
    await pumpUntil(tester, find.text('Weekly plan'));

    await tester.tap(find.text('Insights').first);
    await pumpUntil(tester, find.text('Nothing measured yet'));

    // Real records make the empty state disappear.
    final tasks = TasksRepository(database);
    await tasks.create(title: 'Measured task');
    final task = (await database.select(database.tasks).get()).single;
    await tasks.setCompleted(task, true, now: DateTime.now());
    await pumpUntilGone(tester, find.text('Nothing measured yet'));
    await pumpUntil(
      tester,
      find.text('Measured on this device, from your own records.'),
    );

    await settleAndClose(tester, database);
  });

  testWidgets('settings reset needs the typed confirmation and clears data', (
    tester,
  ) async {
    final database = FlowStateDatabase.forTesting(NativeDatabase.memory());
    useDesktopWindow(tester);
    await TasksRepository(database).create(title: 'Will be deleted');

    await tester.pumpWidget(FlowStateApp(database: database));
    await pumpUntil(tester, find.text('Today'));

    await tester.tap(find.text('Settings').first);
    await pumpUntil(tester, find.text('Reset application data'));
    await tester.ensureVisible(find.text('Reset application data'));
    await tester.pump();
    await tester.tap(find.text('Reset application data'));
    await pumpUntil(tester, find.text('Delete all local data?'));

    final deleteButton = find.widgetWithText(FilledButton, 'Delete everything');
    expect(tester.widget<FilledButton>(deleteButton).onPressed, isNull);

    await tester.enterText(find.byType(TextField).first, 'RESET');
    await tester.pump();
    expect(tester.widget<FilledButton>(deleteButton).onPressed, isNotNull);

    await tester.tap(deleteButton);
    await pumpUntilGone(tester, find.text('Delete all local data?'));
    await pumpUntil(tester, find.textContaining('All local data was deleted'));
    expect(await database.select(database.tasks).get(), isEmpty);
    expect(await database.select(database.preferences).get(), isEmpty);

    await settleAndClose(tester, database);
  });
}
