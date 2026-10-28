import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import 'focus_timer.dart';

void main() {
  runApp(const FlowStateApp());
}

const _background = Color(0xFF101014);
const _surface = Color(0xFF19191F);
const _surfaceRaised = Color(0xFF202027);
const _violet = Color(0xFFA78BFA);
const _muted = Color(0xFF9996A5);

class FlowStateApp extends StatelessWidget {
  const FlowStateApp({super.key});

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
      home: const FocusScreen(),
    );
  }
}

class FocusScreen extends StatefulWidget {
  const FocusScreen({super.key});

  @override
  State<FocusScreen> createState() => _FocusScreenState();
}

class _FocusScreenState extends State<FocusScreen> with WidgetsBindingObserver {
  final FocusTimer _timer = FocusTimer();
  Timer? _ticker;
  String? _lastSessionLabel;

  Duration get _elapsed => _timer.elapsed;
  bool get _hasStarted => _timer.hasStarted;
  bool get _isRunning => _timer.isRunning;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isRunning) {
      setState(() {});
    }
  }

  void _startOrResume() {
    if (_isRunning) return;
    setState(() {
      _timer.startOrResume();
      _ticker ??= Timer.periodic(
        const Duration(seconds: 1),
        (_) {
          if (mounted && _isRunning) setState(() {});
        },
      );
    });
  }

  void _pause() {
    if (!_isRunning) return;
    _ticker?.cancel();
    _ticker = null;
    setState(_timer.pause);
  }

  void _finish() {
    if (!_hasStarted) return;
    final duration = _timer.finish()!;
    _ticker?.cancel();
    _ticker = null;
    setState(() {
      _lastSessionLabel = 'Completed · ${_formatDuration(duration)}';
    });
  }

  void _cancel() {
    if (!_hasStarted) return;
    final duration = _timer.cancel()!;
    _ticker?.cancel();
    _ticker = null;
    setState(() {
      _lastSessionLabel = 'Interrupted · ${_formatDuration(duration)}';
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 680;
    final content = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980),
        child: Padding(
          padding: EdgeInsets.all(compact ? 22 : 42),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _TopBar(compact: compact),
              SizedBox(height: compact ? 38 : 58),
              Text('YOUR SPACE TO FOCUS', style: _eyebrowStyle),
              const SizedBox(height: 10),
              Text(
                'Make room for\nwhat matters.',
                style: TextStyle(
                  fontSize: compact ? 37 : 52,
                  height: 1.08,
                  letterSpacing: -2.1,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'One thing at a time. Your time stays yours.',
                style: TextStyle(fontSize: 15, color: _muted),
              ),
              const SizedBox(height: 5),
              const Text(
                'This first build includes a working stopwatch. Other sections are planned.',
                style: TextStyle(fontSize: 11, color: _muted),
              ),
              SizedBox(height: compact ? 30 : 38),
              if (compact)
                _FocusCard(
                  elapsed: _elapsed,
                  hasStarted: _hasStarted,
                  isRunning: _isRunning,
                  onStart: _startOrResume,
                  onPause: _pause,
                  onFinish: _finish,
                  onCancel: _cancel,
                )
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 7,
                      child: _FocusCard(
                        elapsed: _elapsed,
                        hasStarted: _hasStarted,
                        isRunning: _isRunning,
                        onStart: _startOrResume,
                        onPause: _pause,
                        onFinish: _finish,
                        onCancel: _cancel,
                      ),
                    ),
                    const SizedBox(width: 20),
                    const Expanded(flex: 4, child: _TodayCard()),
                  ],
                ),
              if (compact) ...[
                const SizedBox(height: 16),
                const _TodayCard(),
              ],
              if (_lastSessionLabel != null) ...[
                const SizedBox(height: 18),
                _SessionNotice(label: _lastSessionLabel!),
              ],
              if (compact) const SizedBox(height: 24) else const Spacer(),
              const Row(
                children: [
                  Icon(Icons.cloud_off_outlined, size: 16, color: _muted),
                  SizedBox(width: 8),
                  Text(
                    'Timer runs offline · Session history is not saved yet',
                    style: TextStyle(color: _muted, fontSize: 12),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    return Scaffold(
      body: SafeArea(
        child: compact
            ? SingleChildScrollView(child: content)
            : Row(
                children: [
                  const _Sidebar(),
                  Expanded(child: content),
                ],
              ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.compact});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (compact) ...[
          const Icon(Icons.bubble_chart_rounded, color: _violet, size: 25),
          const SizedBox(width: 9),
          const Text('FlowState', style: TextStyle(fontWeight: FontWeight.w700)),
          const Spacer(),
        ] else ...[
          const Icon(Icons.wb_sunny_outlined, size: 17, color: _violet),
          const SizedBox(width: 9),
          const Text('A little progress is still progress',
              style: TextStyle(color: _muted, fontSize: 13)),
          const Spacer(),
        ],
        const CircleAvatar(
          radius: 17,
          backgroundColor: _surfaceRaised,
          child: Icon(Icons.person_outline_rounded, size: 18, color: _muted),
        ),
      ],
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 224,
      decoration: const BoxDecoration(
        color: Color(0xFF141418),
        border: Border(right: BorderSide(color: Color(0xFF25242C))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 27),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(children: [
            Icon(Icons.bubble_chart_rounded, color: _violet, size: 26),
            SizedBox(width: 10),
            Text('FlowState',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 48),
          const _NavItem(
              icon: Icons.hourglass_bottom_rounded,
              label: 'Focus',
              selected: true),
          const SizedBox(height: 18),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 11),
            child: Text(
              'This milestone is focused on a reliable timer. Tasks, notes, habits, insights, and settings are planned next.',
              style: TextStyle(color: _muted, fontSize: 11, height: 1.5),
            ),
          ),
          const Spacer(),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 11),
            child: Text('MILESTONE 1 · IN PROGRESS',
                style: _eyebrowStyle),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.icon, required this.label, this.selected = false});
  final IconData icon;
  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 5),
      decoration: BoxDecoration(
        color: selected ? const Color(0xFF292335) : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
      ),
      child: ListTile(
        dense: true,
        leading: Icon(icon, size: 19, color: selected ? _violet : _muted),
        title: Text(label,
            style: TextStyle(
              fontSize: 13,
              color: selected ? Colors.white : _muted,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            )),
        onTap: () {},
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 11),
        minLeadingWidth: 22,
      ),
    );
  }
}

class _FocusCard extends StatelessWidget {
  const _FocusCard({
    required this.elapsed,
    required this.hasStarted,
    required this.isRunning,
    required this.onStart,
    required this.onPause,
    required this.onFinish,
    required this.onCancel,
  });

  final Duration elapsed;
  final bool hasStarted;
  final bool isRunning;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onFinish;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF2B2933)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.bolt_rounded, size: 17, color: _violet),
            const SizedBox(width: 8),
            Text(isRunning ? 'FOCUS IN PROGRESS' : 'FOCUS STOPWATCH',
                style: _eyebrowStyle),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFF25242D),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(isRunning ? 'Active' : 'Local timer',
                  style: const TextStyle(color: _muted, fontSize: 11)),
            ),
          ]),
          const SizedBox(height: 34),
          Center(
            child: Text(
              _formatDuration(elapsed),
              semanticsLabel: 'Elapsed ${_formatDuration(elapsed)}',
              style: const TextStyle(
                fontFeatures: [FontFeature.tabularFigures()],
                fontSize: 56,
                letterSpacing: -2,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Center(
            child: Text(
              isRunning ? 'Every minute counts.' : 'Start when you’re ready.',
              style: const TextStyle(color: _muted, fontSize: 13),
            ),
          ),
          const SizedBox(height: 30),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: isRunning ? onPause : onStart,
                  icon: Icon(isRunning ? Icons.pause_rounded : Icons.play_arrow_rounded),
                  label: Text(isRunning ? 'Pause' : hasStarted ? 'Resume' : 'Start focus'),
                  style: FilledButton.styleFrom(
                    backgroundColor: _violet,
                    foregroundColor: const Color(0xFF17131F),
                    minimumSize: const Size(0, 48),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(11)),
                    textStyle: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              if (hasStarted) ...[
                const SizedBox(width: 10),
                IconButton.filledTonal(
                  tooltip: 'Finish session',
                  onPressed: onFinish,
                  icon: const Icon(Icons.check_rounded),
                  style: IconButton.styleFrom(
                      backgroundColor: _surfaceRaised,
                      minimumSize: const Size(48, 48)),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: 'Cancel session',
                  onPressed: onCancel,
                  icon: const Icon(Icons.close_rounded, color: _muted),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _TodayCard extends StatelessWidget {
  const _TodayCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF2B2933)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('TODAY', style: _eyebrowStyle),
          const SizedBox(height: 20),
          const Row(children: [
            _StatIcon(icon: Icons.schedule_rounded),
            SizedBox(width: 13),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Focus time', style: TextStyle(color: _muted, fontSize: 12)),
              SizedBox(height: 3),
              Text('No sessions yet', style: TextStyle(fontSize: 14)),
            ]),
          ]),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 15),
            child: Divider(height: 1, color: Color(0xFF302E37)),
          ),
          const Row(children: [
            _StatIcon(icon: Icons.checklist_rounded),
            SizedBox(width: 13),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Tasks completed',
                  style: TextStyle(color: _muted, fontSize: 12)),
              SizedBox(height: 3),
              Text('Ready when you are', style: TextStyle(fontSize: 14)),
            ]),
          ]),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: _surfaceRaised,
              borderRadius: BorderRadius.circular(11),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_outline_rounded, size: 17, color: _violet),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Focus Lock isn’t enabled. Your timer works independently.',
                    style: TextStyle(color: _muted, fontSize: 11, height: 1.45),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatIcon extends StatelessWidget {
  const _StatIcon({required this.icon});
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: const Color(0xFF292335),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 18, color: _violet),
      );
}

class _SessionNotice extends StatelessWidget {
  const _SessionNotice({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: const Color(0xFF2B2933)),
        ),
        child: Row(children: [
          const Icon(Icons.history_rounded, size: 18, color: _violet),
          const SizedBox(width: 10),
          Text('Last session: $label',
              style: const TextStyle(fontSize: 12, color: _muted)),
        ]),
      );
}

const _eyebrowStyle = TextStyle(
  color: _muted,
  fontSize: 10,
  letterSpacing: 1.15,
  fontWeight: FontWeight.w700,
);

String _formatDuration(Duration duration) {
  final hours = duration.inHours.toString().padLeft(2, '0');
  final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return '$hours:$minutes:$seconds';
}
