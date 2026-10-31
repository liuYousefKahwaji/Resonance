import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/app/theme.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/providers/theme_provider.dart';
import 'package:resonance/widgets/library/modern_music_shell.dart';
import 'package:resonance/widgets/player/cinematic_intro.dart';
import 'package:resonance/screens/youtube/youtube_search_screen.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/widgets/player/compact_player.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/audio/playback_preferences.dart';
import 'package:audio_service/audio_service.dart';
import 'package:provider/provider.dart';
import 'package:just_audio/just_audio.dart';
import 'package:resonance/core/audio/shuffle_order.dart';
import 'package:resonance/services/suggested_music_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final icons = await File('build/unit_test_assets/fonts/MaterialIcons-Regular.otf').readAsBytes();
    await (FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(icons)))).load();
    final fontFile = File(r'C:\Windows\Fonts\segoeui.ttf');
    if (await fontFile.exists()) {
      final bytes = await fontFile.readAsBytes();
      await (FontLoader('ReviewFont')..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
  });
  test('new layout defaults on; cinematic intro stays opt-in; both are reversible', () async {
    SharedPreferences.setMockInitialValues({});
    final provider = ThemeProvider();
    expect(provider.modernLayout, isTrue, reason: 'The first frame uses the new default too.');
    await Future<void>.delayed(Duration.zero);
    expect(provider.modernLayout, isTrue);
    expect(provider.cinematicIntro, isFalse);
    await provider.setModernLayout(true);
    await provider.setCinematicIntro(true);
    await provider.reloadPortablePreferences();
    expect(provider.modernLayout, isTrue);
    expect(provider.cinematicIntro, isTrue);
    await provider.setModernLayout(false);
    await provider.setCinematicIntro(false);
    await provider.reloadPortablePreferences();
    expect(provider.modernLayout, isFalse);
    expect(provider.cinematicIntro, isFalse);
    provider.dispose();
  });

  test('a saved classic layout choice survives startup and preference reload', () async {
    SharedPreferences.setMockInitialValues({'modern_layout': false});
    final provider = ThemeProvider();
    await provider.reloadPortablePreferences();
    expect(provider.modernLayout, isFalse);
    await provider.setModernLayout(true);
    await provider.reloadPortablePreferences();
    expect(provider.modernLayout, isTrue);
    provider.dispose();
  });

  for (final locale in [const Locale('en'), const Locale('ar')]) {
    for (final width in [320.0, 390.0, 850.0, 1280.0]) {
      testWidgets('optional shell and compact Search remain usable at $width ${locale.languageCode}', (tester) async {
        SharedPreferences.setMockInitialValues({});
        await tester.binding.setSurfaceSize(Size(width, 820));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var selected = -1;
        final handler = _Handler();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          handler.close();
        });
        final played = <String>[];
        final first = Completer<void>();
        final capture = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            supportedLocales: AppStrings.supportedLocales,
            localizationsDelegates: const [
              AppStrings.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            theme: buildResonanceTheme(ResonanceThemeStyle.obsidian, Brightness.dark).copyWith(
              textTheme: buildResonanceTheme(
                ResonanceThemeStyle.obsidian,
                Brightness.dark,
              ).textTheme.apply(fontFamily: 'ReviewFont'),
            ),
            home: Provider<PlayerHandler>.value(
              value: handler,
              child: Scaffold(
                body: RepaintBoundary(
                  key: capture,
                  child: ModernMusicShell(
                    selected: 1,
                    onSelected: (value) => selected = value,
                    onSettings: () {},
                    onHistory: () {},
                    downloads: const SizedBox.shrink(),
                    player: CompactPlayer(handler: handler, onExpand: (_) {}, onQueue: () {}),
                    content: YoutubeSearchScreen(
                      playlistNumber: 1,
                      playlistName: 'Favorites',
                      embedded: true,
                      compactResults: true,
                      searchOnly: true,
                      initialQuery: 'Neoni',
                      searchLoader: (_, __) async => const [
                        YoutubeTrack(
                          title: 'Haunted House',
                          artist: 'Neoni',
                          url: 'https://www.youtube.com/watch?v=abcdefghijk',
                        ),
                        YoutubeTrack(
                          title: 'MONEY ON THE DASH',
                          artist: 'Elley Duhé & Whethan',
                          url: 'https://www.youtube.com/watch?v=01234567890',
                        ),
                      ],
                      onPlay: (track, _) {
                        played.add(track.title);
                        return played.length == 1 ? first.future : Future.value();
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Haunted House').first);
        await tester.pump();
        await tester.tap(find.text('MONEY ON THE DASH'));
        await tester.pump();
        expect(played, ['Haunted House', 'MONEY ON THE DASH']);
        first.completeError(StateError('obsolete request'));
        await tester.pumpAndSettle();
        expect(find.text('Could not play stream'), findsNothing);
        final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(capture));
        await tester.runAsync(() async {
          final picture = await boundary.toImage(pixelRatio: 1);
          final png = await picture.toByteData(format: ui.ImageByteFormat.png);
          final file = File('build/v390-ui/search-${locale.languageCode}-${width.toInt()}.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(png!.buffer.asUint8List());
          picture.dispose();
        });
        final library = AppStrings(locale).text('Library');
        await tester.tap(find.byTooltip(AppStrings(locale).text('Playback Settings')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('playback-scope-selector')), findsOneWidget);
        expect(find.byKey(const Key('track-volume-slider')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text(AppStrings(locale).text('Close')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(library));
        await tester.pump();
        expect(selected, 2);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final locale in [const Locale('en'), const Locale('ar')]) {
    for (final width in [390.0, 1280.0]) {
      testWidgets('Discover grid and playlist navigation at $width ${locale.languageCode}', (tester) async {
        SharedPreferences.setMockInitialValues({});
        await tester.binding.setSurfaceSize(Size(width, 820));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final handler = _Handler();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          handler.close();
        });
        final capture = GlobalKey();
        var pickedPlaylist = false;
        final songs = [
          'Haunted House',
          'MONEY ON THE DASH',
          'Blow Me Away',
          'SUKOON',
          'FUNK GLORIA',
          'NO DESCENDO',
          'That’s So True',
          'mandragora 2',
        ];
        final artists = [
          'Neoni',
          'Elley Duhé & Whethan',
          'Breaking Benjamin',
          'Dhruv Vajani',
          'Dhruv Vajani',
          'slxughter',
          'Gracie Abrams',
          'gunbaou',
        ];
        final tracks = [
          for (var i = 0; i < songs.length; i++)
            YoutubeTrack(title: songs[i], artist: artists[i], url: 'https://www.youtube.com/watch?v=fixture000$i'),
        ];
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            supportedLocales: AppStrings.supportedLocales,
            localizationsDelegates: const [
              AppStrings.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            theme: buildResonanceTheme(ResonanceThemeStyle.obsidian, Brightness.dark).copyWith(
              textTheme: buildResonanceTheme(
                ResonanceThemeStyle.obsidian,
                Brightness.dark,
              ).textTheme.apply(fontFamily: 'ReviewFont'),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(width < 850 ? 1.5 : 1)),
              child: child!,
            ),
            home: Provider<PlayerHandler>.value(
              value: handler,
              child: Scaffold(
                body: RepaintBoundary(
                  key: capture,
                  child: ModernMusicShell(
                    selected: 0,
                    onSelected: (_) {},
                    onSettings: () {},
                    onHistory: () {},
                    downloads: const SizedBox.shrink(),
                    playlists: [
                      ModernPlaylistDestination(
                        name: AppStrings(locale).text('Favorites'),
                        favorite: true,
                        onSelected: () => pickedPlaylist = true,
                      ),
                      ModernPlaylistDestination(name: 'Night drive', onSelected: () {}),
                    ],
                    player: CompactPlayer(handler: handler, onExpand: (_) {}, onQueue: () {}),
                    content: YoutubeSearchScreen(
                      playlistNumber: 1,
                      playlistName: 'Night drive',
                      embedded: true,
                      compactResults: true,
                      onPlay: (_, __) async {},
                      suggestionsLoader: ({required refresh, required isCancelled}) async => SuggestedMusicResult(
                        profile: const PlaylistProfile(
                          playlistNumber: 1,
                          playlistName: 'Night drive',
                          fingerprint: 'fixture',
                          tracks: [PlaylistProfileTrack(path: 'fixture', title: 'Haunted House', artist: 'Neoni')],
                          artistWeights: {},
                          tokenWeights: {},
                          variantTokens: {},
                        ),
                        tracks: tracks,
                        fromCache: false,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('youtube-search-field')), findsNothing);
        expect(find.byType(GridView), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (width < 850) {
          expect(tester.getSize(find.byType(CompactPlayer)).height, lessThan(150));
          expect(find.byTooltip(AppStrings(locale).text('Previous')), findsOneWidget);
          expect(find.byTooltip(AppStrings(locale).text('Loop off')), findsOneWidget);
          expect(find.byTooltip(AppStrings(locale).text('Shuffle off')), findsOneWidget);
          expect(find.byTooltip(AppStrings(locale).text('Playback Settings')), findsOneWidget);
          await tester.tap(find.byTooltip(AppStrings(locale).text('Volume')));
          await tester.pumpAndSettle();
          expect(find.byType(Slider), findsNWidgets(2));
          expect(tester.takeException(), isNull);
          Navigator.of(tester.element(find.byType(Slider).last)).pop();
          await tester.pumpAndSettle();
        }
        final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(capture));
        await tester.runAsync(() async {
          final picture = await boundary.toImage(pixelRatio: 1);
          final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
          final file = File('build/v390-ui/discover-${locale.languageCode}-${width.toInt()}.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          picture.dispose();
        });
        if (width >= 850) {
          await tester.tap(find.text(AppStrings(locale).text('Favorites')));
          expect(pickedPlaylist, isTrue);
        }
      });
    }
  }

  testWidgets('cinematic intro can skip immediately with reduced motion', (tester) async {
    final position = ValueNotifier(const Duration(milliseconds: 1200));
    var skipped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: CinematicIntro(position: position, onDismiss: () => skipped = true),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Resonance'), findsOneWidget);
    await tester.tap(find.text('tap to skip'));
    expect(skipped, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    position.dispose();
  });

  testWidgets('cinematic stages render on the original sound timeline', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final position = ValueNotifier(Duration.zero);
    final capture = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildResonanceTheme(ResonanceThemeStyle.obsidian, Brightness.dark).copyWith(
          textTheme: buildResonanceTheme(
            ResonanceThemeStyle.obsidian,
            Brightness.dark,
          ).textTheme.apply(fontFamily: 'ReviewFont'),
        ),
        home: DefaultTextStyle(
          style: const TextStyle(fontFamily: 'ReviewFont', color: Colors.white),
          child: RepaintBoundary(
            key: capture,
            child: CinematicIntro(position: position, onDismiss: () {}),
          ),
        ),
      ),
    );
    for (final milliseconds in [350, 1100, 2200]) {
      position.value = Duration(milliseconds: milliseconds);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull);
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(capture));
      await tester.runAsync(() async {
        final picture = await boundary.toImage(pixelRatio: 1);
        final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/v390-ui/intro-$milliseconds.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        picture.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox.shrink());
    position.dispose();
  });
}

class _Handler extends Fake implements PlayerHandler {
  @override
  final speedNotifier = ValueNotifier<double>(1);
  @override
  final pitchNotifier = ValueNotifier<double>(1);
  @override
  final equalizerNotifier = ValueNotifier(EqualizerSettings.flat);
  @override
  final trackVolumePercentNotifier = ValueNotifier<double>(0);
  @override
  final playbackSettingsScopeNotifier = ValueNotifier(PlaybackSettingsScope.global);
  @override
  final playbackModeRevision = ValueNotifier(0);
  @override
  LoopMode getLoopMode() => LoopMode.off;
  @override
  bool getShuffleMode() => false;
  @override
  PlaybackOrderMode get playbackOrderMode => PlaybackOrderMode.off;
  final _base = BaseAudioHandler();
  _Handler() {
    mediaItem.add(
      const MediaItem(
        id: 'https://www.youtube.com/watch?v=abcdefghijk',
        title: 'Haunted House',
        artist: 'Neoni',
        duration: Duration(minutes: 3),
      ),
    );
    playbackState.add(PlaybackState(processingState: AudioProcessingState.ready, playing: true));
  }
  @override
  get mediaItem => _base.mediaItem;
  @override
  get playbackState => _base.playbackState;
  @override
  get voiceChat => null;
  @override
  final volumeNotifier = ValueNotifier<double>(0.7);
  @override
  final playbackVisualNotifier = ValueNotifier(const PlaybackVisualState(playing: true));
  @override
  final playbackRangeNotifier = ValueNotifier(PlaybackRange.full);
  @override
  final uiVisibleNotifier = ValueNotifier(true);
  @override
  final seekStepNotifier = ValueNotifier(5);
  @override
  PlaybackRange get currentPlaybackRange => PlaybackRange.full;
  @override
  Duration get currentPosition => const Duration(seconds: 32);
  @override
  Duration get currentDuration => const Duration(minutes: 3);
  @override
  Duration get currentSourceDuration => currentDuration;
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Future<void> previous({bool restartCurrent = true}) async {}
  @override
  Future<void> next() async {}
  @override
  Future<void> playPause() async {}
  @override
  Future<void> changeVolume(double value) async => volumeNotifier.value = value;
  void close() {
    speedNotifier.dispose();
    pitchNotifier.dispose();
    equalizerNotifier.dispose();
    trackVolumePercentNotifier.dispose();
    playbackSettingsScopeNotifier.dispose();
    playbackModeRevision.dispose();
    volumeNotifier.dispose();
    playbackVisualNotifier.dispose();
    playbackRangeNotifier.dispose();
    uiVisibleNotifier.dispose();
    seekStepNotifier.dispose();
  }
}
