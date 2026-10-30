import 'package:flutter/material.dart';

import 'data/flowstate_database.dart';
import 'workspace_screen.dart';

void main() {
  runApp(const FlowStateApp());
}

const _background = Color(0xFF101014);
const _surface = Color(0xFF19191F);
const _violet = Color(0xFFA78BFA);

class FlowStateApp extends StatelessWidget {
  const FlowStateApp({super.key, this.database});

  final FlowStateDatabase? database;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FlowState',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _background,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _violet,
          brightness: Brightness.dark,
          surface: _surface,
        ),
        fontFamily: 'Segoe UI',
      ),
      home: WorkspaceScreen(database: database),
    );
  }
}
