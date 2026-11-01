import 'package:flutter/material.dart';

import 'data/flowstate_database.dart';
import 'ui.dart';
import 'workspace_screen.dart';

void main() {
  runApp(const FlowStateApp());
}

class FlowStateApp extends StatefulWidget {
  const FlowStateApp({super.key, this.database});

  /// Injected by tests; the app opens its own file database otherwise.
  final FlowStateDatabase? database;

  @override
  State<FlowStateApp> createState() => _FlowStateAppState();
}

class _FlowStateAppState extends State<FlowStateApp> {
  FlowStateDatabase? _database;
  bool _ownsDatabase = false;

  @override
  void initState() {
    super.initState();
    _database = widget.database;
    if (_database == null) {
      _database = FlowStateDatabase();
      _ownsDatabase = true;
    }
  }

  @override
  void dispose() {
    if (_ownsDatabase) _database?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'FlowState',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: kBackground,
      colorScheme: ColorScheme.fromSeed(
        seedColor: kViolet,
        brightness: Brightness.dark,
        surface: kSurface,
      ),
      fontFamily: 'Segoe UI',
    ),
    home: WorkspaceScreen(database: _database!),
  );
}
