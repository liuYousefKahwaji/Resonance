import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/companion/companion_protocol.dart';

void main() {
  test('Discord actions remain additive semantic protocol v1 commands', () {
    expect(companionProtocolVersion, 1);
    expect(companionToggleMuteCommand, 'toggle_mute');
    expect(companionToggleDeafenCommand, 'toggle_deafen');
  });

  test('pairing codes round-trip endpoint and temporary token', () {
    const source = CompanionPairingInfo(
      host: '192.168.1.25',
      port: 45873,
      pairingToken: 'abcdefghijklmnopqrstuvwxyz123456',
      pcName: 'Studio PC',
    );

    final decoded = CompanionPairingInfo.parse(source.encode());
    expect(decoded.host, source.host);
    expect(decoded.port, source.port);
    expect(decoded.pairingToken, source.pairingToken);
    expect(decoded.pcName, source.pcName);
  });

  test('pairing parser rejects unrelated and incomplete QR values', () {
    expect(() => CompanionPairingInfo.parse('https://example.com'), throwsFormatException);
    expect(
      () => CompanionPairingInfo.parse('resonance://companion?v=1&host=192.168.1.2&port=45873'),
      throwsFormatException,
    );
  });

  test('playback snapshots decode queue and effect support', () {
    final snapshot = CompanionPlaybackSnapshot.fromJson({
      'pcName': 'PC',
      'playing': true,
      'loop': 'one',
      'shuffle': true,
      'volume': 1.4,
      'seekStepSeconds': 9,
      'speed': 1.25,
      'pitch': 0.9,
      'bass': 0.7,
      'bassSupported': true,
      'equalizerEnabled': true,
      'equalizerPreset': 'rock',
      'equalizerGainsDb': [4, 2, -2, 3, 4],
      'equalizerCustomGainsDb': [6, 3, 0, -1, -2],
      'equalizerSupported': true,
      'queue': [
        {'id': 'current', 'title': 'Current', 'artist': 'Artist', 'current': true},
        {'id': 'next', 'title': 'Next', 'artist': 'Artist', 'current': false},
      ],
    });

    expect(snapshot.currentTrack?.id, 'current');
    expect(snapshot.queue.map((track) => track.id), ['current', 'next']);
    expect(snapshot.volume, 1.4);
    expect(snapshot.seekStepSeconds, 9);
    expect(snapshot.bassSupported, isTrue);
    expect(snapshot.equalizerPreset, 'rock');
    expect(snapshot.equalizerGainsDb, [4, 2, -2, 3, 4]);
    expect(snapshot.equalizerCustomGainsDb, [6, 3, 0, -1, -2]);
    expect(snapshot.equalizerSupported, isTrue);
  });

  test('playback snapshot clamps remote volume and Windows seek step', () {
    final snapshot = CompanionPlaybackSnapshot.fromJson({'volume': 3, 'seekStepSeconds': 99});

    expect(snapshot.volume, 2);
    expect(snapshot.seekStepSeconds, 15);
  });
}
