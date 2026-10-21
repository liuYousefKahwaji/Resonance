import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/models/youtube_search_source.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/screens/youtube/youtube_search_screen.dart';
import 'package:resonance/widgets/youtube/android_youtube.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('switch reruns query and discards the previous source response', (tester) async {
    final music = Completer<List<YoutubeTrack>>();
    final calls = <YoutubeSearchSource>[];
    await tester.pumpWidget(
      MaterialApp(
        home: YoutubeSearchScreen(
          playlistNumber: 1,
          playlistName: 'Library',
          initialQuery: 'yes',
          sourceSearchLoader: (query, limit, source) {
            calls.add(source);
            return source == YoutubeSearchSource.music
                ? music.future
                : Future.value([
                    const YoutubeTrack(title: 'YouTube result', artist: 'A', url: 'https://youtu.be/abcdefghijk'),
                  ]);
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(calls, [YoutubeSearchSource.music]);
    await tester.tap(find.byKey(const ValueKey('search-source-youtube')));
    await tester.pumpAndSettle();
    expect(calls, [YoutubeSearchSource.music, YoutubeSearchSource.youtube]);
    expect(find.text('YouTube result'), findsOneWidget);
    music.complete([const YoutubeTrack(title: 'Obsolete music', artist: 'B', url: 'https://youtu.be/lmnopqrstuv')]);
    await tester.pumpAndSettle();
    expect(find.text('Obsolete music'), findsNothing);
    expect((await SharedPreferences.getInstance()).getString('youtube_search_source'), 'youtube');
  });
  testWidgets('saved source is used for the first query', (tester) async {
    SharedPreferences.setMockInitialValues({'youtube_search_source': 'youtube'});
    final calls = <YoutubeSearchSource>[];
    await tester.pumpWidget(
      MaterialApp(
        home: YoutubeSearchScreen(
          playlistNumber: 1,
          playlistName: 'Library',
          initialQuery: 'yes',
          sourceSearchLoader: (query, limit, source) async {
            calls.add(source);
            return [];
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, [YoutubeSearchSource.youtube]);
  });
  test('Android source travels through channel and caches never mix', () async {
    const channel = MethodChannel('resonance/android_youtube');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      final source = (call.arguments as Map)['source'] as String;
      calls.add(source);
      return '[{"title":"$source","artist":"A","url":"https://youtu.be/abcdefghijk"}]';
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );
    final downloader = AndroidYoutubeDownloader();
    expect((await downloader.search('source-isolation', source: YoutubeSearchSource.music)).single.title, 'music');
    expect((await downloader.search('source-isolation', source: YoutubeSearchSource.youtube)).single.title, 'youtube');
    expect(calls, ['music', 'youtube']);
  });
}
