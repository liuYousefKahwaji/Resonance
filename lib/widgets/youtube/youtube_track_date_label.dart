import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/models/youtube_track_date.dart';
import 'package:resonance/services/youtube/youtube_track_date_service.dart';

String formatYoutubeTrackDate(YoutubeTrackDate date, Locale locale, {DateTime? now}) {
  final strings = AppStrings(locale);
  final current = now ?? DateTime.now();
  final value = date.value;
  if (value == null) {
    if (date.year != null) return NumberFormat('0', locale.languageCode).format(date.year);
    final relative = date.relative;
    if (relative == null) return '';
    if (relative == 'today') return strings.text('Today');
    if (relative == 'yesterday') return strings.text('Yesterday');
    final match = RegExp(r'^(a|an|\d+) (second|minute|hour|day|week|month|year)s? ago$').firstMatch(relative);
    if (match == null) return '';
    final number = int.tryParse(match[1]!) ?? 1;
    return strings.text(number == 1 ? '1 ${match[2]} ago' : '{0} ${match[2]}s ago', [
      NumberFormat('0', locale.languageCode).format(number),
    ]);
  }
  // Date-only metadata has no trustworthy hour. Preserve its calendar day.
  final local = date.hasTime ? value.toLocal() : value;
  final elapsed = current.difference(local);
  final day = DateTime.utc(
    current.year,
    current.month,
    current.day,
  ).difference(DateTime.utc(local.year, local.month, local.day)).inDays;
  if (date.hasTime && !elapsed.isNegative && elapsed.inHours < 24 && day == 0) {
    if (elapsed.inMinutes < 1) return strings.text('Just now');
    final hours = elapsed.inHours;
    final count = hours > 0 ? hours : elapsed.inMinutes;
    final unit = hours > 0 ? 'hour' : 'minute';
    return strings.text(count == 1 ? '1 $unit ago' : '{0} ${unit}s ago', [
      NumberFormat('0', locale.languageCode).format(count),
    ]);
  }
  if (day == 0) return strings.text('Today');
  if (day == 1) return strings.text('Yesterday');
  if (day >= 2 && day < 7) return strings.text('{0} days ago', [NumberFormat('0', locale.languageCode).format(day)]);
  if (day >= 7 && day < 14) return strings.text('Last week');
  return DateFormat.yMMMd(locale.languageCode).format(local);
}

class YoutubeTrackDateLabel extends StatefulWidget {
  const YoutubeTrackDateLabel({super.key, required this.track, this.fetch = true, this.loader, this.separator = false});
  final YoutubeTrack track;
  final bool fetch;
  final bool separator;
  final Future<YoutubeTrackDate?> Function(YoutubeTrack)? loader;
  @override
  State<YoutubeTrackDateLabel> createState() => _YoutubeTrackDateLabelState();
}

class _YoutubeTrackDateLabelState extends State<YoutubeTrackDateLabel> {
  YoutubeTrackDate? _date;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(YoutubeTrackDateLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track.url != widget.track.url ||
        oldWidget.track.date != widget.track.date ||
        oldWidget.fetch != widget.fetch) {
      _load();
    }
  }

  void _load() {
    final generation = ++_generation;
    _date = widget.track.date;
    if (!widget.fetch || _date?.value != null) return;
    // List builders include a small viewport cache; never fetch the entire list.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation) return;
      unawaited(_hydrate(generation));
    });
  }

  Future<void> _hydrate(int generation) async {
    try {
      final date = widget.loader != null
          ? await widget.loader!(widget.track)
          : await const YoutubeTrackDateService().fetch(
              widget.track,
              isActive: () => mounted && generation == _generation,
            );
      if (mounted && generation == _generation && date != null) setState(() => _date = date);
    } catch (_) {
      /* Optional date metadata cannot affect browsing. */
    }
  }

  @override
  Widget build(BuildContext context) {
    final date = _date;
    if (date == null) return const SizedBox.shrink();
    final locale = Localizations.localeOf(context);
    final text = formatYoutubeTrackDate(date, locale);
    final exact = date.value == null
        ? text
        : DateFormat.yMMMMd(locale.languageCode).format(date.hasTime ? date.value!.toLocal() : date.value!);
    return Tooltip(
      message: context.tr(date.isRelease ? 'Released {0}' : 'Uploaded {0}', [exact]),
      child: Text(
        widget.separator ? '· $text' : text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}
