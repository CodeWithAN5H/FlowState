import 'package:flutter/material.dart';

const kBackground = Color(0xFF101014);
const kSidebar = Color(0xFF141418);
const kSurface = Color(0xFF19191F);
const kViolet = Color(0xFFA78BFA);
const kMuted = Color(0xFF9996A5);
const kBorder = Color(0xFF2B2933);
const kSelected = Color(0xFF292335);
const kDivider = Color(0xFF302E37);

const kEyebrow = TextStyle(
  color: kMuted,
  fontSize: 10,
  letterSpacing: 1.15,
  fontWeight: FontWeight.w700,
);

const kPageTitle = TextStyle(
  fontSize: 30,
  fontWeight: FontWeight.w600,
  letterSpacing: -0.8,
);

/// Standard page scaffold used by every workspace section.
class PageFrame extends StatelessWidget {
  const PageFrame({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
    this.action,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 760;
    return SingleChildScrollView(
      padding: EdgeInsets.all(compact ? 20 : 42),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: kPageTitle),
                        const SizedBox(height: 5),
                        Text(
                          subtitle,
                          style: const TextStyle(color: kMuted, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  if (action != null) action!,
                ],
              ),
              const SizedBox(height: 28),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) => Container(
    child: SizedBox(
      width: double.infinity,
      // Material (not a plain decorated box) so ListTile ink and splash paint
      // on the surface they belong to instead of being hidden by it.
      child: Material(
        color: kSurface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: kBorder),
        ),
        child: padding == null
            ? child
            : Padding(padding: padding!, child: child),
      ),
    ),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Panel(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 34),
      child: Center(
        child: Column(
          children: [
            Icon(icon, size: 34, color: kViolet),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: kMuted, fontSize: 12, height: 1.5),
            ),
            if (action != null) ...[const SizedBox(height: 18), action!],
          ],
        ),
      ),
    ),
  );
}

String durationLabel(Duration value) {
  final hours = value.inHours.toString().padLeft(2, '0');
  final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
  return '$hours:$minutes:$seconds';
}

String shortDurationLabel(Duration value) {
  if (value == Duration.zero) return '0m';
  if (value.inMinutes < 1) return '${value.inSeconds}s';
  final hours = value.inHours;
  final minutes = value.inMinutes % 60;
  if (hours == 0) return '${minutes}m';
  return minutes == 0 ? '${hours}h' : '${hours}h ${minutes}m';
}

String dateLabel(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

String shortDateLabel(DateTime date) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${date.day} ${months[date.month - 1]}';
}

String weekdayLabel(DateTime date) =>
    const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][date.weekday - 1];
