import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/services/track_links.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'package:resonance/models/track_source_record.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('canonical links strip playback parameters and preserve exact video identity', () async {
    final links = await TrackLinks.resolve('https://youtu.be/abcdefghijk?si=tracking&t=80');
    expect(links?.source.toString(), 'https://www.youtube.com/watch?v=abcdefghijk');
    expect(links?.youtubeMusic.toString(), 'https://music.youtube.com/watch?v=abcdefghijk');
  });
  test('download source is read from the saved mapping without extraction', () async {
    const path = r'C:\Music\Example.webm';
    await const TrackSourceRepository().saveSource(
      localPath: path,
      youtubeVideoId: 'abcdefghijk',
      method: TrackSourceMethod.downloadedByResonance,
    );
    expect((await TrackLinks.resolve(path))?.youtubeId, 'abcdefghijk');
    expect(await TrackLinks.resolve(r'C:\Music\Unmapped.mp3'), isNull);
  });
  test('Drive sharing omits internal account identity; arbitrary media URLs cannot be shared', () async {
    final links = await TrackLinks.resolve(
      'https://drive.google.com/file/d/file123/view?resonanceAccount=private-account',
    );
    expect(links?.source.toString(), 'https://drive.google.com/file/d/file123/view');
    expect(links?.youtubeMusic, isNull);
    expect(await TrackLinks.resolve('https://cdn.test/media?token=secret'), isNull);
  });
}
