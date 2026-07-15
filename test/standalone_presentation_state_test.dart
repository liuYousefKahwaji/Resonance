import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/audio/audio_service.dart';

void main() {
  test('slow load completion reflects the current standalone presentation', () {
    const presentationRequestedAtLoadStart = true;
    const presentationAfterRouteWasPopped = false;

    expect(standalonePresentationExtras(presentationRequestedAtLoadStart), {'resonanceStandalone': true});
    expect(standalonePresentationExtras(presentationAfterRouteWasPopped), isNull);
  });

  test('restored external playback returns to standalone', () {
    expect(restoredTrackIsExternal(persistedValue: true, trackIsInPlaylist: false), isTrue);
    expect(restoredTrackIsExternal(persistedValue: false, trackIsInPlaylist: false), isFalse);
    expect(restoredTrackIsExternal(persistedValue: null, trackIsInPlaylist: false), isTrue);
    expect(restoredTrackIsExternal(persistedValue: null, trackIsInPlaylist: true), isFalse);
  });
}
