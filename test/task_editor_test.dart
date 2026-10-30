import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flowstate/data/flowstate_database.dart';
import 'package:flowstate/main.dart';

/// Pumps frames until [finder] matches. `pumpAndSettle` is avoided because the
/// dashboard shows an indeterminate progress bar while data loads.
Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsWidgets, reason: 'Timed out waiting for $finder');
}

Future<void> pumpUntilGone(WidgetTester tester, Finder finder) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    if (finder.evaluate().isEmpty) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsNothing);
}

void main() {
  testWidgets('saving a task closes the editor and lists the task', (
    tester,
  ) async {
    final database = FlowStateDatabase.forTesting(NativeDatabase.memory());

    await tester.pumpWidget(FlowStateApp(database: database));
    await pumpUntil(tester, find.text('Today'));

    await tester.tap(find.text('Tasks').first);
    await pumpUntil(tester, find.text('Your task list is empty'));

    await tester.tap(find.text('Add task'));
    await pumpUntil(tester, find.text('New task'));
    await tester.enterText(find.byType(TextField).first, 'Draft the plan');
    await tester.tap(find.text('Save'));

    await pumpUntil(tester, find.text('TO DO · 1'));
    // The editor's controllers must outlive its closing animation.
    await pumpUntilGone(tester, find.text('New task'));
    expect(tester.takeException(), isNull);
    expect(find.text('Draft the plan'), findsOneWidget);
    expect(
      await database
          .select(database.tasks)
          .get()
          .then((rows) => rows.single.title),
      'Draft the plan',
    );

    // Dispose the tree so the workspace releases its database streams, and let
    // the closed dialog's cursor-blink timer finish before the test ends.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 600));
    await database.close();
  });
}
