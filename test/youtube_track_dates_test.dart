import 'dart:async';
import 'package:intl/date_symbol_data_local.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/models/youtube_track_date.dart';
import 'package:resonance/services/youtube/youtube_track_date_service.dart';
import 'package:resonance/widgets/youtube/youtube_track_date_label.dart';

void main() {
  setUpAll(() => initializeDateFormatting());
  test('dates preserve precision, source and cache serialization', () {
    final track = YoutubeTrack.fromJson({
      'title': 'A',
      'artist': 'B',
      'url': 'https://youtu.be/abcdefghijk',
      'release_date': '20230218',
      'upload_date': '20240101',
    });
    expect(track.date!.value, DateTime.utc(2023, 2, 18));
    expect(track.date!.hasTime, isFalse);
    expect(track.date!.isRelease, isTrue);
    final restored = YoutubeTrack.fromCacheJson(track.copyWith(likeCount: 42).toJson());
    expect(restored.date!.value, track.date!.value);
    expect(restored.date!.hasTime, isFalse);
    expect(restored.date!.isRelease, isTrue);
    expect(YoutubeTrackDate.parse('2023')!.value, isNull);
    expect(YoutubeTrackDate.parse('20230230'), isNull);
    expect(YoutubeTrackDate.parse('unknown'), isNull);
  });
  test('full dates and recent labels respect real precision', () {
    final now = DateTime(2026, 10, 21, 12);
    String label(String raw) => formatYoutubeTrackDate(YoutubeTrackDate.parse(raw)!, const Locale('en'), now: now);
    expect(label('20231001'), 'Oct 1, 2023');
    expect(label('20261021'), 'Today');
    expect(label('20261020'), 'Yesterday');
    expect(label('20261018'), '3 days ago');
    expect(label('20261012'), 'Last week');
    expect(label('2026-10-21T11:00:00'), '1 hour ago');
    expect(label('2026-10-21T11:58:00'), '2 minutes ago');
    expect(label('2023'), '2023');
    expect(label('Streamed 2 hours ago'), '2 hours ago');
    expect(formatYoutubeTrackDate(YoutubeTrackDate.parse('yesterday')!, const Locale('ar'), now: now), 'أمس');
  });
  test('watch metadata uses full dates without mistaking relative labels for days', () {
    final date = YoutubeTrackDateService.parseHtml(
      'var ytInitialPlayerResponse = {"microformat":{"playerMicroformatRenderer":{"publishDate":"2023-01-06","uploadDate":"2022-12-30"}}};',
    );
    expect(date!.value, DateTime.utc(2023, 1, 6));
    expect(date.isRelease, isFalse);
    expect(
      YoutubeTrackDateService.parseHtml('<meta itemprop="datePublished" content="2024-02-17">')!.value,
      DateTime.utc(2024, 2, 17),
    );
    expect(YoutubeTrackDateService.parseHtml('<html>Sign in</html>'), isNull);
  });
  test('enrichment bounds concurrency and drops work for disposed rows', () async {
    final pending = <Completer<String>>[];
    final service = YoutubeTrackDateService(
      loader: (uri) {
        final c = Completer<String>();
        pending.add(c);
        return c.future;
      },
    );
    var thirdActive = true;
    YoutubeTrack track(int i) => YoutubeTrack(title: 'A', artist: 'B', url: 'https://youtu.be/date000000$i');
    final first = service.fetch(track(1));
    final second = service.fetch(track(2));
    final third = service.fetch(track(3), isActive: () => thirdActive);
    expect(pending.length, 2);
    thirdActive = false;
    pending.first.complete('<meta itemprop="datePublished" content="2024-02-17">');
    await first;
    expect(await third, isNull);
    expect(pending.length, 2);
    pending[1].complete('unavailable');
    await second;
    expect((await service.fetch(track(1)))!.value, DateTime.utc(2024, 2, 17));
    expect(pending.length, 2);
  });
  testWidgets('late date cannot replace a newer row and Arabic layout fits', (tester) async {
    final pending = Completer<YoutubeTrackDate?>();
    Widget app(YoutubeTrack track) => MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: AppStrings.supportedLocales,
      localizationsDelegates: const [
        AppStrings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: YoutubeTrackDateLabel(track: track, loader: (_) => pending.future),
      ),
    );
    await tester.pumpWidget(app(const YoutubeTrack(title: 'Old', artist: 'A', url: 'https://youtu.be/old00000000')));
    await tester.pump();
    await tester.pumpWidget(
      app(
        YoutubeTrack(
          title: 'New',
          artist: 'A',
          url: 'https://youtu.be/new00000000',
          date: YoutubeTrackDate.parse('20240102'),
        ),
      ),
    );
    pending.complete(YoutubeTrackDate.parse('20000101'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2024'), findsOneWidget);
    expect(find.textContaining('2000'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
