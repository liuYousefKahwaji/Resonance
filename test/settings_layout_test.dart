import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/screens/settings/settings_screen.dart';

void main() {
  test('slider settings stack their controls at narrow Android widths', () {
    expect(settingsTileShouldStackTrailing(360, true), isTrue);
    expect(settingsTileShouldStackTrailing(439, true), isTrue);
    expect(settingsTileShouldStackTrailing(440, true), isFalse);
    expect(settingsTileShouldStackTrailing(320, false), isFalse);
  });
}
