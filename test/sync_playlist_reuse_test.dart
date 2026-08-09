import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/sync/sync_session_service.dart';

void main() {
  test('host reuses the canonical Sync playlist before numbered copies', () {
    expect(reusableHostSyncPlaylist({1: 'Playlist 1', 4: 'Sync (2)', 7: 'Sync', 9: 'Sync - Phone'}), 7);
  });

  test('host can reuse a prior numbered Sync playlist but not a peer playlist', () {
    expect(reusableHostSyncPlaylist({1: 'Playlist 1', 3: 'Sync - Pixel', 5: 'sync (3)'}), 5);
    expect(reusableHostSyncPlaylist({1: 'Playlist 1', 3: 'Sync - Pixel'}), isNull);
  });
}
