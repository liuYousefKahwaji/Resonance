import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis_auth/auth_io.dart' as oauth;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'google_drive_models.dart';

const googleDriveFileScope = 'https://www.googleapis.com/auth/drive.file';
const googleDriveMusicReadScope = 'https://www.googleapis.com/auth/drive.readonly';

class GoogleDriveConfig {
  const GoogleDriveConfig({
    this.windowsClientId = const String.fromEnvironment('GOOGLE_DRIVE_WINDOWS_CLIENT_ID'),
    this.windowsClientSecret = const String.fromEnvironment('GOOGLE_DRIVE_WINDOWS_CLIENT_SECRET'),
    this.androidServerClientId = const String.fromEnvironment('GOOGLE_DRIVE_ANDROID_SERVER_CLIENT_ID'),
  });
  final String windowsClientId, windowsClientSecret, androidServerClientId;
}

abstract class GoogleDriveAuth {
  GoogleDriveAccount? get account;
  Future<void> restore();
  Future<void> connect();
  Future<String> accessToken({bool refresh = false});
  Future<void> logout();
  bool get musicLibraryAccess => false;
  Future<void> enableMusicLibrary() async =>
      throw const GoogleDriveException('Reconnect Google Drive to browse music.');

  static GoogleDriveAuth platform() => Platform.isAndroid ? AndroidGoogleDriveAuth() : DesktopGoogleDriveAuth();
}

/// Android owns account/token persistence in Google Play services. No Google
/// password or SDK access token is copied into Resonance preferences/backups.
class AndroidGoogleDriveAuth implements GoogleDriveAuth {
  AndroidGoogleDriveAuth({this.config = const GoogleDriveConfig()});
  final GoogleDriveConfig config;
  GoogleSignInAccount? _user;
  @override
  bool musicLibraryAccess = false;
  Future<void>? _initialization;
  Future<void> _preferenceQueue = Future.value();
  bool _initialized = false;
  static const _connectedKey = 'google_drive_android_connected_v1';
  int _epoch = 0;
  final _signIn = GoogleSignIn.instance;

  @override
  GoogleDriveAccount? get account {
    final user = _user;
    return user == null
        ? null
        : GoogleDriveAccount(id: user.id, name: user.displayName ?? user.email, photoUrl: user.photoUrl);
  }

  Future<void> _initialize() => _initialization ??= () async {
    if (config.androidServerClientId.isEmpty) {
      throw const GoogleDriveException('Google Drive is not configured in this build yet.');
    }
    await _signIn.initialize(serverClientId: config.androidServerClientId);
    _initialized = true;
  }();

  Future<void> _remember(int epoch, bool connected) {
    final write = _preferenceQueue.then((_) async {
      if (epoch != _epoch) return;
      final preferences = await SharedPreferences.getInstance();
      if (epoch == _epoch) await preferences.setBool(_connectedKey, connected);
    });
    _preferenceQueue = write.catchError((Object _) {});
    return write;
  }

  @override
  Future<void> restore() async {
    if (config.androidServerClientId.isEmpty) return;
    final epoch = _epoch;
    final preferences = await SharedPreferences.getInstance();
    if (preferences.getBool(_connectedKey) != true || epoch != _epoch) return;
    await _initialize();
    if (epoch != _epoch) return;
    final user = await _signIn.attemptLightweightAuthentication();
    final music =
        user != null &&
        await user.authorizationClient.authorizationForScopes(const [
              googleDriveFileScope,
              googleDriveMusicReadScope,
            ]) !=
            null;
    if (epoch == _epoch) {
      _user = user;
      musicLibraryAccess = music;
    }
  }

  @override
  Future<void> connect() async {
    final epoch = ++_epoch;
    await _initialize();
    if (epoch != _epoch) throw const GoogleDriveCancelled();
    final user = await _signIn.authenticate(scopeHint: const [googleDriveFileScope]);
    if (epoch != _epoch) throw const GoogleDriveCancelled();
    await user.authorizationClient.authorizeScopes(const [googleDriveFileScope]);
    if (epoch != _epoch) throw const GoogleDriveCancelled();
    await _remember(epoch, true);
    if (epoch != _epoch) throw const GoogleDriveCancelled();
    final music =
        await user.authorizationClient.authorizationForScopes(const [
          googleDriveFileScope,
          googleDriveMusicReadScope,
        ]) !=
        null;
    if (epoch != _epoch) throw const GoogleDriveCancelled();
    _user = user;
    musicLibraryAccess = music;
  }

  @override
  Future<void> enableMusicLibrary() async {
    final epoch = _epoch;
    final user = _user;
    if (user == null) throw const GoogleDriveException('Connect Google Drive to continue.');
    await user.authorizationClient.authorizeScopes(const [googleDriveFileScope, googleDriveMusicReadScope]);
    if (epoch != _epoch || _user?.id != user.id) throw const GoogleDriveCancelled();
    musicLibraryAccess = true;
  }

  @override
  Future<String> accessToken({bool refresh = false}) async {
    final epoch = _epoch;
    final user = _user;
    if (user == null) throw const GoogleDriveException('Connect Google Drive to continue.');
    final client = user.authorizationClient;
    final scopes = [googleDriveFileScope, if (musicLibraryAccess) googleDriveMusicReadScope];
    var authorization = await client.authorizationForScopes(scopes);
    if (refresh && authorization != null) {
      await client.clearAuthorizationToken(accessToken: authorization.accessToken);
      authorization = await client.authorizationForScopes(scopes);
    }
    if (epoch != _epoch) throw const GoogleDriveCancelled();
    if (authorization == null) throw const GoogleDriveException('Reconnect Google Drive to allow playlist access.');
    return authorization.accessToken;
  }

  @override
  Future<void> logout() async {
    final epoch = ++_epoch;
    _user = null;
    musicLibraryAccess = false;
    await _remember(epoch, false);
    if (_initialized) await _signIn.signOut();
  }
}

abstract class DriveCredentialStore {
  Future<String?> read();
  Future<void> write(String? value);
}

class SecureDriveCredentialStore implements DriveCredentialStore {
  static const _storage = FlutterSecureStorage();
  static const _key = bool.fromEnvironment('RESONANCE_UPDATE_TEST')
      ? 'resonance_google_drive_test_v1'
      : 'resonance_google_drive_v1';
  @override
  Future<String?> read() => _storage.read(key: _key);
  @override
  Future<void> write(String? value) =>
      value == null ? _storage.delete(key: _key) : _storage.write(key: _key, value: value);
}

/// Public installed-app OAuth client: system browser, ephemeral loopback port,
/// state + S256 PKCE. Google handles credentials; the desktop refresh grant is
/// stored using the OS secure store and never enters portable backups.
class DesktopGoogleDriveAuth implements GoogleDriveAuth {
  DesktopGoogleDriveAuth({
    this.config = const GoogleDriveConfig(),
    DriveCredentialStore? store,
    http.Client Function()? clientFactory,
    Future<bool> Function(Uri)? openBrowser,
    this.loginTimeout = const Duration(minutes: 3),
  }) : _store = store ?? SecureDriveCredentialStore(),
       _clientFactory = clientFactory ?? http.Client.new,
       _openBrowser = openBrowser ?? ((uri) => launchUrl(uri, mode: LaunchMode.externalApplication));

  final GoogleDriveConfig config;
  final DriveCredentialStore _store;
  final http.Client Function() _clientFactory;
  final Future<bool> Function(Uri) _openBrowser;
  final Duration loginTimeout;
  @override
  GoogleDriveAccount? account;
  oauth.AccessCredentials? _credentials;
  @override
  bool get musicLibraryAccess => _credentials?.scopes.contains(googleDriveMusicReadScope) == true;
  HttpServer? _server;
  Completer<String>? _callback;
  int _epoch = 0;
  Future<void> _storeQueue = Future.value();
  Future<String>? _refresh;
  oauth.ClientId get _clientId => oauth.ClientId(config.windowsClientId, config.windowsClientSecret);

  Future<void> _save(int epoch, String? value) {
    final write = _storeQueue.then((_) async {
      if (epoch == _epoch) await _store.write(value);
    });
    _storeQueue = write.catchError((Object _) {});
    return write;
  }

  @override
  Future<void> restore() async {
    if (config.windowsClientId.isEmpty) return;
    final epoch = _epoch;
    final saved = await _store.read();
    if (epoch != _epoch || saved == null) return;
    try {
      final json = jsonDecode(saved) as Map<String, dynamic>;
      if (json['clientId'] != config.windowsClientId) return;
      final restored = oauth.AccessCredentials.fromJson(json['credentials'] as Map<String, dynamic>);
      if (restored.refreshToken == null || !restored.scopes.contains(googleDriveFileScope)) return;
      account = GoogleDriveAccount.fromJson(json['account'] as Map<String, dynamic>);
      _credentials = restored;
    } on Object {
      await _save(epoch, null);
    }
  }

  String _savedSession(oauth.AccessCredentials credentials, GoogleDriveAccount user) =>
      jsonEncode({'clientId': config.windowsClientId, 'credentials': credentials.toJson(), 'account': user.toJson()});

  @override
  Future<void> connect() => _connect(music: musicLibraryAccess);

  @override
  Future<void> enableMusicLibrary() => _connect(music: true, expectedAccount: account?.id);

  Future<void> _connect({required bool music, String? expectedAccount}) async {
    if (config.windowsClientId.isEmpty || config.windowsClientSecret.isEmpty) {
      throw const GoogleDriveException('Google Drive is not configured in this build yet.');
    }
    final epoch = ++_epoch;
    final random = Random.secure();
    String nonce() => base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256))).replaceAll('=', '');
    final verifier = nonce();
    final state = nonce();
    final callback = Completer<String>();
    // Observe cancellation immediately, even if it arrives while launching.
    unawaited(callback.future.then<void>((_) {}, onError: (Object _) {}));
    _callback = callback;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    final redirect = 'http://127.0.0.1:${server.port}/oauth2callback';
    final subscription = server.listen((request) async {
      final valid =
          request.method == 'GET' &&
          request.uri.path == '/oauth2callback' &&
          request.uri.queryParameters['state'] == state;
      request.response.headers.contentType = ContentType.html;
      request.response.headers.set('Cache-Control', 'no-store');
      request.response.headers.set('Content-Security-Policy', "default-src 'none'");
      if (!valid || callback.isCompleted) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write('This sign-in request is not valid. Return to Resonance.');
      } else {
        final code = request.uri.queryParameters['code'];
        final denied = request.uri.queryParameters['error'] != null || code == null || code.isEmpty;
        request.response.write(
          '<!doctype html><meta charset="utf-8"><title>Resonance</title><p>${denied ? 'Sign-in cancelled.' : 'Return to Resonance to finish connecting Google Drive.'}</p>',
        );
        if (denied) {
          callback.completeError(const GoogleDriveCancelled());
        } else {
          callback.complete(code);
        }
      }
      try {
        await request.response.close();
      } catch (_) {
        /* Browser may close the callback tab. */
      }
    });
    final client = _clientFactory();
    try {
      if (epoch != _epoch) throw const GoogleDriveCancelled();
      final uri = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
        'client_id': config.windowsClientId,
        'redirect_uri': redirect,
        'response_type': 'code',
        'scope': 'openid profile email $googleDriveFileScope${music ? ' $googleDriveMusicReadScope' : ''}',
        'include_granted_scopes': 'true',
        'access_type': 'offline',
        'prompt': 'consent select_account',
        'state': state,
        'code_challenge': base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', ''),
        'code_challenge_method': 'S256',
      });
      final code = await (() async {
        if (!await _openBrowser(uri)) {
          throw const GoogleDriveException('Could not open Google sign-in in your browser.');
        }
        return callback.future;
      })().timeout(loginTimeout);
      if (epoch != _epoch) throw const GoogleDriveCancelled();
      final credentials = await oauth
          .obtainAccessCredentialsViaCodeExchange(
            client,
            _clientId,
            code,
            redirectUrl: redirect,
            codeVerifier: verifier,
          )
          .timeout(const Duration(seconds: 30));
      if (epoch != _epoch) throw const GoogleDriveCancelled();
      if (!credentials.scopes.contains(googleDriveFileScope) || credentials.refreshToken == null) {
        throw const GoogleDriveException('Google Drive permission was not granted. Please connect again.');
      }
      if (music && !credentials.scopes.contains(googleDriveMusicReadScope)) {
        throw const GoogleDriveException('Allow read-only Drive access to browse your music folders.');
      }
      final response = await client
          .get(
            Uri.https('www.googleapis.com', '/oauth2/v3/userinfo'),
            headers: {'Authorization': 'Bearer ${credentials.accessToken.data}'},
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200 || response.bodyBytes.length > 65536) {
        throw const GoogleDriveException('Could not load your Google account. Please try connecting again.');
      }
      final profile = jsonDecode(response.body) as Map<String, dynamic>;
      final user = GoogleDriveAccount.fromJson({
        'id': profile['sub'],
        'name': profile['name'] ?? profile['email'],
        'photoUrl': profile['picture'],
      });
      if (expectedAccount != null && user.id != expectedAccount) {
        throw const GoogleDriveException('Choose the same Google account to enable music browsing.');
      }
      if (epoch != _epoch) throw const GoogleDriveCancelled();
      await _save(epoch, _savedSession(credentials, user));
      if (epoch != _epoch) throw const GoogleDriveCancelled();
      _credentials = credentials;
      account = user;
    } on TimeoutException {
      throw const GoogleDriveException('Google sign-in timed out. Please try connecting again.');
    } on oauth.ServerRequestFailedException {
      throw const GoogleDriveException('Google could not complete sign-in. Please try connecting again.');
    } finally {
      client.close();
      await subscription.cancel();
      await server.close(force: true);
      if (identical(_server, server)) {
        _server = null;
        _callback = null;
      }
    }
  }

  @override
  Future<String> accessToken({bool refresh = false}) async {
    final credentials = _credentials;
    if (account == null || credentials == null) throw const GoogleDriveException('Connect Google Drive to continue.');
    if (!refresh && credentials.accessToken.expiry.isAfter(DateTime.now().toUtc().add(const Duration(minutes: 1)))) {
      return credentials.accessToken.data;
    }
    return _refresh ??= _refreshToken().whenComplete(() => _refresh = null);
  }

  Future<String> _refreshToken() async {
    final epoch = _epoch;
    final user = account!;
    final client = _clientFactory();
    try {
      final credentials = await oauth
          .refreshCredentials(_clientId, _credentials!, client)
          .timeout(const Duration(seconds: 20));
      if (epoch != _epoch) throw const GoogleDriveCancelled();
      await _save(epoch, _savedSession(credentials, user));
      if (epoch != _epoch) throw const GoogleDriveCancelled();
      _credentials = credentials;
      return credentials.accessToken.data;
    } on oauth.ServerRequestFailedException {
      throw const GoogleDriveException('Reconnect Google Drive to continue.');
    } finally {
      client.close();
    }
  }

  @override
  Future<void> logout() async {
    final epoch = ++_epoch;
    account = null;
    _credentials = null;
    _refresh = null;
    final callback = _callback;
    if (callback != null && !callback.isCompleted) callback.completeError(const GoogleDriveCancelled());
    await _server?.close(force: true);
    await _save(epoch, null);
  }
}
