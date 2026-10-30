import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:resonance/services/google_drive/google_drive_auth.dart';
import 'package:resonance/services/google_drive/google_drive_models.dart';
import 'google_drive_auth_test.dart' show MemoryCredentials, config;

class _Loopback extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final scenario in ['grant', 'decline', 'different-account']) {
    test('optional read-only music permission: $scenario', () async {
      final store = MemoryCredentials();
      late Uri authorization;
      var logins = 0;
      final auth = DesktopGoogleDriveAuth(
        config: config,
        store: store,
        clientFactory: () => MockClient((request) async {
          if (request.url.path == '/token') {
            return http.Response(
              jsonEncode({
                'access_token': 'ephemeral-token',
                'token_type': 'Bearer',
                'expires_in': 3600,
                'refresh_token': 'refresh',
                'scope': logins > 1 && scenario == 'decline'
                    ? 'openid profile email $googleDriveFileScope'
                    : authorization.queryParameters['scope'],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode({
              'sub': logins > 1 && scenario == 'different-account' ? 'other' : 'listener',
              'name': 'Listener',
            }),
            200,
          );
        }),
        openBrowser: (uri) async {
          authorization = uri;
          logins++;
          expect(uri.queryParameters['scope']!.contains(googleDriveMusicReadScope), logins > 1);
          final redirect = Uri.parse(uri.queryParameters['redirect_uri']!);
          await HttpOverrides.runWithHttpOverrides(
            () => http.get(
              redirect.replace(queryParameters: {'state': uri.queryParameters['state']!, 'code': 'fixture'}),
            ),
            _Loopback(),
          );
          return true;
        },
      );
      await auth.connect();
      final before = store.value;
      expect(auth.musicLibraryAccess, isFalse);
      if (scenario == 'grant') {
        await auth.enableMusicLibrary();
        expect(auth.musicLibraryAccess, isTrue);
        final restored = DesktopGoogleDriveAuth(config: config, store: store);
        await restored.restore();
        expect(restored.musicLibraryAccess, isTrue);
        expect(restored.account!.id, 'listener');
      } else {
        await expectLater(auth.enableMusicLibrary(), throwsA(isA<GoogleDriveException>()));
        expect(auth.musicLibraryAccess, isFalse);
        expect(auth.account!.id, 'listener');
        expect(store.value, before);
      }
    });
  }
}
