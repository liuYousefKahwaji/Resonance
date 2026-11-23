import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/models/lyrics.dart';
import 'package:resonance/services/lyrics_service.dart';
import 'package:resonance/widgets/player/lyrics_picker.dart';

const record = {
  'id': 42,
  'trackName': 'Song',
  'artistName': 'Artist',
  'duration': 180,
  'instrumental': false,
  'plainLyrics': 'Test line',
  'syncedLyrics': '[00:01.00]Test line',
};

class _RealHttp extends HttpOverrides {}

class _Client extends Fake implements HttpClient {
  _Client(this.port) : inner = HttpOverrides.runWithHttpOverrides(() => HttpClient(), _RealHttp());
  final int port;
  final HttpClient inner;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) => inner.getUrl(uri.replace(scheme: 'http', host: '127.0.0.1', port: port));
  @override
  void close({bool force = false}) => inner.close(force: force);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(LyricsService.resetLrclibBackoff);
  tearDown(LyricsService.resetLrclibBackoff);
  test('YouTube decorations and duplicated artist do not poison the LRCLIB query', () {
    expect(
      LyricsService.searchQueryForTrack('In The End [Official HD Music Video] - Linkin Park', 'Linkin Park'),
      'Linkin Park In The End',
    );
    expect(
      LyricsService.searchQueryForTrack('Linkin Park - In The End (Official Video)', 'Linkin Park - Topic'),
      'Linkin Park In The End',
    );
    expect(
      LyricsService.searchQueryForTrack('Breaking Benjamin - Blow Me Away', 'Vayeate'),
      'Breaking Benjamin Blow Me Away',
    );
    expect(LyricsService.searchQueryForTrack('Song (Slowed)', 'Artist'), 'Artist Song (Slowed)');
  });
  test('busy LRCLIB response retries once and returns real candidate shape', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var attempts = 0;
    server.listen((request) async {
      attempts++;
      expect(request.headers.value(HttpHeaders.acceptHeader), 'application/json');
      request.response.headers.contentType = ContentType.json;
      if (attempts == 1) {
        request.response.statusCode = 503;
        request.response.write('{"message":"busy"}');
      } else {
        request.response.write(jsonEncode([record]));
      }
      await request.response.close();
    });
    final service = LyricsService(lrclibClientFactory: () => _Client(server.port));
    final results = await service.searchLrclibCandidates('Artist Song');
    expect(attempts, 2);
    expect(results.single.id, 42);
    expect(results.single.hasLyrics, isTrue);
  });
  test('search labels actual word timings and ignores contradictory LRCLIB flags', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      expect(request.uri.path, '/api/search');
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode([
          {...record, 'hasWordSync': true},
          {
            ...record,
            'id': 43,
            'hasWordSync': true,
            'lyricsfile': '''
lines:
  - text: Test line
    start_ms: 1000
    end_ms: 2000
    words:
      - {text: "Test ", start_ms: 1000}
      - {text: line, start_ms: 1500}
''',
          },
        ]),
      );
      await request.response.close();
    });
    final service = LyricsService(lrclibClientFactory: () => _Client(server.port));
    final candidates = await service.searchLrclibCandidates('Artist Song');
    expect(candidates[0].timingQuality, LyricTimingQuality.line);
    expect(candidates[0].hasWordSync, isFalse);
    expect(candidates[1].timingQuality, LyricTimingQuality.word);
    expect(candidates[1].document!.lines.single.words.map((word) => word.end.inMilliseconds), [1500, 2000]);
  });

  testWidgets('source, duration, and timing filters work together without another request', (tester) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var requests = 0;
    LrclibCandidate result(int id, String title, int seconds, LyricTimingQuality timing, String source) =>
        LrclibCandidate(
          id: id,
          trackName: title,
          artistName: 'Artist',
          albumName: '',
          duration: Duration(seconds: seconds),
          instrumental: false,
          hasSyncedLyrics: true,
          hasPlainLyrics: false,
          document: LyricsDocument(lines: const [], timingQuality: timing, source: source),
        );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LyricsPicker(
            initialQuery: 'Test',
            targetDuration: const Duration(seconds: 180),
            search: (_) async {
              requests++;
              return [
                result(1, 'Close word result', 182, LyricTimingQuality.word, 'LRCLIB'),
                result(2, 'Long word result', 205, LyricTimingQuality.word, 'LRCLIB'),
                result(3, 'Close line result', 180, LyricTimingQuality.line, 'LRCLIB'),
                result(4, 'Another source', 180, LyricTimingQuality.word, 'QQ Music'),
              ];
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> choose(String label, String option) async {
      await tester.tap(find.byTooltip(label));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, option));
      await tester.pumpAndSettle();
    }

    await choose('Filter by lyrics source', 'LRCLIB');
    await choose('Filter by duration difference', 'Within 3s');
    await choose('Filter by timing', 'Word-synced');
    expect(find.text('Close word result'), findsOneWidget);
    expect(find.text('Long word result'), findsNothing);
    expect(find.text('Close line result'), findsNothing);
    expect(find.text('Another source'), findsNothing);
    expect(requests, 1);
  });
  test('a stalled response does not hold later searches in the global request queue', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final started = Completer<void>();
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.uri.queryParameters['q'] == 'slow') {
        request.response.write('[');
        await request.response.flush();
        started.complete();
      } else {
        request.response.write(jsonEncode([record]));
        await request.response.close();
      }
    });
    final service = LyricsService(
      lrclibClientFactory: () => _Client(server.port),
      lrclibTimeout: const Duration(seconds: 2),
    );
    var slowDone = false;
    final slow = service.searchLrclibCandidates('slow').whenComplete(() => slowDone = true);
    final failure = expectLater(slow, throwsA(isA<LyricsLookupException>()));
    await started.future;
    expect((await service.searchLrclibCandidates('fast')).single.id, 42);
    expect(slowDone, isFalse, reason: 'Only start times are rate limited; response bodies are independent.');
    await failure;
  });
  for (final dateHint in [false, true]) {
    test('long Retry-After is honored across lookups without a long spinner date=$dateHint', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var attempts = 0;
      server.listen((request) async {
        attempts++;
        request.response.statusCode = 502;
        request.response.headers.set(
          HttpHeaders.retryAfterHeader,
          dateHint ? HttpDate.format(DateTime.now().add(const Duration(seconds: 60))) : '60',
        );
        request.response.write('Bad gateway');
        await request.response.close();
      });
      final service = LyricsService(lrclibClientFactory: () => _Client(server.port));
      final started = DateTime.now();
      Future<void> lookup() async {
        await expectLater(
          service.searchLrclibCandidates('Blow Me Away'),
          throwsA(
            isA<LyricsLookupException>().having(
              (e) => e.retryAt!.difference(started).inSeconds,
              'server delay',
              greaterThanOrEqualTo(58),
            ),
          ),
        );
      }

      await lookup();
      await lookup();
      expect(attempts, 1, reason: 'Do not retry before the server permits it, including another manual search.');
      expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 4)));
    });
  }
  testWidgets('picker displays connection errors distinctly and Retry can recover', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 600,
            child: LyricsPicker(
              initialQuery: 'Artist Song',
              targetDuration: const Duration(minutes: 3),
              search: (query) async {
                if (++calls == 1) throw const LyricsLookupException('LRCLIB is busy. Try again in a moment.');
                return const [];
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('LRCLIB is busy. Try again in a moment.'), findsOneWidget);
    expect(find.text('No lyrics found for this search.'), findsNothing);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('No lyrics found for this search.'), findsOneWidget);
  });
  testWidgets('picker shows server cooldown and disables Retry until permitted', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LyricsPicker(
            initialQuery: 'Blow Me Away',
            targetDuration: null,
            search: (_) async {
              calls++;
              throw LyricsLookupException(
                'LRCLIB is temporarily unavailable. Please try again later.',
                retryAt: DateTime.now().add(const Duration(seconds: 60)),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Retry in '), findsOneWidget);
    expect(tester.widget<TextButton>(find.byType(TextButton)).onPressed, isNull);
    expect(calls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
