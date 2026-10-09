import 'dart:async';
import 'dart:convert';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'track_source_repository.dart';

/// Local aggregates by calendar day and canonical track. Never controls playback.
class ListeningStatistics extends ChangeNotifier {
  ListeningStatistics({DateTime Function()? clock}) : clock = clock ?? DateTime.now;
  static final instance = ListeningStatistics();
  static const storageKey = 'listening_statistics_v1';
  final DateTime Function() clock;
  Map<String, dynamic> days = {};
  Map<String, String> _sources = {};
  bool enabled = true;
  DateTime? startedAt;
  Timer? _flushTimer;
  Future<void> _writeTail = Future.value();
  StreamSubscription<Object?>? _subscription;
  DateTime? _lastTime;
  Duration? _lastPosition;
  String? _identity;
  bool _wasPlaying = false, _qualified = false;
  int _sessionMs = 0;
  Future<void> initialize() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    onSessionEnded();
    final prefs = await SharedPreferences.getInstance();
    enabled = prefs.getBool('listening_statistics_enabled') ?? true;
    try {
      final value = jsonDecode(prefs.getString(storageKey) ?? '{}') as Map;
      validateData(value);
      days = Map<String, dynamic>.from(value['days'] as Map? ?? {});
      startedAt = DateTime.tryParse('${value['startedAt'] ?? ''}');
    } catch (_) {
      days = {};
    }
    startedAt ??= clock();
    _sources = await const TrackSourceRepository().youtubeIdsByLocalPath();
    _subscription ??= FileService.mutations.listen((_) async {
      _sources = await const TrackSourceRepository().youtubeIdsByLocalPath();
    });
    notifyListeners();
  }

  static void validateData(Map value) {
    final days = value['days'];
    if (days == null) return;
    if (days is! Map) throw const FormatException('Invalid listening days');
    for (final day in days.entries) {
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch('${day.key}') || day.value is! Map) {
        throw const FormatException('Invalid listening day');
      }
      for (final raw in (day.value as Map).values) {
        if (raw is! Map || raw['title'] is! String || raw['artist'] is! String) {
          throw const FormatException('Invalid listening track');
        }
        for (final field in ['ms', 'plays', 'localMs', 'streamMs']) {
          if (raw[field] is! num || !(raw[field] as num).isFinite || (raw[field] as num) < 0) {
            throw const FormatException('Invalid listening totals');
          }
        }
        for (final field in ['hours', 'playlists']) {
          if (raw[field] is! Map ||
              !(raw[field] as Map).values.every((value) => value is num && value.isFinite && value >= 0)) {
            throw const FormatException('Invalid listening breakdown');
          }
        }
      }
    }
  }

  Future<void> setEnabled(bool value) async {
    enabled = value;
    onSessionEnded();
    await (await SharedPreferences.getInstance()).setBool('listening_statistics_enabled', value);
    notifyListeners();
  }

  void onSessionEnded() {
    _lastTime = null;
    _lastPosition = null;
    _identity = null;
    _wasPlaying = false;
    _qualified = false;
    _sessionMs = 0;
  }

  void observe({
    required MediaItem? item,
    required bool playing,
    required Duration position,
    double speed = 1,
    int? playlist,
    bool loading = false,
  }) {
    final now = clock();
    final id = item == null ? null : FileService().favoriteIdentity(item.id, sourceIds: _sources);
    if (id != _identity) onSessionEnded();
    final elapsed = _lastTime == null ? Duration.zero : now.difference(_lastTime!);
    final advance = _lastPosition == null ? Duration.zero : position - _lastPosition!;
    final qualifies =
        enabled &&
        !loading &&
        item != null &&
        id != null &&
        _wasPlaying &&
        playing &&
        elapsed > Duration.zero &&
        elapsed <= const Duration(seconds: 10) &&
        advance > Duration.zero &&
        advance.inMilliseconds <= elapsed.inMilliseconds * speed + 750;
    _identity = id;
    _lastTime = now;
    _lastPosition = position;
    _wasPlaying = playing && !loading;
    if (!qualifies) return;
    // Count wall time; fast playback and seeks must not inflate listening time.
    final milliseconds = elapsed.inMilliseconds;
    _sessionMs += milliseconds;
    final day = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final bucket = days.putIfAbsent(day, () => <String, dynamic>{}) as Map;
    final track =
        bucket.putIfAbsent(
              id,
              () => <String, dynamic>{
                'title': item.title,
                'artist': item.artist ?? 'Unknown artist',
                'path': item.id,
                'artwork': item.artUri?.toString(),
                'ms': 0,
                'plays': 0,
                'localMs': 0,
                'streamMs': 0,
                'hours': <String, dynamic>{},
                'playlists': <String, dynamic>{},
              },
            )
            as Map;
    track['title'] = item.title;
    track['artist'] = item.artist ?? 'Unknown artist';
    track['path'] = item.id;
    track['artwork'] = item.artUri?.toString();
    track['ms'] = (track['ms'] as num).toInt() + milliseconds;
    track['lastPlayed'] = now.toIso8601String();
    final source = item.id.startsWith('http') ? 'streamMs' : 'localMs';
    track[source] = (track[source] as num? ?? 0).toInt() + milliseconds;
    final hours = track['hours'] as Map;
    hours['${now.hour}'] = (hours['${now.hour}'] as num? ?? 0).toInt() + milliseconds;
    if (playlist != null) {
      final playlists = track['playlists'] as Map;
      playlists['$playlist'] = (playlists['$playlist'] as num? ?? 0).toInt() + milliseconds;
    }
    final half = (item.duration?.inMilliseconds ?? 60000) ~/ 2;
    final threshold = half.clamp(1000, 30000);
    if (!_qualified && _sessionMs >= threshold) {
      _qualified = true;
      track['plays'] = (track['plays'] as num).toInt() + 1;
    }
    _flushTimer ??= Timer(const Duration(seconds: 15), () {
      _flushTimer = null;
      unawaited(flush());
    });
  }

  Map<String, Map<String, dynamic>> aggregate({String? prefix}) {
    final result = <String, Map<String, dynamic>>{};
    for (final day in days.entries) {
      if (prefix != null && !day.key.startsWith(prefix)) continue;
      for (final entry in (day.value as Map).entries) {
        final raw = Map<String, dynamic>.from(entry.value as Map);
        final previous = result[entry.key] ?? {};
        result[entry.key as String] = {
          ...raw,
          for (final field in ['ms', 'plays', 'localMs', 'streamMs'])
            field: (previous[field] as num? ?? 0) + (raw[field] as num? ?? 0),
          for (final field in ['hours', 'playlists'])
            field: {
              for (final key in {...(previous[field] as Map? ?? {}).keys, ...(raw[field] as Map? ?? {}).keys})
                key: ((previous[field] as Map?)?[key] as num? ?? 0) + ((raw[field] as Map?)?[key] as num? ?? 0),
            },
          'lastPlayed': '${previous['lastPlayed'] ?? ''}'.compareTo('${raw['lastPlayed'] ?? ''}') > 0
              ? previous['lastPlayed']
              : raw['lastPlayed'],
        };
      }
    }
    return result;
  }

  Future<void> flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    final snapshot = jsonEncode({'startedAt': startedAt?.toIso8601String(), 'days': days});
    _writeTail = _writeTail.catchError((_) {}).then((_) async {
      await (await SharedPreferences.getInstance()).setString(storageKey, snapshot);
    });
    notifyListeners();
    return _writeTail;
  }

  Future<void> clear() async {
    days = {};
    startedAt = clock();
    onSessionEnded();
    await flush();
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    _subscription?.cancel();
    super.dispose();
  }
}
