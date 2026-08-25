import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/youtube/windows_browser_detector.dart';
import 'package:resonance/services/youtube/windows_ytdlp_runner.dart';

void main() {
  test('Windows runner builds common and authenticated arguments without a shell', () {
    final runner = WindowsYtdlpRunner(executableDirectory: r'C:\Resonance\bin');
    final args = runner.buildArguments(['--dump-json', 'https://example.test'], overrideBrowserId: 'firefox');
    expect(args, containsAllInOrder(['--js-runtimes', r'deno:C:\Resonance\bin\deno.exe', '--force-ipv4']));
    expect(args, containsAllInOrder(['--cookies-from-browser', 'firefox']));
  });

  test('browser identifiers are mapped from ProgIDs and executables', () {
    expect(WindowsBrowserDetector.browserIdForProgId('MSEdgeHTM'), 'edge');
    expect(WindowsBrowserDetector.browserIdForProgId('FirefoxURL-308046B0AF4A39CB'), 'firefox');
    expect(WindowsBrowserDetector.browserIdForProgId('BraveHTML'), 'brave');
    expect(
      WindowsBrowserDetector.browserIdForExecutable(r'C:\Program Files\Google\Chrome\Application\chrome.exe'),
      'chrome',
    );
    expect(
      WindowsBrowserDetector.browserIdForCommand(
        r'"C:\Program Files\Vivaldi\Application\vivaldi.exe" --single-argument %1',
      ),
      'vivaldi',
    );
    expect(WindowsBrowserDetector.browserIdForProgId('Unknown.Browser'), isNull);
  });

  test('browser profile resolution helpers retain only safe concrete profiles', () {
    expect(WindowsBrowserDetector.lastUsedChromiumProfile('{"profile":{"last_used":"Profile 3"}}'), 'Profile 3');
    expect(WindowsBrowserDetector.lastUsedChromiumProfile('{"profile":{"last_used":"../Guest"}}'), isNull);
    expect(
      WindowsBrowserDetector.defaultFirefoxProfile('''
[Profile0]
Name=default-release
IsRelative=1
Path=Profiles/abc.default-release
Default=1
'''),
      'abc.default-release',
    );
    expect(WindowsBrowserDetector.baseBrowserId('chrome:Profile 3'), 'chrome');
    expect(WindowsBrowserDetector.browserProfile('chrome:Profile 3'), 'Profile 3');
  });
}
