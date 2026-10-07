import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/l10n/arabic_messages.dart';
import 'package:resonance/providers/language_provider.dart';
import 'package:resonance/widgets/settings/language_selector.dart';
import 'package:resonance/core/youtube/youtube_music_home_models.dart';
import 'package:resonance/models/external_playlist.dart';
import 'package:resonance/screens/youtube/youtube_collection_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget languageApp(LanguageProvider language, Widget home) => ChangeNotifierProvider.value(
  value: language,
  child: Consumer<LanguageProvider>(
    builder: (context, language, _) => MaterialApp(
      locale: language.locale,
      supportedLocales: AppStrings.supportedLocales,
      localizationsDelegates: const [
        AppStrings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: home,
    ),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('language persists, reloads and rejects unsupported values', () async {
    final language = LanguageProvider();
    await language.initialize();
    expect(language.locale, const Locale('en'));
    await language.setLocale(const Locale('ar'));
    final reloaded = LanguageProvider();
    await reloaded.initialize();
    expect(reloaded.locale, const Locale('ar'));
    await expectLater(language.setLocale(const Locale('fr')), throwsArgumentError);
    SharedPreferences.setMockInitialValues({LanguageProvider.preferenceKey: 'invalid'});
    await reloaded.initialize();
    expect(reloaded.locale, const Locale('en'));
    language.dispose();
    reloaded.dispose();
  });

  test('brand is transliterated and mixed-content arguments are isolated once', () {
    const ar = AppStrings(Locale('ar'));
    expect(ar.text('Resonance'), 'ريزونانس');
    final message = ar.text('{0} added to {1}', ['Song {1}', 'قائمة My Mix']);
    expect(message, contains('\u2068Song {1}\u2069'));
    expect(message, contains('\u2068قائمة My Mix\u2069'));
    expect(ar.rendered('12 downloads waiting'), ar.text('{0} downloads waiting', ['12']));
    expect(ar.text('unrecognized'), 'unrecognized');
  });

  test('Arabic messages never introduce placeholders absent from English', () {
    final placeholders = RegExp(r'\{\d+\}');
    for (final entry in arabicMessages.entries) {
      expect(entry.value.trim(), isNotEmpty, reason: entry.key);
      final source = placeholders.allMatches(entry.key).map((m) => m[0]).toSet();
      final target = placeholders.allMatches(entry.value).map((m) => m[0]).toSet();
      expect(source.containsAll(target), isTrue, reason: entry.key);
    }
  });

  testWidgets('the actual settings selector switches the existing route and can switch back', (tester) async {
    final language = LanguageProvider();
    final marker = GlobalKey();
    await tester.pumpWidget(
      languageApp(
        language,
        Builder(
          builder: (context) => Scaffold(
            appBar: AppBar(title: Text(context.tr('Resonance'))),
            body: ListTile(
              key: marker,
              leading: const Icon(Icons.language),
              title: Text(context.tr('Language')),
              trailing: const LanguageSelector(),
            ),
          ),
        ),
      ),
    );
    expect(Directionality.of(marker.currentContext!), TextDirection.ltr);
    await tester.tap(find.byKey(const Key('app-language-setting')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('العربية').last);
    await tester.pumpAndSettle();
    expect(find.text('ريزونانس'), findsOneWidget);
    expect(find.text('اللغة'), findsOneWidget);
    expect(Directionality.of(marker.currentContext!), TextDirection.rtl);
    expect(
      tester.getCenter(find.byIcon(Icons.language)).dx,
      greaterThan(tester.getCenter(find.byKey(const Key('app-language-setting'))).dx),
    );
    expect((await SharedPreferences.getInstance()).getString(LanguageProvider.preferenceKey), 'ar');
    await tester.tap(find.byKey(const Key('app-language-setting')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English').last);
    await tester.pumpAndSettle();
    expect(Directionality.of(marker.currentContext!), TextDirection.ltr);
    expect(find.text('Resonance'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    language.dispose();
  });

  for (final width in [320.0, 1280.0]) {
    testWidgets('Arabic collection at width $width preserves song metadata and queue selection', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final language = LanguageProvider();
      await language.setLocale(const Locale('ar'));
      String? played;
      await tester.pumpWidget(
        languageApp(
          language,
          YoutubeCollectionScreen(
            item: const YoutubeMusicHomeItem(
              title: 'My Mix مزيج',
              subtitle: 'Mixed artists',
              kind: 'playlist',
              playlistId: 'PLtest',
            ),
            loader: (_) async => ExternalPlaylist(
              kind: ExternalPlaylistKind.youtube,
              name: 'My Mix مزيج',
              sourceUri: Uri.parse('https://music.youtube.com/playlist?list=PLtest'),
              tracks: const [
                ExternalPlaylistTrack(
                  title: 'English Song أغنية',
                  artists: ['Artist فنان'],
                  sourceId: 'aaaaaaaaaaa',
                  duration: Duration(seconds: 125),
                ),
              ],
            ),
            onPlay: (track, _) async => played = track.title,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(const AppStrings(Locale('ar')).text('Playlist')), findsOneWidget);
      expect(find.text('My Mix مزيج'), findsOneWidget);
      await tester.ensureVisible(find.text('English Song أغنية'));
      await tester.tap(find.text('English Song أغنية'));
      await tester.pumpAndSettle();
      expect(played, 'English Song أغنية');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      language.dispose();
    });
  }
}
