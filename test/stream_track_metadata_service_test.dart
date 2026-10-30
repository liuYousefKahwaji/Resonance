import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'package:resonance/services/youtube/stream_track_metadata_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await MetadataCacheService.clear();
  });
  tearDown(MetadataCacheService.flush);
  test('visible rows share requests, queued disposed rows are skipped, and concurrency is bounded', () async {
    final completions = <String, Completer<YoutubeTrack?>>{};
    var active = 0, peak = 0;
    final service = StreamTrackMetadataService(
      concurrency: 2,
      fetch: (link) async {
        active++;
        if (active > peak) peak = active;
        final completion = Completer<YoutubeTrack?>();
        completions[link.videoId!] = completion;
        final result = await completion.future;
        active--;
        return result;
      },
    );
    var thirdVisible = true;
    final one = service.load(TrackSourceRepository.canonicalUrlFor('aaaaaaaaaaa'), isCurrent: () => true);
    final duplicate = service.load(TrackSourceRepository.canonicalUrlFor('aaaaaaaaaaa'), isCurrent: () => true);
    final two = service.load(TrackSourceRepository.canonicalUrlFor('bbbbbbbbbbb'), isCurrent: () => true);
    final abandoned = service.load(TrackSourceRepository.canonicalUrlFor('ccccccccccc'), isCurrent: () => thirdVisible);
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
      if (completions.length == 2) break;
    }
    expect(completions.keys, ['aaaaaaaaaaa', 'bbbbbbbbbbb']);
    thirdVisible = false;
    for (final entry in completions.entries) {
      entry.value.complete(
        YoutubeTrack(title: entry.key, artist: 'Artist', url: TrackSourceRepository.canonicalUrlFor(entry.key)),
      );
    }
    final result = await Future.wait([one, duplicate, two, abandoned]);
    expect(result[0]!.title, 'aaaaaaaaaaa');
    expect(result[1]!.title, 'aaaaaaaaaaa');
    expect(result[3], isNull);
    expect(completions.length, 2);
    expect(peak, 2);
  });

  test('failed metadata is briefly cached and cannot remove a playable stream', () async {
    var requests = 0;
    final service = StreamTrackMetadataService(
      fetch: (_) async {
        requests++;
        return null;
      },
    );
    const url = 'https://www.youtube.com/watch?v=aaaaaaaaaaa';
    expect(await service.load(url, isCurrent: () => true), isNull);
    expect(await service.load(url, isCurrent: () => true), isNull);
    expect(requests, 1);
  });

  test('leaving a large list discards queued metadata without recursive draining', () async {
    final response = Completer<YoutubeTrack?>();
    final started = Completer<void>();
    var requests = 0, visible = true;
    final service = StreamTrackMetadataService(
      concurrency: 1,
      fetch: (_) {
        requests++;
        started.complete();
        return response.future;
      },
    );
    final active = service.load('https://www.youtube.com/watch?v=aaaaaaaaaaa', isCurrent: () => true);
    await started.future;
    final pending = [
      for (var i = 0; i < 2000; i++)
        service.load(
          TrackSourceRepository.canonicalUrlFor('m${i.toString().padLeft(10, '0')}'),
          isCurrent: () => visible,
        ),
    ];
    await Future<void>.delayed(Duration.zero);
    visible = false;
    response.complete(null);
    await Future.wait([active, ...pending]);
    expect(requests, 1);
  });

  test('late optional metadata cannot overwrite a newer track name', () async {
    final response = Completer<YoutubeTrack?>();
    final started = Completer<void>();
    final service = StreamTrackMetadataService(
      fetch: (_) {
        started.complete();
        return response.future;
      },
    );
    const url = 'https://www.youtube.com/watch?v=aaaaaaaaaaa';
    final loading = service.load(url, isCurrent: () => true);
    await started.future;
    await MetadataCacheService.set(url, 'New title', 'New artist');
    response.complete(YoutubeTrack(title: 'Old title', artist: 'Old artist', url: url));
    expect((await loading)!.title, 'New title');
  });
}
