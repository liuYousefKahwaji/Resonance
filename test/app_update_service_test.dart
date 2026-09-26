import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/app_update_service.dart';

void main() {
  test('release versions accept both tag styles and compare numerically', () {
    expect(AppVersion.parse('v3.4.2')!.compareTo(AppVersion.parse('3.4.1')!), greaterThan(0));
    expect(AppVersion.parse('v.3.4.2')!.compareTo(AppVersion.parse('3.4.2')!), 0);
    expect(AppVersion.parse('3.10.0')!.compareTo(AppVersion.parse('v3.9.9')!), greaterThan(0));
    expect(AppVersion.parse('v3.4.2-beta'), isNull);
    expect(AppVersion.parse('other3.4.2'), isNull);
  });

  test('only a higher release with a verified platform asset is offered', () {
    final release = <String, dynamic>{
      'tag_name': 'v.3.4.2',
      'body': 'What changed',
      'assets': [
        {
          'name': 'resonance-v3.4.2.apk',
          'browser_download_url':
              'https://github.com/liuYousefKahwaji/Resonance/releases/download/v.3.4.2/resonance.apk',
          'digest': 'sha256:${'a' * 64}',
          'size': 500,
        },
        {
          'name': 'resonance-v3.4.2-windows.zip',
          'browser_download_url':
              'https://github.com/liuYousefKahwaji/Resonance/releases/download/v.3.4.2/resonance.zip',
          'digest': 'sha256:${'b' * 64}',
          'size': 900,
        },
      ],
    };
    final installed = AppVersion.parse('3.4.1')!;
    expect(AvailableUpdate.fromReleaseJson(release, installed, android: true)?.asset.name, endsWith('.apk'));
    expect(AvailableUpdate.fromReleaseJson(release, installed, android: false)?.asset.name, endsWith('.zip'));
    expect(AvailableUpdate.fromReleaseJson(release, AppVersion.parse('3.4.2')!, android: true), isNull);
    expect(AvailableUpdate.fromReleaseJson({...release, 'tag_name': '3.4.0'}, installed, android: true), isNull);
    expect(AvailableUpdate.fromReleaseJson({...release, 'draft': true}, installed, android: true), isNull);
    expect(
      AvailableUpdate.fromReleaseJson(
        {
          ...release,
          'assets': [
            {...(release['assets'] as List).first, 'name': 'resonance-v3.4.1.apk'},
          ],
        },
        installed,
        android: true,
      ),
      isNull,
    );
    final assets = (release['assets'] as List).cast<Map<String, dynamic>>();
    expect(
      AvailableUpdate.fromReleaseJson(
        {
          ...release,
          'assets': [
            {...assets.first, 'digest': 'sha256:bad'},
          ],
        },
        installed,
        android: true,
      ),
      isNull,
    );
  });
}
