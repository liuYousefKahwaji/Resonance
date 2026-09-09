import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/audio/audio_service.dart';

void main() {
  test('system default alone is not treated as a physical output', () {
    expect(hasUsableOutputDeviceNames(const ['auto']), isFalse);
    expect(hasUsableOutputDeviceNames(const ['', 'auto']), isFalse);
  });

  test('a named output is treated as usable', () {
    expect(hasUsableOutputDeviceNames(const ['auto', 'wasapi/{0.0.0.00000000}.{abc}']), isTrue);
  });

  test('output device labels prefer the friendly description', () {
    expect(const PlaybackOutputDevice.systemDefault().label, 'System default');
    expect(const PlaybackOutputDevice(name: 'wasapi/device', description: 'Headphones').label, 'Headphones');
  });
}
