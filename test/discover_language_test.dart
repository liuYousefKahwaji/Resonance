import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/youtube/youtube_music_home_models.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/providers/language_provider.dart';
import 'package:resonance/screens/youtube/youtube_search_screen.dart';
import 'package:resonance/widgets/library/listening_focus_tab.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget localizedApp(LanguageProvider language, Widget child) => ChangeNotifierProvider.value(
  value: language,
  child: Consumer<LanguageProvider>(
    builder: (_, language, _) => MaterialApp(
      locale: language.locale,
      supportedLocales: AppStrings.supportedLocales,
      localizationsDelegates: const [
        AppStrings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(body: child),
    ),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Arabic shelf arrows and mouse dragging follow RTL scrolling', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final language = LanguageProvider();
    await language.setLocale(const Locale('ar'));
    addTearDown(language.dispose);
    await tester.pumpWidget(
      localizedApp(
        language,
        YoutubeSearchScreen(
          playlistNumber: 1,
          playlistName: 'Playlist',
          embedded: true,
          startOnMusicHome: true,
          youtubeMusicHomeLoader: () async => YoutubeMusicHome(
            shelves: [
              YoutubeMusicHomeShelf(
                title: 'اختيارات سريعة',
                kind: 'quickPicks',
                tracks: List.generate(
                  24,
                  (i) => YoutubeTrack(
                    title: 'Song $i',
                    artist: 'Artist',
                    url: 'https://www.youtube.com/watch?v=track00000$i',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final grid = tester.widget<GridView>(find.byType(GridView));
    final position = grid.controller!.position;
    expect(position.axisDirection, AxisDirection.left);
    final forward = find.byKey(const Key('youtube-shelf-scroll-right'));
    expect(
      tester.widget<IconButton>(forward).icon,
      isA<Icon>().having((icon) => icon.icon, 'direction', Icons.chevron_left_rounded),
    );
    await tester.tap(forward);
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
    await tester.tap(find.byKey(const Key('youtube-shelf-scroll-left')));
    await tester.pumpAndSettle();
    expect(position.pixels, 0);
    final gesture = await tester.startGesture(tester.getCenter(find.byType(GridView)), kind: PointerDeviceKind.mouse);
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(240, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('real Library and Discover tabs translate live and remain clickable', (tester) async {
    final language = LanguageProvider();
    addTearDown(language.dispose);
    var selected = '';
    await tester.pumpWidget(
      localizedApp(
        language,
        Row(
          children: [
            ListeningFocusTab(
              label: 'Library',
              icon: Icons.library_music,
              selected: true,
              onTap: () => selected = 'library',
            ),
            ListeningFocusTab(
              label: 'Discover',
              icon: Icons.explore,
              selected: false,
              onTap: () => selected = 'discover',
            ),
          ],
        ),
      ),
    );
    expect(find.text('Library'), findsOneWidget);
    await language.setLocale(const Locale('ar'));
    await tester.pumpAndSettle();
    expect(find.text('Library'), findsNothing);
    expect(find.text('Discover'), findsNothing);
    expect(find.text('المكتبة'), findsOneWidget);
    await tester.tap(find.text('اكتشف'));
    expect(selected, 'discover');
    expect(Directionality.of(tester.element(find.text('اكتشف'))), TextDirection.rtl);
    await language.setLocale(const Locale('en'));
    await tester.pumpAndSettle();
    expect(find.text('Discover'), findsOneWidget);
  });

  testWidgets('Discover translates tabs, shelf headings, collection types and counts without translating names', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final language = LanguageProvider();
    await language.setLocale(const Locale('ar'));
    addTearDown(language.dispose);
    await tester.pumpWidget(
      localizedApp(
        language,
        YoutubeSearchScreen(
          playlistNumber: 1,
          playlistName: 'My original playlist',
          embedded: true,
          startOnMusicHome: true,
          playlistLibraryLoader: () async => const YoutubeMusicHomeShelf(
            title: 'Playlist Library',
            tracks: [],
            items: [
              YoutubeMusicHomeItem(
                title: 'My saved mix',
                subtitle: '20 songs',
                kind: 'playlist',
                playlistId: 'PLsaved',
              ),
            ],
          ),
          youtubeMusicHomeLoader: () async => const YoutubeMusicHome(
            shelves: [
              YoutubeMusicHomeShelf(
                title: 'Quick picks',
                tracks: [
                  YoutubeTrack(
                    title: 'Original song',
                    artist: 'Original artist',
                    url: 'https://www.youtube.com/watch?v=jNQXAC9IVRw',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('اقتراحات ريزونانس'), findsOneWidget);
    expect(find.text('صفحة يوتيوب ميوزيك الرئيسية'), findsOneWidget);
    expect(find.text('مكتبة قوائم التشغيل'), findsOneWidget);
    expect(find.text('اختيارات سريعة'), findsOneWidget);
    expect(find.text('قائمة تشغيل'), findsOneWidget);
    expect(find.textContaining('عدد الأغاني:'), findsOneWidget);
    expect(find.text('20 songs'), findsNothing);
    expect(find.text('My saved mix'), findsOneWidget);
    expect(find.text('Original song'), findsOneWidget);
    expect(find.text('Original artist'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching languages rejects a late old feed and preserves Arabic Quick picks layout', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final language = LanguageProvider();
    addTearDown(language.dispose);
    final oldFeed = Completer<YoutubeMusicHome>();
    final newFeed = Completer<YoutubeMusicHome>();
    var calls = 0;
    await tester.pumpWidget(
      localizedApp(
        language,
        YoutubeSearchScreen(
          playlistNumber: 1,
          playlistName: 'Playlist',
          embedded: true,
          startOnMusicHome: true,
          youtubeMusicHomeLoader: () => ++calls == 1 ? oldFeed.future : newFeed.future,
        ),
      ),
    );
    await tester.pump();
    expect(calls, 1);
    await language.setLocale(const Locale('ar'));
    await tester.pump();
    await tester.pump();
    expect(calls, 2);
    oldFeed.complete(
      const YoutubeMusicHome(
        shelves: [
          YoutubeMusicHomeShelf(
            title: 'Stale English shelf',
            tracks: [
              YoutubeTrack(title: 'Stale song', artist: 'Artist', url: 'https://www.youtube.com/watch?v=jNQXAC9IVRw'),
            ],
          ),
        ],
      ),
    );
    await tester.pump();
    expect(find.text('Stale song'), findsNothing);
    newFeed.complete(
      const YoutubeMusicHome(
        shelves: [
          YoutubeMusicHomeShelf(
            title: 'اختيارات سريعة',
            kind: 'quickPicks',
            tracks: [
              YoutubeTrack(title: 'Fresh song', artist: 'Artist', url: 'https://www.youtube.com/watch?v=jNQXAC9IVRw'),
            ],
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('اختيارات سريعة'), findsOneWidget);
    expect(find.text('Fresh song'), findsOneWidget);
    expect(find.byType(GridView), findsOneWidget);
    expect(find.text('Stale English shelf'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
