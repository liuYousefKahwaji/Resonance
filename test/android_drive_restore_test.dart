import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart' as platform;
import 'package:resonance/services/google_drive/google_drive_auth.dart';
import 'package:resonance/services/google_drive/google_drive_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

const config = GoogleDriveConfig(androidServerClientId: 'test-web-client');
Map<String, Object> saved() => {
  'google_drive_android_connected_v1': true,
  'google_drive_android_account_v2': jsonEncode({
    'account': {'id': 'google-user', 'name': 'Listener'},
    'email': 'listener@example.test',
    'musicLibraryAccess': false,
  }),
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late platform.GoogleSignInPlatform original;
  late _Google sdk;
  setUp(() {
    original = platform.GoogleSignInPlatform.instance;
    sdk = _Google();
    platform.GoogleSignInPlatform.instance = sdk;
  });
  tearDown(() => platform.GoogleSignInPlatform.instance = original);
  test('restore reads identity without account picker or even SDK initialization', () async {
    SharedPreferences.setMockInitialValues(saved());
    final auth = AndroidGoogleDriveAuth(config: config);
    await auth.restore();
    expect(auth.account?.name, 'Listener');
    expect(sdk.initializations, 0);
    expect(sdk.lightweight, 0);
    expect(sdk.authentications, 0);
    expect(await auth.accessToken(), 'fresh-access-token');
    expect(sdk.requests.single.email, 'listener@example.test');
    expect(sdk.requests.single.userId, 'google-user');
    expect(sdk.requests.single.promptIfUnauthorized, isFalse);
    expect(
      (await SharedPreferences.getInstance()).getString('google_drive_android_account_v2'),
      isNot(contains('fresh-access-token')),
    );
  });
  test('explicit connect persists an identity that a new process can restore silently', () async {
    SharedPreferences.setMockInitialValues({});
    final first = AndroidGoogleDriveAuth(config: config);
    await first.connect();
    expect(sdk.authentications, 1);
    expect(first.account?.id, 'google-user');
    final second = AndroidGoogleDriveAuth(config: config);
    await second.restore();
    expect(second.account?.id, 'google-user');
    expect(sdk.lightweight, 0);
    expect(sdk.authentications, 1);
    expect(await second.accessToken(), 'fresh-access-token');
    expect(sdk.requests.last.email, 'listener@example.test');
    expect(sdk.requests.last.promptIfUnauthorized, isFalse);
  });
  test('revoked authorization requires explicit reconnect, never a startup sign-in prompt', () async {
    SharedPreferences.setMockInitialValues(saved());
    sdk.revoked = true;
    final auth = AndroidGoogleDriveAuth(config: config);
    await auth.restore();
    await expectLater(auth.accessToken(), throwsA(isA<GoogleDriveException>()));
    expect(auth.account?.id, 'google-user');
    expect(sdk.authentications, 0);
    expect(sdk.lightweight, 0);
    expect(sdk.requests.single.promptIfUnauthorized, isFalse);
  });
  test('logout invalidates a late authorization response and removes saved identity', () async {
    SharedPreferences.setMockInitialValues(saved());
    final auth = AndroidGoogleDriveAuth(config: config);
    await auth.restore();
    sdk.pending = Completer<platform.ClientAuthorizationTokenData?>();
    final token = auth.accessToken();
    final expectation = expectLater(token, throwsA(isA<GoogleDriveCancelled>()));
    await sdk.requested.future;
    await auth.logout();
    sdk.pending!.complete(const platform.ClientAuthorizationTokenData(accessToken: 'late-token'));
    await expectation;
    expect(auth.account, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('google_drive_android_connected_v1'), isFalse);
    expect(prefs.getString('google_drive_android_account_v2'), isNull);
  });
  test('transient SDK initialization failure can retry without account selection', () async {
    SharedPreferences.setMockInitialValues(saved());
    sdk.failInitialization = true;
    final auth = AndroidGoogleDriveAuth(config: config);
    await auth.restore();
    await expectLater(auth.accessToken(), throwsStateError);
    sdk.failInitialization = false;
    expect(await auth.accessToken(), 'fresh-access-token');
    expect(sdk.initializations, 2);
    expect(sdk.authentications, 0);
    expect(sdk.lightweight, 0);
  });
  test('legacy installs need one explicit reconnect, not repeated automatic account prompts', () async {
    SharedPreferences.setMockInitialValues({'google_drive_android_connected_v1': true});
    final auth = AndroidGoogleDriveAuth(config: config);
    await auth.restore();
    expect(auth.account, isNull);
    expect(sdk.lightweight, 0);
    expect(sdk.initializations, 0);
    await auth.connect();
    final restored = AndroidGoogleDriveAuth(config: config);
    await restored.restore();
    expect(restored.account, isNotNull);
  });
}

class _Google extends platform.GoogleSignInPlatform {
  int initializations = 0, lightweight = 0, authentications = 0;
  bool revoked = false;
  bool failInitialization = false;
  final requests = <platform.AuthorizationRequestDetails>[];
  final requested = Completer<void>();
  Completer<platform.ClientAuthorizationTokenData?>? pending;
  @override
  Future<void> init(platform.InitParameters params) async {
    initializations++;
    if (failInitialization) throw StateError('Temporary SDK failure');
  }

  @override
  Future<platform.AuthenticationResults?> attemptLightweightAuthentication(
    platform.AttemptLightweightAuthenticationParameters params,
  ) async {
    lightweight++;
    return null;
  }

  @override
  Future<platform.AuthenticationResults> authenticate(platform.AuthenticateParameters params) async {
    authentications++;
    return const platform.AuthenticationResults(
      user: platform.GoogleSignInUserData(email: 'listener@example.test', id: 'google-user', displayName: 'Listener'),
      authenticationTokens: platform.AuthenticationTokenData(idToken: 'test-identity'),
    );
  }

  @override
  bool supportsAuthenticate() => true;
  @override
  bool authorizationRequiresUserInteraction() => false;
  @override
  Future<platform.ServerAuthorizationTokenData?> serverAuthorizationTokensForScopes(
    platform.ServerAuthorizationTokensForScopesParameters params,
  ) async => null;
  @override
  Future<platform.ClientAuthorizationTokenData?> clientAuthorizationTokensForScopes(
    platform.ClientAuthorizationTokensForScopesParameters params,
  ) async {
    requests.add(params.request);
    if (!requested.isCompleted) requested.complete();
    if (pending != null) return pending!.future;
    if (revoked || params.request.scopes.contains(googleDriveMusicReadScope)) return null;
    return const platform.ClientAuthorizationTokenData(accessToken: 'fresh-access-token');
  }

  @override
  Future<void> clearAuthorizationToken(platform.ClearAuthorizationTokenParams params) async {}
  @override
  Future<void> signOut(platform.SignOutParams params) async {}
  @override
  Future<void> disconnect(platform.DisconnectParams params) async {}
}
