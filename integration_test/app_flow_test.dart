import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flowstate/data/flowstate_database.dart';
import 'package:flowstate/main.dart';

/// Pumps frames until [finder] matches, because the app uses a periodic ticker
/// while a focus session runs, so `pumpAndSettle` would never settle.
Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsWidgets, reason: 'Timed out waiting for $finder');
}

/// Pumps frames until [finder] matches nothing, e.g. a closing dialog.
Future<void> pumpUntilGone(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (finder.evaluate().isEmpty) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsNothing, reason: 'Timed out waiting for $finder to go');
}

/// Reads the value shown under a dashboard stat label.
String? statValue(WidgetTester tester, String label) {
  final column = find
      .ancestor(of: find.text(label), matching: find.byType(Column))
      .first;
  final texts = tester
      .widgetList<Text>(
        find.descendant(of: column, matching: find.byType(Text)),
      )
      .map((text) => text.data)
      .toList();
  return texts.length > 1 ? texts[1] : null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late File databaseFile;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('flowstate_it_');
    databaseFile = File('${tempDir.path}/flowstate.sqlite');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('tasks and focus sessions work and survive a restart', (
    tester,
  ) async {
    var database = FlowStateDatabase.forTesting(NativeDatabase(databaseFile));
    addTearDown(() async {
      await database.close();
    });
    await tester.pumpWidget(FlowStateApp(database: database));
    await pumpUntil(tester, find.text('Today'));
    await pumpUntil(
      tester,
      find.text('Nothing on your list yet. Add a task when you’re ready.'),
    );
    expect(
      statValue(tester, 'Tasks completed'),
      '0',
      reason: 'a fresh workspace must not show invented statistics',
    );
    expect(statValue(tester, 'Completed sessions'), '0');

    // Create a task through the Tasks page.
    await tester.tap(find.text('Tasks').first);
    await pumpUntil(tester, find.text('Your task list is empty'));
    await tester.tap(find.text('Add task'));
    await pumpUntil(tester, find.text('New task'));
    await tester.enterText(
      find.byType(TextField).first,
      'Write milestone notes',
    );
    await tester.tap(find.text('Save'));
    // Wait for the dialog to close and the list to rebuild from the database.
    await pumpUntil(tester, find.text('TO DO · 1'));
    await pumpUntilGone(tester, find.text('New task'));
    expect(find.text('Write milestone notes'), findsOneWidget);

    // Complete it and confirm it moves to the completed group.
    await tester.tap(find.byType(Checkbox).first);
    await pumpUntil(tester, find.text('COMPLETED · 1'));

    // Run a focus session: start, pause, resume, finish.
    await tester.tap(find.text('Focus').first);
    await pumpUntil(tester, find.text('Start focus'));
    await tester.tap(find.text('Start focus'));
    await pumpUntil(tester, find.text('Pause'));
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.text('Pause'));
    await pumpUntil(tester, find.text('Resume'));
    await tester.tap(find.text('Resume'));
    await pumpUntil(tester, find.text('Pause'));
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.tap(find.byTooltip('Finish session'));
    final lastSession = find.textContaining('Last session: Completed ·');
    await pumpUntil(tester, lastSession);
    expect(
      tester.widget<Text>(lastSession).data!.contains('00:00:00'),
      isFalse,
      reason: 'the finished session must record real elapsed time',
    );

    // Home reflects the saved records.
    await tester.tap(find.text('Home').first);
    await pumpUntil(tester, find.text('Tasks completed'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(statValue(tester, 'Tasks completed'), '1');
    expect(statValue(tester, 'Completed sessions'), '1');
    expect(statValue(tester, 'Focus time'), isNot('00:00:00'));
    expect(
      find.text('You’re all caught up for today.'),
      findsOneWidget,
      reason: 'the completed task must no longer be due',
    );

    // Restart against the same database file and confirm nothing was lost.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
    await database.close();
    expect(databaseFile.existsSync(), isTrue);

    database = FlowStateDatabase.forTesting(NativeDatabase(databaseFile));
    await tester.pumpWidget(FlowStateApp(database: database));
    await pumpUntil(tester, find.text('Today'));
    await pumpUntil(tester, find.text('You’re all caught up for today.'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(statValue(tester, 'Tasks completed'), '1');
    expect(statValue(tester, 'Completed sessions'), '1');

    await tester.tap(find.text('Tasks').first);
    await pumpUntil(tester, find.text('COMPLETED · 1'));
    expect(find.text('Write milestone notes'), findsOneWidget);
  });
}
