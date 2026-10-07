import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/models/youtube_artist.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/services/youtube/youtube_artist_service.dart';

const artistId = 'UCQJ-a2IzCJ-gwlHvqvOWGhw';
const artist = YoutubeArtistProfile(id: artistId, name: 'Actual artist');
const seed = YoutubeTrack(
  title: 'Seed',
  artist: 'Ambiguous name',
  artistId: artistId,
  url: 'https://www.youtube.com/watch?v=abcdefghijk',
);

Map<String, dynamic> legacyVideo(String id, {String? title}) => {
  'videoRenderer': {
    'videoId': id,
    'title': {'simpleText': title ?? 'Song $id'},
    'viewCountText': {'simpleText': '1,234 views'},
    'lengthText': {'simpleText': '3:14'},
  },
};
Map<String, dynamic> continuation(String token) => {
  'continuationItemRenderer': {
    'continuationEndpoint': {
      'continuationCommand': {'token': token},
    },
  },
};
Map<String, dynamic> channelData({bool videos = true}) => {
  'metadata': {
    'channelMetadataRenderer': {
      'externalId': artistId,
      'title': artist.name,
      'description': 'Artist bio',
      'avatar': {
        'thumbnails': [
          {'url': 'https://img.example/avatar'},
        ],
      },
    },
  },
  'contents': {
    'twoColumnBrowseResultsRenderer': {
      'tabs': [
        {
          'tabRenderer': {
            'selected': true,
            'title': videos ? 'Videos' : 'Home',
            'content': {
              'richGridRenderer': {
                'header': {
                  'chipBarViewModel': {
                    'chips': [
                      for (final sort in ['Latest', 'Oldest', 'Popular'])
                        {
                          'chipViewModel': {
                            'text': sort,
                            'tapCommand': {
                              'innertubeCommand': {
                                'continuationCommand': {'token': 'sort-$sort'},
                              },
                            },
                          },
                        },
                    ],
                  },
                },
                'contents': [legacyVideo('abcdefghijk'), legacyVideo('lmnopqrstuv'), continuation('next-newest')],
              },
            },
          },
        },
      ],
    },
  },
};
String html({bool videos = true}) =>
    'ytcfg.set({"CSI_SERVICE_NAME": \'youtube\'});ytcfg.set(${jsonEncode({
      'INNERTUBE_CONTEXT': {
        'client': {'clientName': 'WEB', 'clientVersion': 'test-version', 'visitorData': 'guest'},
      },
    })});var ytInitialData = ${jsonEncode(channelData(videos: videos))};';
String browse(String id, {String? next}) => jsonEncode({
  'onResponseReceivedActions': [
    {
      'reloadContinuationItemsCommand': {
        'continuationItems': [legacyVideo(id), if (next != null) continuation(next)],
      },
    },
  ],
});

String topicHtml() {
  final data = channelData(videos: false);
  data['metadata']['channelMetadataRenderer']['title'] = 'Actual artist - Topic';
  return 'ytcfg.set(${jsonEncode({
    'INNERTUBE_CONTEXT': {
      'client': {'clientName': 'WEB', 'clientVersion': 'test-version'},
    },
  })});var ytInitialData = ${jsonEncode(data)};';
}

Map<String, dynamic> topicVideo(int index) {
  final video = legacyVideo('topic${index.toString().padLeft(6, '0')}');
  video['videoRenderer']['viewCountText'] = {'simpleText': '${index * 1000} views'};
  return video;
}

String uploadsHtml() =>
    'ytcfg.set(${jsonEncode({
      'INNERTUBE_CONTEXT': {
        'client': {'clientName': 'WEB', 'clientVersion': 'playlist-context'},
      },
    })});var ytInitialData = ${jsonEncode({
      'contents': {
        'twoColumnBrowseResultsRenderer': {
          'tabs': [
            {
              'tabRenderer': {
                'selected': true,
                'content': {
                  'contents': [topicVideo(0), topicVideo(1), continuation('uploads-next')],
                },
              },
            },
          ],
        },
      },
    })};';

void main() {
  setUp(YoutubeArtistService.clearCache);
  tearDown(YoutubeArtistService.clearCache);

  test('artist identity, actual server sort tokens, continuation and cache stay separate', () async {
    final requests = <({Uri uri, Map<String, dynamic>? body})>[];
    final service = YoutubeArtistService(
      loader: (uri, body) async {
        requests.add((uri: uri, body: body));
        if (body == null) return html();
        return switch (body['continuation']) {
          'sort-Oldest' => browse('oldest00001'),
          'sort-Popular' => browse('popular0001'),
          'next-newest' => browse('nextpage001'),
          _ => throw StateError('Unexpected sort/continuation'),
        };
      },
    );
    final first = await service.fetch(seed, YoutubeArtistSort.newest);
    expect(first.artist.name, 'Actual artist');
    expect(first.artist.avatarUrl, 'https://img.example/avatar');
    expect(first.tracks.map((track) => track.videoId), ['abcdefghijk', 'lmnopqrstuv']);
    expect(first.availableSorts, YoutubeArtistSort.values.toSet());
    expect(requests.single.uri.path, '/channel/$artistId/videos');
    final oldest = await service.fetch(seed, YoutubeArtistSort.oldest);
    expect(oldest.tracks.single.videoId, 'oldest00001');
    final popular = await service.fetch(seed, YoutubeArtistSort.popular);
    expect(popular.tracks.single.videoId, 'popular0001');
    final next = await service.fetch(
      seed,
      YoutubeArtistSort.newest,
      cursor: first.next,
      artist: first.artist,
      availableSorts: first.availableSorts,
    );
    expect(next.tracks.single.videoId, 'nextpage001');
    expect(next.next, isNull);
    expect(requests.skip(1).map((request) => request.body!['continuation']), [
      'sort-Oldest',
      'sort-Popular',
      'next-newest',
    ]);
    expect(requests.last.body!['context']['client']['visitorData'], 'guest');
    expect(identical(await service.fetch(seed, YoutubeArtistSort.popular), popular), isTrue);
    expect(requests, hasLength(4));
    service.cancel();
  });

  test('unidentified stream resolves the real uploader from oEmbed rather than searching its name', () async {
    final requests = <Uri>[];
    final service = YoutubeArtistService(
      loader: (uri, body) async {
        requests.add(uri);
        return uri.path == '/oembed' ? jsonEncode({'author_url': 'https://www.youtube.com/@real_artist'}) : html();
      },
    );
    final page = await service.fetch(
      const YoutubeTrack(
        title: 'Seed',
        artist: 'Same name as another artist',
        url: 'https://www.youtube.com/watch?v=abcdefghijk',
      ),
      YoutubeArtistSort.newest,
    );
    expect(page.artist.id, artistId);
    expect(requests.map((uri) => uri.path), ['/oembed', '/@real_artist/videos']);
    expect(requests.first.queryParameters['url'], 'https://www.youtube.com/watch?v=abcdefghijk');
  });

  test('oEmbed cannot turn artist browsing into an arbitrary URL request', () async {
    var requests = 0;
    final service = YoutubeArtistService(
      loader: (_, __) async {
        requests++;
        return jsonEncode({'author_url': 'https://evil.example/@artist'});
      },
    );
    await expectLater(
      service.fetch(
        const YoutubeTrack(title: 'Seed', artist: 'Artist', url: 'https://www.youtube.com/watch?v=abcdefghijk'),
        YoutubeArtistSort.newest,
      ),
      throwsA(isA<YoutubeArtistException>()),
    );
    expect(requests, 1);
  });

  test('Home recommendations are not mistaken for a channel song catalog', () async {
    final service = YoutubeArtistService(loader: (_, __) async => html(videos: false));
    await expectLater(service.fetch(seed, YoutubeArtistSort.newest), throwsA(isA<YoutubeArtistException>()));
  });

  test('Topic uploads are lazy; oldest and popular sort the complete catalog and page locally', () async {
    final requests = <({Uri uri, Map<String, dynamic>? body})>[];
    final service = YoutubeArtistService(
      loader: (uri, body) async {
        requests.add((uri: uri, body: body));
        if (body == null) return uri.path == '/playlist' ? uploadsHtml() : topicHtml();
        expect(body['continuation'], 'uploads-next');
        expect(body['context']['client']['clientVersion'], 'playlist-context');
        return jsonEncode({
          'onResponseReceivedActions': [
            {
              'appendContinuationItemsAction': {
                'continuationItems': [for (var i = 2; i < 37; i++) topicVideo(i)],
              },
            },
          ],
        });
      },
    );
    final newest = await service.fetch(seed, YoutubeArtistSort.newest);
    expect(newest.artist.name, 'Actual artist');
    expect(newest.tracks.map((track) => track.videoId), ['topic000000', 'topic000001']);
    expect(newest.availableSorts, YoutubeArtistSort.values.toSet());
    expect(requests, hasLength(2));
    expect(requests.last.uri.queryParameters['list'], 'UU${artistId.substring(2)}');
    final oldest = await service.fetch(seed, YoutubeArtistSort.oldest);
    expect(oldest.tracks, hasLength(30));
    expect(oldest.tracks.first.videoId, 'topic000036');
    expect(oldest.tracks.last.videoId, 'topic000007');
    final more = await service.fetch(seed, YoutubeArtistSort.oldest, cursor: oldest.next, artist: oldest.artist);
    expect(more.tracks.map((track) => track.videoId), [
      for (var i = 6; i >= 0; i--) 'topic${i.toString().padLeft(6, '0')}',
    ]);
    expect(more.next, isNull);
    final popular = await service.fetch(seed, YoutubeArtistSort.popular);
    expect(popular.tracks.first.viewCount, 36000);
    expect(requests, hasLength(3));
    service.cancel();
  });

  test('repeated remote continuation fails instead of endlessly loading the same page', () async {
    final service = YoutubeArtistService(
      loader: (_, body) async => body == null ? html() : browse('abcdefghijk', next: 'next-newest'),
    );
    final first = await service.fetch(seed, YoutubeArtistSort.newest);
    await expectLater(
      service.fetch(seed, YoutubeArtistSort.newest, cursor: first.next, artist: first.artist),
      throwsA(isA<YoutubeArtistException>()),
    );
  });

  test('cancelled response cannot enter the shared artist cache', () async {
    final pending = Completer<String>();
    final service = YoutubeArtistService(loader: (_, __) => pending.future);
    final request = service.fetch(seed, YoutubeArtistSort.newest);
    final rejected = expectLater(request, throwsA(isA<YoutubeArtistException>()));
    service.cancel();
    pending.complete(html());
    await rejected;
    var loads = 0;
    final next = YoutubeArtistService(
      loader: (_, __) async {
        loads++;
        return html();
      },
    );
    await next.fetch(seed, YoutubeArtistSort.newest);
    expect(loads, 1);
  });

  test('modern cards, legacy videos, counts, duration and duplicate IDs decode safely', () {
    final page = YoutubeArtistService.decodePage(
      {
        'contents': [
          legacyVideo('abcdefghijk'),
          legacyVideo('abcdefghijk'),
          {
            'lockupViewModel': {
              'contentId': 'modern00001',
              'contentType': 'LOCKUP_CONTENT_TYPE_VIDEO',
              'metadata': {
                'lockupMetadataViewModel': {
                  'title': {'content': 'Modern song'},
                  'metadata': {
                    'contentMetadataViewModel': {
                      'metadataRows': [
                        {
                          'metadataParts': [
                            {
                              'text': {'content': '1.2M'},
                              'accessibilityLabel': '1.2 million views',
                            },
                            {
                              'text': {'content': '4y ago'},
                              'accessibilityLabel': '4 years ago',
                            },
                          ],
                        },
                      ],
                    },
                  },
                },
              },
              'contentImage': {
                'thumbnailViewModel': {
                  'image': {
                    'sources': [
                      {'url': 'https://img.example/modern'},
                    ],
                  },
                  'overlays': [
                    {
                      'thumbnailBottomOverlayViewModel': {
                        'badges': [
                          {
                            'thumbnailBadgeViewModel': {'text': '1:02:03'},
                          },
                        ],
                      },
                    },
                  ],
                },
              },
            },
          },
          {
            'lockupViewModel': {'contentId': 'playlist000', 'contentType': 'LOCKUP_CONTENT_TYPE_PLAYLIST'},
          },
        ],
      },
      artist,
      {},
    );
    expect(page.tracks, hasLength(2));
    expect(page.tracks.first.viewCount, 1234);
    expect(page.tracks.first.durationSeconds, 194);
    expect(page.tracks.last.viewCount, 1200000);
    expect(page.tracks.last.likeCount, isNull);
    expect(page.tracks.last.durationSeconds, 3723);
    expect(page.tracks.last.artistId, artistId);
    final cached = YoutubeTrack.fromCacheJson(page.tracks.last.toJson());
    expect(cached.copyWith(likeCount: 42).artistId, artistId);
  });
}
