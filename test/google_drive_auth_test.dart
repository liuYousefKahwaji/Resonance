import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/services/google_drive/google_drive_auth.dart';
import 'package:resonance/services/google_drive/google_drive_models.dart';

class MemoryCredentials implements DriveCredentialStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String? data) async {
    value = data;
  }
}

const config = GoogleDriveConfig(windowsClientId: 'desktop-client', windowsClientSecret: 'installed-app-value');

// Flutter's binding blocks HTTP by default; these requests only target the
// ephemeral 127.0.0.1 callback listener, while Google endpoints stay mocked.
class _LoopbackHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Android restore never opens Google sign-in until the user has connected', () async {
    SharedPreferences.setMockInitialValues({});
    final auth = AndroidGoogleDriveAuth(config: const GoogleDriveConfig(androidServerClientId: 'web-client'));
    // No native plugin is registered here: any unintended SDK invocation fails.
    await auth.restore();
    expect(auth.account, isNull);
    await auth.logout();
    expect((await SharedPreferences.getInstance()).getBool('google_drive_android_connected_v1'), isFalse);
    await auth.restore();
    expect(auth.account, isNull);
  });

  test('desktop flow uses loopback, state and PKCE, then restores encrypted-store session', () async {
    final store = MemoryCredentials();
    late Uri authorization;
    var refreshes = 0;
    http.Client client() => MockClient((request) async {
      if (request.url.path == '/token') {
        final fields = request.bodyFields;
        if (fields['grant_type'] == 'authorization_code') {
          expect(fields['code'], 'test-code');
          final challenge = base64UrlEncode(
            sha256.convert(ascii.encode(fields['code_verifier']!)).bytes,
          ).replaceAll('=', '');
          expect(challenge, authorization.queryParameters['code_challenge']);
          expect(fields['redirect_uri'], authorization.queryParameters['redirect_uri']);
        } else {
          refreshes++;
        }
        return http.Response(
          jsonEncode({
            'access_token': refreshes == 0 ? 'access-one' : 'access-two',
            'token_type': 'Bearer',
            'expires_in': 3600,
            'refresh_token': 'refresh-one',
            'scope': 'openid profile email $googleDriveFileScope',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      expect(request.url.path, '/oauth2/v3/userinfo');
      return http.Response(
        jsonEncode({
          'sub': 'account-one',
          'name': 'مستمع ريزونانس',
          'picture': 'https://lh3.googleusercontent.com/avatar',
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final auth = DesktopGoogleDriveAuth(
      config: config,
      store: store,
      clientFactory: client,
      openBrowser: (uri) async {
        authorization = uri;
        expect(uri.host, 'accounts.google.com');
        expect(uri.queryParameters['code_challenge_method'], 'S256');
        expect(uri.queryParameters['scope'], contains(googleDriveFileScope));
        final redirect = Uri.parse(uri.queryParameters['redirect_uri']!);
        expect(redirect.host, '127.0.0.1');
        final wrong = await HttpOverrides.runWithHttpOverrides(
          () => http.get(redirect.replace(queryParameters: {'code': 'wrong', 'state': 'wrong-state'})),
          _LoopbackHttpOverrides(),
        );
        expect(wrong.statusCode, 400);
        final correct = await HttpOverrides.runWithHttpOverrides(
          () => http.get(
            redirect.replace(queryParameters: {'code': 'test-code', 'state': uri.queryParameters['state']!}),
          ),
          _LoopbackHttpOverrides(),
        );
        expect(correct.statusCode, 200);
        return true;
      },
    );
    await auth.connect();
    expect(auth.account!.name, 'مستمع ريزونانس');
    expect(await auth.accessToken(), 'access-one');
    expect(store.value, contains('refresh-one'));
    final restored = DesktopGoogleDriveAuth(config: config, store: store, clientFactory: client);
    await restored.restore();
    expect(restored.account!.id, 'account-one');
    expect(await restored.accessToken(refresh: true), 'access-two');
    expect(refreshes, 1);
    await restored.logout();
    expect(store.value, isNull);
    expect(restored.account, isNull);
  });

  test('browser refusal and timeout release the listener without saving a login', () async {
    final store = MemoryCredentials();
    final refused = DesktopGoogleDriveAuth(config: config, store: store, openBrowser: (_) async => false);
    await expectLater(refused.connect(), throwsA(isA<GoogleDriveException>()));
    final timed = DesktopGoogleDriveAuth(
      config: config,
      store: store,
      openBrowser: (_) async => true,
      loginTimeout: const Duration(milliseconds: 40),
    );
    await expectLater(timed.connect(), throwsA(isA<GoogleDriveException>()));
    expect(store.value, isNull);
  });

  test('logout cancels pending browser sign-in and cannot restore the old session later', () async {
    final store = MemoryCredentials();
    final opened = Completer<void>();
    final auth = DesktopGoogleDriveAuth(
      config: config,
      store: store,
      openBrowser: (_) async {
        opened.complete();
        return true;
      },
    );
    final connecting = auth.connect();
    final outcome = expectLater(connecting, throwsA(isA<GoogleDriveCancelled>()));
    await opened.future;
    await auth.logout();
    await outcome;
    expect(store.value, isNull);
    expect(auth.account, isNull);
  });

  test('saved credentials from another OAuth client are never reused', () async {
    final store = MemoryCredentials()..value = jsonEncode({'clientId': 'different-client'});
    final auth = DesktopGoogleDriveAuth(config: config, store: store);
    await auth.restore();
    expect(auth.account, isNull);
    await expectLater(auth.accessToken(), throwsA(isA<GoogleDriveException>()));
  });

  test('missing setup fails before opening a browser', () async {
    var opened = false;
    final auth = DesktopGoogleDriveAuth(
      config: const GoogleDriveConfig(windowsClientId: '', windowsClientSecret: ''),
      store: MemoryCredentials(),
      openBrowser: (_) async {
        opened = true;
        return true;
      },
    );
    await expectLater(auth.connect(), throwsA(isA<GoogleDriveException>()));
    expect(opened, isFalse);
  });
}
