import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/services/listening_statistics.dart';
import 'package:resonance/services/portable_file_export.dart';
import 'package:resonance/screens/library/library_browser_screen.dart';

class ListeningStatisticsScreen extends StatefulWidget {
  const ListeningStatisticsScreen({super.key, this.statistics, this.files});
  final ListeningStatistics? statistics;
  final FileService? files;
  @override
  State<ListeningStatisticsScreen> createState() => _ListeningStatisticsScreenState();
}

class _ListeningStatisticsScreenState extends State<ListeningStatisticsScreen> {
  late final stats = widget.statistics ?? ListeningStatistics.instance;
  final card = GlobalKey();
  String period = 'year';
  DateTime date = DateTime.now();
  Map<int, String> names = {};
  bool sharing = false;
  @override
  void initState() {
    super.initState();
    (widget.files ?? FileService()).getPlaylistNames().then((value) {
      if (mounted) setState(() => names = value);
    });
  }

  String? get prefix => period == 'all'
      ? null
      : period == 'year'
      ? '${date.year}'
      : '${date.year}-${date.month.toString().padLeft(2, '0')}';
  String get label => period == 'all'
      ? context.tr('All time')
      : period == 'year'
      ? '${date.year}'
      : MaterialLocalizations.of(context).formatMonthYear(date);
  String _time(num milliseconds) {
    final minutes = (milliseconds / 60000).round();
    return context.tr('{0} hr {1} min', [minutes ~/ 60, minutes % 60]);
  }

  Future<void> _share() async {
    setState(() => sharing = true);
    File? file;
    try {
      await WidgetsBinding.instance.endOfFrame;
      final image = await (card.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      file = File(p.join((await getTemporaryDirectory()).path, 'resonance-wrapped.png'));
      await file.writeAsBytes(data!.buffer.asUint8List());
      await savePortableFile(file.path, name: 'Resonance-Wrapped-${prefix ?? 'all-time'}.png', mime: 'image/png');
    } catch (error) {
      if (mounted) showLibraryError(context, error);
    } finally {
      if (file != null && await file.exists()) await file.delete();
      if (mounted) setState(() => sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: stats,
    builder: (context, _) {
      final tracks = stats.aggregate(prefix: prefix);
      final ranked = tracks.values.toList()..sort((a, b) => (b['ms'] as num).compareTo(a['ms'] as num));
      final artists = <String, num>{}, playlists = <String, num>{}, hours = <String, num>{};
      num total = 0, local = 0, streamed = 0, plays = 0;
      for (final track in ranked) {
        total += track['ms'] as num;
        local += track['localMs'] as num;
        streamed += track['streamMs'] as num;
        plays += track['plays'] as num;
        final artist = '${track['artist']}';
        artists[artist] = (artists[artist] ?? 0) + (track['ms'] as num);
        for (final entry in (track['playlists'] as Map? ?? {}).entries) {
          playlists['${entry.key}'] = (playlists['${entry.key}'] ?? 0) + (entry.value as num);
        }
        for (final entry in (track['hours'] as Map? ?? {}).entries) {
          hours['${entry.key}'] = (hours['${entry.key}'] ?? 0) + (entry.value as num);
        }
      }
      final days = <MapEntry<String, num>>[];
      for (final entry in stats.days.entries) {
        if (prefix != null && !entry.key.startsWith(prefix!)) continue;
        final value = (entry.value as Map).values.fold<num>(0, (sum, raw) => sum + ((raw as Map)['ms'] as num));
        if (value > 0) days.add(MapEntry(entry.key, value));
      }
      days.sort((a, b) => a.key.compareTo(b.key));
      var streak = 0, bestStreak = 0;
      DateTime? previous;
      for (final day in days) {
        final current = DateTime.parse(day.key);
        streak = previous != null && current.difference(previous).inDays == 1 ? streak + 1 : 1;
        if (streak > bestStreak) bestStreak = streak;
        previous = current;
      }
      final busiest = [...days]..sort((a, b) => b.value.compareTo(a.value));
      final hoursRanked = hours.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      Widget ranking(String title, Map<String, num> values, {String Function(String)? display}) {
        final sorted = values.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 22),
            Text(context.tr(title), style: Theme.of(context).textTheme.titleLarge),
            for (final entry in sorted.take(5))
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(display?.call(entry.key) ?? entry.key),
                trailing: Text(_time(entry.value)),
              ),
          ],
        );
      }

      return Scaffold(
        appBar: AppBar(
          title: Text(context.tr('Resonance Wrapped')),
          actions: [
            IconButton(
              onPressed: sharing || ranked.isEmpty ? null : _share,
              tooltip: context.tr('Save recap card'),
              icon: const Icon(Icons.ios_share),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(context.tr('Listening statistics')),
              subtitle: Text(
                context.tr('Stored only on this device. Tracking starts now; older listening cannot be reconstructed.'),
              ),
              value: stats.enabled,
              onChanged: stats.setEnabled,
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final entry in {'year': 'Year', 'month': 'Month', 'all': 'All time'}.entries)
                  ChoiceChip(
                    label: Text(context.tr(entry.value)),
                    selected: period == entry.key,
                    onSelected: (_) => setState(() => period = entry.key),
                  ),
              ],
            ),
            Row(
              children: [
                if (period != 'all')
                  IconButton(
                    tooltip: context.tr('Previous period'),
                    onPressed: () => setState(
                      () => date = period == 'year'
                          ? DateTime(date.year - 1, date.month)
                          : DateTime(date.year, date.month - 1),
                    ),
                    icon: const Icon(Icons.chevron_left),
                  ),
                Expanded(
                  child: Text(label, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
                ),
                if (period != 'all')
                  IconButton(
                    tooltip: context.tr('Next period'),
                    onPressed:
                        date.year >= DateTime.now().year && (period == 'year' || date.month >= DateTime.now().month)
                        ? null
                        : () => setState(
                            () => date = period == 'year'
                                ? DateTime(date.year + 1, date.month)
                                : DateTime(date.year, date.month + 1),
                          ),
                    icon: const Icon(Icons.chevron_right),
                  ),
              ],
            ),
            RepaintBoundary(
              key: card,
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(context.tr('Resonance Wrapped'), style: Theme.of(context).textTheme.headlineSmall),
                    Text(label),
                    const SizedBox(height: 20),
                    Text(_time(total), style: Theme.of(context).textTheme.headlineLarge),
                    const SizedBox(height: 8),
                    Text(
                      context.tr('{0} plays · {1} tracks · {2} artists', [
                        plays.toInt(),
                        ranked.length,
                        artists.length,
                      ]),
                    ),
                    if (ranked.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      if (ranked.first['artwork'] is String) ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: SizedBox(
                            width: 80,
                            height: 80,
                            child: '${ranked.first['artwork']}'.startsWith('file:')
                                ? Image.file(
                                    File.fromUri(Uri.parse('${ranked.first['artwork']}')),
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => const Icon(Icons.music_note),
                                  )
                                : Image.network(
                                    '${ranked.first['artwork']}',
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => const Icon(Icons.music_note),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      Text(context.tr('Your top song')),
                      Text('${ranked.first['title']}', style: Theme.of(context).textTheme.titleLarge),
                      Text('${ranked.first['artist']}'),
                    ],
                  ],
                ),
              ),
            ),
            if (ranked.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(context.tr('Play some music to start your recap.')),
              ),
            if (ranked.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text(context.tr('Local: {0} · Streamed: {1}', [_time(local), _time(streamed)])),
              Text(context.tr('{0} active days · {1}-day longest streak', [days.length, bestStreak])),
              if (busiest.isNotEmpty)
                Text(
                  context.tr('Busiest day: {0}', [
                    MaterialLocalizations.of(context).formatMediumDate(DateTime.parse(busiest.first.key)),
                  ]),
                ),
              if (hoursRanked.isNotEmpty)
                Text(context.tr('Favorite listening hour: {0}', ['${hoursRanked.first.key}:00'])),
              ranking('Top songs', {
                for (final entry in tracks.entries) entry.key: entry.value['ms'] as num,
              }, display: (id) => '${tracks[id]!['title']}'),
              ranking('Top artists', artists),
              ranking(
                'Top playlists',
                playlists,
                display: (number) => number == '0'
                    ? context.tr('Favorites')
                    : names[int.tryParse(number)] ?? context.tr('Playlist {0}', [number]),
              ),
            ],
            const SizedBox(height: 20),
            TextButton.icon(
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text(context.tr('Clear listening statistics?')),
                    content: Text(context.tr('This removes the recap history from this device.')),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.tr('Cancel'))),
                      FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(context.tr('Clear'))),
                    ],
                  ),
                );
                if (confirmed == true) await stats.clear();
              },
              icon: const Icon(Icons.delete_outline),
              label: Text(context.tr('Clear statistics')),
            ),
          ],
        ),
      );
    },
  );
}
