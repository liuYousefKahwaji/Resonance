import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:resonance/widgets/youtube/android_youtube.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File source, cover;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('resonance-cover-regression-');
    source = await File(p.join(directory.path, 'Song [aaaaaaaaaaa].webm')).writeAsBytes([1, 2, 3]);
    cover = await File('${source.path}.cover').writeAsString('invalid image');
  });
  tearDown(() => directory.delete(recursive: true));

  test('bad optional cover retries audio-only and preserves title and artist', () async {
    final calls = <List<String>>[];
    final output = await convertAndroidYoutubeAudioToMp3(
      source.path,
      title: 'أغنية',
      artist: 'Artist',
      coverPath: cover.path,
      encode: (args) async {
        calls.add(args);
        if (calls.length == 1) return (success: false, diagnostics: 'Invalid image');
        await File(args.last).writeAsBytes([4, 5, 6]);
        return (success: true, diagnostics: '');
      },
    );
    expect(calls.length, 2);
    expect(calls.first, contains(cover.path));
    expect(calls.last, isNot(contains(cover.path)));
    expect(calls.last, containsAll(['-vn', 'title=أغنية', 'artist=Artist']));
    expect(await File(output).readAsBytes(), [4, 5, 6]);
    expect(await source.exists(), isFalse);
    expect(await cover.exists(), isFalse);
  });

  test('failed audio conversion retains the original instead of deleting recoverable audio', () async {
    await expectLater(
      convertAndroidYoutubeAudioToMp3(
        source.path,
        coverPath: cover.path,
        encode: (_) async => (success: false, diagnostics: 'Invalid audio'),
      ),
      throwsA(isA<Exception>()),
    );
    expect(await source.readAsBytes(), [1, 2, 3]);
    expect(await cover.exists(), isTrue);
  });
}
