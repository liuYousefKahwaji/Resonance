// lib/core/audio/audio_service.dart

import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:audio_service/audio_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:resonance/core/audio/audio_envelope_analyzer.dart';
import 'package:resonance/core/audio/loudness_normalization.dart';
import 'package:resonance/core/audio/playback_preferences.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/models/playback_queue_snapshot.dart';
import 'package:resonance/services/discord_presence_service.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:metadata_god/metadata_god.dart';

@immutable
class PlaybackVisualState {
  final String? trackId;
  final bool playing;
  final bool loading;

  const PlaybackVisualState({this.trackId, this.playing = false, this.loading = false});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaybackVisualState && trackId == other.trackId && playing == other.playing && loading == other.loading;

  @override
  int get hashCode => Object.hash(trackId, playing, loading);
}

@visibleForTesting
double fallbackVisualizerAmplitude(String trackId, Duration position) {
  final seed = trackId.codeUnits.fold<int>(17, (value, unit) => (value * 31 + unit) & 0x7fffffff);
  final seconds = position.inMilliseconds / 1000.0;
  final primary = math.sin(seconds * (2.0 + (seed % 7) * 0.11) + (seed % 19));
  final secondary = math.sin(seconds * (3.7 + (seed % 5) * 0.09) + (seed % 13) * 0.4);
  return (0.22 + primary.abs() * 0.34 + secondary.abs() * 0.18).clamp(0.0, 0.82);
}

/// Loading and buffering are useful feedback for network streams, but local
/// files must always feel immediately available in the UI. The platform audio
/// backends may briefly report either state while swapping local sources, so
/// normalize those implementation details before publishing playback state.
AudioProcessingState visibleProcessingState(AudioProcessingState state, {required bool isStream}) {
  if (!isStream && (state == AudioProcessingState.loading || state == AudioProcessingState.buffering)) {
    return AudioProcessingState.ready;
  }
  return state;
}

@visibleForTesting
bool playbackPositionAdvanced(Duration initial, Duration current) =>
    current - initial >= const Duration(milliseconds: 250);

@visibleForTesting
int nextPlayablePlaylistIndex({
  required List<String> playlist,
  required int currentIndex,
  required bool allowWrap,
  required bool Function(String path) hasFailed,
}) {
  if (currentIndex < 0 || currentIndex >= playlist.length) return -1;
  for (var offset = 1; offset < playlist.length; offset++) {
    final candidate = currentIndex + offset;
    if (!allowWrap && candidate >= playlist.length) return -1;
    final index = candidate % playlist.length;
    if (!hasFailed(playlist[index])) return index;
  }
  return -1;
}

enum TrackTransitionDirection { none, next, previous }

@visibleForTesting
Map<String, dynamic>? standalonePresentationExtras(bool enabled) =>
    enabled ? const <String, dynamic>{'resonanceStandalone': true} : null;

@visibleForTesting
bool restoredTrackIsExternal({required bool? persistedValue, required bool trackIsInPlaylist}) =>
    persistedValue ?? !trackIsInPlaylist;

/// Builds the complete libmpv audio-filter chain.
///
/// media_kit implements independent Windows speed and pitch with scaletempo.
/// Replacing `af` with only an EQ filter silently removes scaletempo, coupling
/// speed and pitch even at 0% bass. The audio-only Windows libmpv build exposes
/// FFmpeg's equalizer but not its automatic sample-format converter, so the
/// combined `lavfi` graph and native `format` filters around it are required.
@visibleForTesting
String buildWindowsAudioFilter(PlaybackAdjustments adjustments) {
  final tempoScale = (adjustments.speed / adjustments.pitch).clamp(0.25, 4.0).toStringAsFixed(8);
  final pitchCorrection = 'scaletempo:scale=$tempoScale';
  if (!adjustments.equalizer.isActive) return pitchCorrection;
  final filters = List<String>.generate(equalizerBandFrequencies.length, (index) {
    final frequency = equalizerBandFrequencies[index].toStringAsFixed(0);
    final gain = adjustments.equalizer.gainsDb[index].toStringAsFixed(2);
    return 'equalizer=f=$frequency:t=q:w=0.70:g=$gain';
  }).join(',');
  return '$pitchCorrection,format=format=floatp,'
      'lavfi=[$filters],'
      'format=format=float';
}

@visibleForTesting
double equalizerOutputHeadroomMultiplier(EqualizerSettings settings, {required bool effectApplied}) =>
    effectApplied ? settings.automaticPreampMultiplier : 1.0;

@immutable
class TrackTransitionState {
  final int revision;
  final TrackTransitionDirection direction;

  const TrackTransitionState({this.revision = 0, this.direction = TrackTransitionDirection.none});
}

class _AutomaticTrackTarget {
  final String path;
  final String title;
  final String artist;
  final bool standalone;
  final int? playlistNumber;
  final int? playlistIndex;

  const _AutomaticTrackTarget({
    required this.path,
    required this.title,
    required this.artist,
    required this.standalone,
    this.playlistNumber,
    this.playlistIndex,
  });
}

class PlayerHandler extends BaseAudioHandler with QueueHandler, SeekHandler, WidgetsBindingObserver {
  late AudioPlayer _player;
  late AndroidLoudnessEnhancer _loudnessEnhancer;
  late AndroidEqualizer _androidEqualizer;
  mk.Player? _windowsPlayer;

  double savedVolume = 1.0;

  final ValueNotifier<double> volumeNotifier = ValueNotifier<double>(1.0);
  final ValueNotifier<double> speedNotifier = ValueNotifier<double>(1.0);
  final ValueNotifier<double> pitchNotifier = ValueNotifier<double>(1.0);
  final ValueNotifier<EqualizerSettings> equalizerNotifier = ValueNotifier<EqualizerSettings>(EqualizerSettings.flat);
  final ValueNotifier<bool> equalizerSupportedNotifier = ValueNotifier<bool>(Platform.isAndroid || Platform.isWindows);
  final ValueNotifier<bool> crossfadeEnabledNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<double> crossfadeDurationSecondsNotifier = ValueNotifier<double>(3.0);
  final ValueNotifier<bool> resumeLongTracksNotifier = ValueNotifier<bool>(true);
  final ValueNotifier<bool> volumeNormalizationEnabledNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<LoudnessScanProgress> loudnessScanProgressNotifier = ValueNotifier<LoudnessScanProgress>(
    const LoudnessScanProgress(),
  );
  final ValueNotifier<PlaybackSettingsScope> playbackSettingsScopeNotifier = ValueNotifier<PlaybackSettingsScope>(
    PlaybackSettingsScope.global,
  );
  final ValueNotifier<int> seekStepNotifier = ValueNotifier<int>(5);
  LoopMode currentLoopMode = LoopMode.all;
  bool isShuffle = false;
  List<String> shuffledList = [];
  final ValueNotifier<int> playbackModeRevision = ValueNotifier<int>(0);
  final ValueNotifier<bool> standaloneModeNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<PlaybackVisualState> playbackVisualNotifier = ValueNotifier<PlaybackVisualState>(
    const PlaybackVisualState(),
  );
  final ValueNotifier<TrackTransitionState> trackTransitionNotifier = ValueNotifier<TrackTransitionState>(
    const TrackTransitionState(),
  );
  final ValueNotifier<bool> uiVisibleNotifier = ValueNotifier<bool>(true);
  MediaItem? _pendingRestoredTrack;
  final Map<String, Uri?> _artUriCache = {};
  final AudioEnvelopeAnalyzer _envelopeAnalyzer = AudioEnvelopeAnalyzer();
  AudioEnvelope? _audioEnvelope;
  String? _audioEnvelopeTrackId;

  int? _standalonePlaylistNumber;
  int? _standalonePlaylistIndex;

  int _loadGeneration = 0;
  int? _activeTrackLoadGeneration;
  int _seekGeneration = 0;
  int? _activeSeekGeneration;
  Future<void> _seekOperationQueue = Future<void>.value();
  int _crossfadeGeneration = 0;
  bool _crossfadeInProgress = false;
  bool _equalizerEffectApplied = false;
  double _transitionVolumeMultiplier = 1.0;
  double _normalizationMultiplier = 1.0;
  late final Future<LoudnessProfileCache> _loudnessCacheFuture;
  LoudnessProfileCache? _loudnessCache;
  final LoudnessAnalyzer _loudnessAnalyzer = LoudnessAnalyzer();
  final List<String> _loudnessQueue = <String>[];
  final Set<String> _queuedLoudnessPaths = <String>{};
  bool _loudnessWorkerRunning = false;
  late final Future<PlaybackPreferenceStore> _playbackPreferenceStore;
  PlaybackAdjustments _globalPlaybackAdjustments = PlaybackAdjustments.neutral;
  PlaybackAdjustments _requestedPlaybackAdjustments = PlaybackAdjustments.neutral;
  Future<void> _playbackAdjustmentQueue = Future<void>.value();
  Timer? _periodicPositionSaveTimer;
  Timer? _playbackHealthTimer;
  bool? _lastPresencePlaying;
  bool _playbackRequested = false;
  bool _playbackUnavailable = false;
  int? _retryLoadGeneration;
  int? _handledFailureGeneration;
  final Set<String> _failedTrackIds = <String>{};

  final StreamController<Duration> _positionController = StreamController<Duration>.broadcast();
  final StreamController<Duration?> _durationController = StreamController<Duration?>.broadcast();

  // Tracks whether the current track is a stream (URL), for seek behaviour.
  bool _currentTrackIsStream = false;

  bool get isStandaloneMode => standaloneModeNotifier.value || mediaItem.value?.extras?['resonanceStandalone'] == true;

  double get visualizerAmplitude {
    final envelope = _audioEnvelope;
    final trackId = _audioEnvelopeTrackId;
    final current = mediaItem.value;
    if (envelope != null && trackId != null && current != null && _sameTrackId(trackId, current.id)) {
      return envelope.amplitudeAt(_currentPosition);
    }
    return current == null ? 0 : fallbackVisualizerAmplitude(current.id, _currentPosition);
  }

  bool _sameTrackId(String first, String second) {
    if (first == second) return true;
    if (first.startsWith('http://') ||
        first.startsWith('https://') ||
        second.startsWith('http://') ||
        second.startsWith('https://')) {
      return false;
    }
    final normalizedFirst = p.normalize(p.absolute(first));
    final normalizedSecond = p.normalize(p.absolute(second));
    return Platform.isWindows
        ? normalizedFirst.toLowerCase() == normalizedSecond.toLowerCase()
        : normalizedFirst == normalizedSecond;
  }

  void setStandalonePresentation(bool enabled) {
    standaloneModeNotifier.value = enabled;
    if (!enabled) {
      _standalonePlaylistNumber = null;
      _standalonePlaylistIndex = null;
    }
    final current = mediaItem.value;
    if (current == null) return;
    final extras = <String, dynamic>{...?current.extras};
    if (enabled) {
      extras['resonanceStandalone'] = true;
    } else {
      extras.remove('resonanceStandalone');
    }
    mediaItem.add(current.copyWith(extras: extras));
  }

  /// Opens the existing player session in the large playlist view. The audio
  /// is loaded only when [filePath] is not already the active track.
  Future<bool> preparePlaylistTrackForStandalone(
    String filePath,
    String title,
    String artist, {
    required int playlistNumber,
    required int playlistIndex,
  }) async {
    _standalonePlaylistNumber = playlistNumber;
    _standalonePlaylistIndex = playlistIndex;
    final current = mediaItem.value;
    if (current != null &&
        _pendingRestoredTrack == null &&
        _sameTrackId(current.id, filePath) &&
        playbackState.value.processingState != AudioProcessingState.idle) {
      trackTransitionNotifier.value = TrackTransitionState(revision: trackTransitionNotifier.value.revision + 1);
      setStandalonePresentation(true);
      return true;
    }
    unawaited(
      loadTrack(
        filePath,
        title,
        artist,
        standalone: true,
        standalonePlaylistNumber: playlistNumber,
        standalonePlaylistIndex: playlistIndex,
      ),
    );
    return true;
  }

  // Session-scoped cache: YouTube URL → resolved CDN/HLS URL.
  final Map<String, String> _streamUrlCache = {};
  final _windowsStreamProxy = _WindowsStreamProxy();
  bool _windowsIsBuffering = false;
  bool _windowsIsCompleted = false;
  Duration _windowsPosition = Duration.zero;
  Duration _windowsDuration = Duration.zero;
  Duration _windowsBufferedPosition = Duration.zero;
  DateTime _lastPlaybackBroadcast = DateTime.fromMillisecondsSinceEpoch(0);

  PlayerHandler() {
    _playbackPreferenceStore = PlaybackPreferenceStore.load();
    _loudnessCacheFuture = LoudnessProfileCache.load();
    if (Platform.isWindows) {
      final player = mk.Player(configuration: const mk.PlayerConfiguration(pitch: true));
      _windowsPlayer = player;
      _attachWindowsPlayer(player);
    } else {
      final backend = _createJustAudioBackend();
      _player = backend.player;
      _loudnessEnhancer = backend.loudnessEnhancer;
      _androidEqualizer = backend.equalizer;
      _attachJustAudioPlayer(_player);
    }

    WidgetsBinding.instance.addObserver(this);
    _periodicPositionSaveTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_isBackendPlaying) unawaited(saveCurrentPlaybackPosition());
    });
    unawaited(_initSavedState());
  }

  ({AudioPlayer player, AndroidLoudnessEnhancer loudnessEnhancer, AndroidEqualizer equalizer})
  _createJustAudioBackend() {
    final loudnessEnhancer = AndroidLoudnessEnhancer();
    final equalizer = AndroidEqualizer();
    final player = AudioPlayer(audioPipeline: AudioPipeline(androidAudioEffects: [loudnessEnhancer, equalizer]));
    return (player: player, loudnessEnhancer: loudnessEnhancer, equalizer: equalizer);
  }

  void _attachWindowsPlayer(mk.Player player) {
    player.stream.playing.listen((playing) {
      if (!identical(player, _windowsPlayer)) return;
      _updatePlaybackState();
      unawaited(_updatePresenceForPlaying(playing));
    });
    player.stream.position.listen((position) {
      if (!identical(player, _windowsPlayer)) return;
      _windowsPosition = position;
      _positionController.add(position);
      _updatePlaybackState();
      _maybeStartAutomaticCrossfade();
    });
    player.stream.duration.listen((duration) {
      if (!identical(player, _windowsPlayer)) return;
      _windowsDuration = duration;
      _durationController.add(duration);
      final currentItem = mediaItem.value;
      if (currentItem != null && duration > Duration.zero) {
        mediaItem.add(currentItem.copyWith(duration: duration));
      }
      _updatePlaybackState();
    });
    player.stream.buffer.listen((position) {
      if (!identical(player, _windowsPlayer)) return;
      _windowsBufferedPosition = position;
      _updatePlaybackState();
    });
    player.stream.buffering.listen((isBuffering) {
      if (!identical(player, _windowsPlayer)) return;
      _windowsIsBuffering = isBuffering;
      _updatePlaybackState();
    });
    player.stream.completed.listen((completed) async {
      if (!identical(player, _windowsPlayer) || !completed) return;
      _windowsIsCompleted = completed;
      _updatePlaybackState();
      if (_crossfadeInProgress) return;
      await _clearCurrentPlaybackPosition();
      final genAtCompletion = _loadGeneration;
      if (currentLoopMode == LoopMode.one) {
        await player.seek(Duration.zero);
        await player.play();
      } else if (_loadGeneration == genAtCompletion) {
        await _advanceAfterCompletion();
      }
    });
    player.stream.rate.listen((speed) {
      if (identical(player, _windowsPlayer)) speedNotifier.value = speed;
    });
    player.stream.pitch.listen((pitch) {
      if (identical(player, _windowsPlayer)) pitchNotifier.value = pitch;
    });
    player.stream.error.listen((error) {
      if (!identical(player, _windowsPlayer) || _activeTrackLoadGeneration != null) return;
      debugPrint('[PlayerHandler] Windows playback backend reported: $error');
      _armPlaybackHealthCheck(_loadGeneration, grace: const Duration(milliseconds: 1200), reason: error);
    });
  }

  void _attachJustAudioPlayer(AudioPlayer player) {
    player.playbackEventStream.listen(
      (_) {
        if (identical(player, _player)) _updatePlaybackState();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!identical(player, _player) || _activeTrackLoadGeneration != null) return;
        debugPrint('[PlayerHandler] Android playback backend reported: $error\n$stackTrace');
        _armPlaybackHealthCheck(_loadGeneration, grace: const Duration(milliseconds: 1200), reason: error);
      },
    );
    player.speedStream.listen((speed) {
      if (identical(player, _player)) speedNotifier.value = speed;
    });
    player.playingStream.listen((playing) {
      if (!identical(player, _player)) return;
      _updatePlaybackState();
      unawaited(_updatePresenceForPlaying(playing));
    });

    player.durationStream.listen((duration) {
      if (!identical(player, _player)) return;
      _durationController.add(duration);
      final currentItem = mediaItem.value;
      if (currentItem != null && duration != null) {
        mediaItem.add(currentItem.copyWith(duration: duration));
      }
      _updatePlaybackState();
    });

    player.positionStream.listen((position) {
      if (!identical(player, _player)) return;
      _positionController.add(position);
      _updatePlaybackState();
      _maybeStartAutomaticCrossfade();
    });

    player.processingStateStream.listen((state) async {
      if (!identical(player, _player)) return;
      _updatePlaybackState();
      if (state == ProcessingState.completed) {
        if (_crossfadeInProgress) return;
        await _clearCurrentPlaybackPosition();
        final genAtCompletion = _loadGeneration;
        if (currentLoopMode == LoopMode.one) {
          await player.seek(Duration.zero);
          await player.play();
        } else if (_loadGeneration == genAtCompletion) {
          await _advanceAfterCompletion();
        }
      }
    });
  }

  Future<void> _updatePresenceForPlaying(bool isPlaying) async {
    if (_lastPresencePlaying == isPlaying) return;
    _lastPresencePlaying = isPlaying;
    try {
      if (isPlaying) {
        final current = mediaItem.value;
        if (current != null) {
          await DiscordPresenceService().updatePresence(current.title, current.artist ?? 'Unknown Artist');
        }
      } else {
        await DiscordPresenceService().setIdle();
      }
    } catch (error) {
      debugPrint('[PlayerHandler] Presence update failed: $error');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(saveCurrentPlaybackPosition());
    }
  }

  // ─── Diagnostic overrides ─────────────────────────────────────────
  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    debugPrint('[PlayerHandler] click($button)');
    await super.click(button);
  }

  // ─── Stream URL resolution ────────────────────────────────────────
  Future<String> _resolveStreamUrl(String url) async {
    if (_streamUrlCache.containsKey(url)) {
      debugPrint('[PlayerHandler] Stream URL cache hit for $url');
      return _streamUrlCache[url]!;
    }

    debugPrint('[PlayerHandler] Resolving stream URL for $url');
    String resolved;

    if (Platform.isWindows) {
      final binDir = p.join(p.dirname(Platform.resolvedExecutable), 'bin');
      final ytDlpPath = p.join(binDir, 'yt-dlp.exe');
      final denoPath = p.join(binDir, 'deno.exe');

      final process = await Process.start(ytDlpPath, [
        '--js-runtimes',
        'deno:$denoPath',
        '--force-ipv4',
        '--dump-single-json',
        '--no-warnings',
        '--no-playlist',
        '--skip-download',
        '--format',
        'bestaudio[has_drm!=true]/best[has_drm!=true]',
        url,
      ]);
      final stderr = StringBuffer();
      process.stderr.transform(utf8.decoder).listen(stderr.write);
      final output = await process.stdout.transform(utf8.decoder).join();
      final exitCode = await process.exitCode;
      if (exitCode != 0) {
        throw Exception('yt-dlp failed: ${stderr.toString().trim()}');
      }
      final info = jsonDecode(output) as Map<String, dynamic>;
      resolved = await _windowsStreamProxy.register(info);
    } else if (Platform.isAndroid) {
      const channel = MethodChannel('resonance/android_youtube');
      final result = await channel.invokeMethod<String>('getStreamUrl', {'url': url});
      if (result == null || result.isEmpty) {
        throw Exception('Android bridge returned empty stream URL');
      }
      resolved = result;
    } else {
      throw UnsupportedError('Streaming not supported on this platform');
    }

    if (resolved.isEmpty) throw Exception('Resolved stream URL is empty');
    if (!_streamUrlCache.containsKey(url) && _streamUrlCache.length >= 32) {
      _streamUrlCache.remove(_streamUrlCache.keys.first);
    }
    _streamUrlCache[url] = resolved;
    debugPrint('[PlayerHandler] Resolved stream URL: ${resolved.substring(0, resolved.length.clamp(0, 80))}...');
    return resolved;
  }

  Future<AudioSource> _buildAudioSource(String filePath) async {
    final isStream = filePath.startsWith('http://') || filePath.startsWith('https://');
    if (isStream) {
      final resolvedUrl = await _resolveStreamUrl(filePath);
      return AudioSource.uri(Uri.parse(resolvedUrl));
    } else {
      return AudioSource.uri(Uri.file(filePath));
    }
  }

  Future<String> _buildMediaKitUri(String filePath) async {
    final isStream = filePath.startsWith('http://') || filePath.startsWith('https://');
    if (isStream) {
      return _resolveStreamUrl(filePath);
    }
    return Uri.file(filePath).toString();
  }

  bool get _isWindowsPlaying => _windowsPlayer?.state.playing ?? false;

  bool get _isBackendPlaying => Platform.isWindows ? _isWindowsPlaying : _player.playing;

  Duration get _currentPosition => Platform.isWindows ? _windowsPosition : _player.position;

  Duration? get _currentDuration => Platform.isWindows ? _windowsDuration : _player.duration;

  Duration get currentPosition => _currentPosition;

  Duration? get currentDuration => _currentDuration;

  String _failureTrackKey(String trackId) {
    if (trackId.startsWith('http://') || trackId.startsWith('https://')) return trackId;
    final normalized = p.normalize(p.absolute(trackId));
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  void _armPlaybackHealthCheck(int generation, {Duration grace = const Duration(seconds: 5), Object? reason}) {
    _playbackHealthTimer?.cancel();
    if (_currentTrackIsStream || !_playbackRequested || _playbackUnavailable) return;
    final initialPosition = _currentPosition;
    final windowsPlayer = Platform.isWindows ? _windowsPlayer : null;
    final justAudioPlayer = Platform.isWindows ? null : _player;
    _playbackHealthTimer = Timer(grace, () {
      if (_loadGeneration != generation || !_playbackRequested || _playbackUnavailable || _currentTrackIsStream) {
        return;
      }
      if (Platform.isWindows) {
        if (!identical(windowsPlayer, _windowsPlayer)) return;
      } else if (!identical(justAudioPlayer, _player)) {
        return;
      }
      final completed = Platform.isWindows ? _windowsIsCompleted : _player.processingState == ProcessingState.completed;
      if (completed || playbackPositionAdvanced(initialPosition, _currentPosition)) {
        _failedTrackIds.clear();
        _retryLoadGeneration = null;
        return;
      }
      unawaited(_handlePlaybackFailure(generation, reason ?? 'playback made no progress'));
    });
  }

  Future<void> _handlePlaybackFailure(int generation, Object reason) async {
    if (_loadGeneration != generation ||
        _handledFailureGeneration == generation ||
        !_playbackRequested ||
        _currentTrackIsStream) {
      return;
    }
    final current = mediaItem.value;
    if (current == null) return;
    _handledFailureGeneration = generation;
    _playbackHealthTimer?.cancel();
    debugPrint('[PlayerHandler] Playback failed for "${current.id}" (generation $generation): $reason');

    if (_retryLoadGeneration != generation) {
      _retryLoadGeneration = _loadGeneration + 1;
      await loadTrack(
        current.id,
        current.title,
        current.artist ?? 'Unknown Artist',
        standalone: isStandaloneMode,
        artworkUri: current.artUri,
        standalonePlaylistNumber: _standalonePlaylistNumber,
        standalonePlaylistIndex: _standalonePlaylistIndex,
        preserveFailureHistory: true,
      );
      return;
    }

    _failedTrackIds.add(_failureTrackKey(current.id));
    _retryLoadGeneration = null;
    await _advanceAfterPlaybackFailure(current, generation);
  }

  Future<void> _advanceAfterPlaybackFailure(MediaItem failedItem, int generation) async {
    final playlistNumber = _standalonePlaylistNumber;
    if (isStandaloneMode && playlistNumber == null) {
      await _markPlaybackUnavailable(generation);
      return;
    }
    final playlist = playlistNumber != null
        ? await _getCleanPlaylist(playlistNumber: playlistNumber)
        : isShuffle
        ? shuffledList
        : await _getCleanPlaylist();
    if (_loadGeneration != generation) return;
    final currentIndex = _currentPlaylistIndex(playlist, failedItem.id);
    final nextIndex = nextPlayablePlaylistIndex(
      playlist: playlist,
      currentIndex: currentIndex,
      allowWrap: currentLoopMode != LoopMode.off,
      hasFailed: (path) => _failedTrackIds.contains(_failureTrackKey(path)),
    );
    if (nextIndex < 0) {
      await _markPlaybackUnavailable(generation);
      return;
    }
    final path = playlist[nextIndex];
    final metadata = await _getTrackMetadata(path);
    if (_loadGeneration != generation) return;
    await loadTrack(
      path,
      metadata.title,
      metadata.artist,
      standalone: playlistNumber != null,
      standalonePlaylistNumber: playlistNumber,
      standalonePlaylistIndex: nextIndex,
      transitionDirection: TrackTransitionDirection.next,
      preserveFailureHistory: true,
    );
  }

  Future<void> _markPlaybackUnavailable([int? generation]) async {
    if (generation != null && _loadGeneration != generation) return;
    _playbackRequested = false;
    _playbackUnavailable = true;
    try {
      if (Platform.isWindows) {
        await _windowsPlayer!.pause();
      } else {
        await _player.pause();
      }
    } catch (error) {
      debugPrint('[PlayerHandler] Could not pause failed playback: $error');
    }
    playbackVisualNotifier.value = PlaybackVisualState(trackId: mediaItem.value?.id);
    _updatePlaybackState(force: true);
  }

  void setUiVisible(bool visible) {
    if (uiVisibleNotifier.value == visible) return;
    uiVisibleNotifier.value = visible;
    if (visible) {
      _updatePlaybackState(force: true);
    } else {
      unawaited(saveCurrentPlaybackPosition());
    }
  }

  /// Windows media backends keep the current audio file open while it is
  /// paused. Release that handle for an in-place metadata update, then restore
  /// the track, position, and play state without requiring elevation.
  Future<T> withTrackFileReleased<T>(
    String filePath,
    Future<T> Function() action, {
    required String updatedTitle,
    required String updatedArtist,
  }) async {
    final current = mediaItem.value;
    if (!Platform.isWindows || current == null || current.id.startsWith('http')) return action();
    final normalizedTarget = p.normalize(p.absolute(filePath)).toLowerCase();
    final normalizedCurrent = p.normalize(p.absolute(current.id)).toLowerCase();
    if (normalizedTarget != normalizedCurrent) return action();

    final wasPlaying = _isWindowsPlaying;
    final position = _currentPosition;
    var updated = false;
    try {
      await _windowsPlayer!.stop();
      final result = await action();
      updated = true;
      return result;
    } finally {
      await loadTrack(
        filePath,
        updated ? updatedTitle : current.title,
        updated ? updatedArtist : current.artist ?? 'Unknown Artist',
      );
      await seek(position);
      if (!wasPlaying) await pause();
    }
  }

  void _updatePlaybackState({bool force = false}) {
    final playing = !_playbackUnavailable && (Platform.isWindows ? _isWindowsPlaying : _player.playing);
    final backendProcessingState = _playbackUnavailable
        ? AudioProcessingState.idle
        : Platform.isWindows
        ? _windowsIsCompleted
              ? AudioProcessingState.completed
              : _windowsIsBuffering
              ? AudioProcessingState.buffering
              : AudioProcessingState.ready
        : _getProcessingState(_player.processingState);
    final processingState = visibleProcessingState(backendProcessingState, isStream: _currentTrackIsStream);
    final visual = PlaybackVisualState(
      trackId: mediaItem.value?.id,
      playing: playing,
      loading: processingState == AudioProcessingState.loading || processingState == AudioProcessingState.buffering,
    );
    final visualChanged = playbackVisualNotifier.value != visual;
    if (visualChanged) playbackVisualNotifier.value = visual;

    final now = DateTime.now();
    final minimumInterval = uiVisibleNotifier.value ? const Duration(milliseconds: 200) : const Duration(seconds: 1);
    if (!force && !visualChanged && now.difference(_lastPlaybackBroadcast) < minimumInterval) return;
    _lastPlaybackBroadcast = now;

    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.skipToNext,
          MediaAction.skipToPrevious,
          MediaAction.play,
          MediaAction.pause,
        },
        processingState: processingState,
        playing: playing,
        updatePosition: Platform.isWindows ? _windowsPosition : _player.position,
        bufferedPosition: Platform.isWindows ? _windowsBufferedPosition : _player.bufferedPosition,
        speed: Platform.isWindows ? speedNotifier.value : _player.speed,
        queueIndex: Platform.isWindows ? 0 : _player.currentIndex,
      ),
    );
  }

  // ─── Saved state ──────────────────────────────────────────────────
  Future<void> _initSavedState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _playbackPreferenceStore;
      _loudnessCache = await _loudnessCacheFuture;

      final vol = prefs.getDouble('last_volume') ?? 0.5;
      await changeVolume(vol);

      final speed = prefs.getDouble('last_speed') ?? 1.0;
      final pitch = prefs.getDouble('last_pitch') ?? 1.0;
      final encodedEqualizer = prefs.getString('last_equalizer_settings_v1');
      final equalizer = encodedEqualizer == null
          ? EqualizerSettings.fromLegacyBass(prefs.getDouble('last_bass_boost') ?? 0)
          : EqualizerSettings.fromJson(jsonDecode(encodedEqualizer));
      _globalPlaybackAdjustments = PlaybackAdjustments(speed: speed, pitch: pitch, equalizer: equalizer);

      final scopeName = prefs.getString('playback_settings_scope');
      playbackSettingsScopeNotifier.value = PlaybackSettingsScope.values.firstWhere(
        (scope) => scope.name == scopeName,
        orElse: () => PlaybackSettingsScope.global,
      );
      crossfadeEnabledNotifier.value = prefs.getBool('crossfade_enabled') ?? false;
      crossfadeDurationSecondsNotifier.value = (prefs.getDouble('crossfade_duration_seconds') ?? 3.0).clamp(0.0, 8.0);
      resumeLongTracksNotifier.value = prefs.getBool('resume_long_tracks') ?? true;
      volumeNormalizationEnabledNotifier.value = prefs.getBool('volume_normalization_enabled') ?? false;
      seekStepNotifier.value = (prefs.getInt('seek_step_seconds') ?? 5).clamp(1, 15);

      await _applyPlaybackAdjustments(
        playbackSettingsScopeNotifier.value == PlaybackSettingsScope.global
            ? _globalPlaybackAdjustments
            : PlaybackAdjustments.neutral,
        persist: false,
      );

      final savedLoopMode = prefs.getString('last_loop_mode');
      currentLoopMode = LoopMode.values.firstWhere((mode) => mode.name == savedLoopMode, orElse: () => LoopMode.all);
      isShuffle = prefs.getBool('last_shuffle') ?? false;
      if (isShuffle) await shuffleQueue();
      playbackModeRevision.value++;

      final trackPath = prefs.getString('last_track_path');
      final trackTitle = prefs.getString('last_track_title');
      final trackArtist = prefs.getString('last_track_artist');
      final trackWasExternal = prefs.getBool('last_track_external_source');

      if (trackPath != null && trackTitle != null && trackArtist != null) {
        await _preloadTrack(trackPath, trackTitle, trackArtist, externalSource: trackWasExternal);
      }
      if (volumeNormalizationEnabledNotifier.value) {
        unawaited(_queueLibraryLoudnessAnalysis());
      }
    } catch (e) {
      debugPrint('Error initializing saved state: $e');
    }
  }

  Future<void> _preloadTrack(String filePath, String title, String artist, {bool? externalSource}) async {
    try {
      final isStream = filePath.startsWith('http://') || filePath.startsWith('https://');
      if (!isStream && !await File(filePath).exists()) {
        throw StateError('Saved track no longer exists');
      }
      final containingPlaylist = externalSource == null ? await FileService().findPlaylistContaining(filePath) : null;
      final restoredFromOutsidePlaylist = restoredTrackIsExternal(
        persistedValue: externalSource,
        trackIsInPlaylist: containingPlaylist != null,
      );
      standaloneModeNotifier.value = restoredFromOutsidePlaylist;
      _standalonePlaylistNumber = null;
      _standalonePlaylistIndex = null;
      final restored = MediaItem(
        id: filePath,
        title: title,
        artist: artist,
        artUri: await _albumArtUri(filePath),
        extras: standalonePresentationExtras(restoredFromOutsidePlaylist),
      );
      _pendingRestoredTrack = restored;
      mediaItem.add(restored);
      _updatePlaybackState();
    } catch (e) {
      debugPrint('Error preloading track: $e');
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('last_track_path');
        await prefs.remove('last_track_title');
        await prefs.remove('last_track_artist');
        await prefs.remove('last_track_external_source');
      } catch (_) {}
    }
  }

  Future<void> _saveTrack(String filePath, String title, String artist, {bool? externalSource}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_track_path', filePath);
      await prefs.setString('last_track_title', title);
      await prefs.setString('last_track_artist', artist);
      await prefs.setBool(
        'last_track_external_source',
        externalSource ?? (standaloneModeNotifier.value && _standalonePlaylistNumber == null),
      );
    } catch (e) {
      debugPrint('Error saving track: $e');
    }
  }

  // ─── Playback preferences ────────────────────────────────────────
  Future<void> setCrossfadeEnabled(bool enabled) async {
    crossfadeEnabledNotifier.value = enabled;
    if (!enabled) {
      _crossfadeGeneration++;
      _crossfadeInProgress = false;
      _transitionVolumeMultiplier = 1.0;
      await _applyOutputVolume();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('crossfade_enabled', enabled);
  }

  Future<void> setCrossfadeDuration(double seconds) async {
    final clamped = seconds.clamp(0.0, 8.0);
    crossfadeDurationSecondsNotifier.value = clamped;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('crossfade_duration_seconds', clamped);
  }

  Future<void> setResumeLongTracksEnabled(bool enabled) async {
    resumeLongTracksNotifier.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('resume_long_tracks', enabled);
    if (!enabled) await saveCurrentPlaybackPosition();
  }

  Future<void> setPlaybackSettingsScope(PlaybackSettingsScope scope) async {
    if (playbackSettingsScopeNotifier.value == scope) return;
    playbackSettingsScopeNotifier.value = scope;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('playback_settings_scope', scope.name);
    final current = mediaItem.value;
    final adjustments = scope == PlaybackSettingsScope.global
        ? _globalPlaybackAdjustments
        : current == null
        ? PlaybackAdjustments.neutral
        : (await _playbackPreferenceStore).adjustmentsFor(current.id);
    await _applyPlaybackAdjustments(adjustments, persist: false);
  }

  Future<void> saveCurrentPlaybackPosition() async {
    if (!resumeLongTracksNotifier.value) return;
    final current = mediaItem.value;
    final duration = _currentDuration;
    final position = _currentPosition;
    if (current == null || duration == null || !isResumablePosition(position, duration)) return;
    try {
      await (await _playbackPreferenceStore).savePosition(current.id, position);
    } catch (error) {
      debugPrint('[PlayerHandler] Could not save playback position: $error');
    }
  }

  Future<void> _clearCurrentPlaybackPosition() async {
    final current = mediaItem.value;
    if (current == null) return;
    try {
      await (await _playbackPreferenceStore).clearPosition(current.id);
    } catch (error) {
      debugPrint('[PlayerHandler] Could not clear playback position: $error');
    }
  }

  Future<void> _restorePlaybackPosition(String filePath, int generation) async {
    if (!resumeLongTracksNotifier.value || _loadGeneration != generation) return;
    final saved = (await _playbackPreferenceStore).positionFor(filePath);
    if (saved == null || _loadGeneration != generation) return;
    var duration = _currentDuration;
    if (duration == null || duration <= Duration.zero) {
      try {
        duration = await durationStream
            .where((value) => value != null && value > Duration.zero)
            .cast<Duration>()
            .first
            .timeout(const Duration(seconds: 3));
      } catch (_) {
        duration = _currentDuration;
      }
    }
    if (_loadGeneration != generation || !isLongFormTrack(duration)) return;
    if (!isResumablePosition(saved, duration!)) return;
    await seek(saved);
  }

  Future<PlaybackAdjustments> _adjustmentsForTrack(String filePath) async {
    if (playbackSettingsScopeNotifier.value == PlaybackSettingsScope.global) {
      return _globalPlaybackAdjustments;
    }
    return (await _playbackPreferenceStore).adjustmentsFor(filePath);
  }

  Future<void> _persistPlaybackAdjustments(
    PlaybackAdjustments adjustments, {
    required PlaybackSettingsScope scope,
    required String? trackId,
  }) async {
    if (scope == PlaybackSettingsScope.global) {
      _globalPlaybackAdjustments = adjustments;
      final prefs = await SharedPreferences.getInstance();
      await Future.wait([
        prefs.setDouble('last_speed', adjustments.speed),
        prefs.setDouble('last_pitch', adjustments.pitch),
        prefs.setString('last_equalizer_settings_v1', jsonEncode(adjustments.equalizer.toJson())),
        // Keep the legacy scalar for one release so downgrades remain usable.
        prefs.setDouble('last_bass_boost', adjustments.equalizer.legacyBassEquivalent),
      ]);
      return;
    }
    if (trackId != null) {
      await (await _playbackPreferenceStore).saveAdjustments(trackId, adjustments);
    }
  }

  PlaybackAdjustments get _currentAdjustments =>
      PlaybackAdjustments(speed: speedNotifier.value, pitch: pitchNotifier.value, equalizer: equalizerNotifier.value);

  Future<void> _applyPlaybackAdjustments(PlaybackAdjustments adjustments, {required bool persist}) {
    final normalized = PlaybackAdjustments(
      speed: adjustments.speed.clamp(0.5, 2.0),
      pitch: adjustments.pitch.clamp(0.5, 2.0),
      equalizer: adjustments.equalizer,
    );
    _requestedPlaybackAdjustments = normalized;
    final persistenceScope = playbackSettingsScopeNotifier.value;
    final persistenceTrackId = mediaItem.value?.id;
    if (persist && persistenceScope == PlaybackSettingsScope.global) {
      // Keep subsequent track loads on the latest requested global values even
      // while the platform calls are waiting their turn in the queue.
      _globalPlaybackAdjustments = normalized;
    }

    final operation = _playbackAdjustmentQueue.then((_) async {
      await _applyPlaybackAdjustmentsNow(
        normalized,
        persist: persist,
        persistenceScope: persistenceScope,
        persistenceTrackId: persistenceTrackId,
      );
    });
    // A failed backend call is still returned to its caller, but must not
    // poison later slider updates or track-load adjustments.
    _playbackAdjustmentQueue = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  Future<void> _applyPlaybackAdjustmentsNow(
    PlaybackAdjustments normalized, {
    required bool persist,
    required PlaybackSettingsScope persistenceScope,
    required String? persistenceTrackId,
  }) async {
    var equalizerApplied = false;
    if (Platform.isWindows) {
      equalizerApplied = await _applyWindowsPlaybackAdjustments(_windowsPlayer!, normalized);
    } else {
      await _player.setSpeed(normalized.speed);
      await _player.setPitch(normalized.pitch);
      if (mediaItem.value != null || !normalized.equalizer.isActive) {
        equalizerApplied = await _applyAndroidEqualizer(_androidEqualizer, normalized.equalizer);
      }
    }
    speedNotifier.value = normalized.speed;
    pitchNotifier.value = normalized.pitch;
    equalizerNotifier.value = normalized.equalizer;
    _equalizerEffectApplied = equalizerApplied;
    await _applyOutputVolume();
    if (persist) {
      await _persistPlaybackAdjustments(normalized, scope: persistenceScope, trackId: persistenceTrackId);
    }
    _updatePlaybackState();
  }

  Future<bool> _applyAndroidEqualizer(
    AndroidEqualizer equalizer,
    EqualizerSettings settings, {
    bool updateSupport = true,
  }) async {
    if (!Platform.isAndroid) {
      if (updateSupport && settings.isActive) equalizerSupportedNotifier.value = false;
      return false;
    }
    try {
      if (!settings.isActive) {
        await equalizer.setEnabled(false);
        return false;
      }

      final parameters = await equalizer.parameters.timeout(const Duration(seconds: 2));
      if (parameters.bands.isEmpty) {
        throw StateError('The active Android audio session exposes no equalizer bands');
      }
      for (final band in parameters.bands) {
        await band.setGain(
          interpolatedEqualizerGain(
            band.centerFrequency,
            settings,
          ).clamp(parameters.minDecibels, parameters.maxDecibels),
        );
      }
      await equalizer.setEnabled(true);
      if (updateSupport) equalizerSupportedNotifier.value = true;
      return true;
    } catch (error) {
      debugPrint('[PlayerHandler] Android equalizer unavailable: $error');
      try {
        await equalizer.setEnabled(false);
      } catch (_) {}
    }
    if (updateSupport) equalizerSupportedNotifier.value = false;
    return false;
  }

  Future<bool> _applyWindowsPlaybackAdjustments(
    mk.Player player,
    PlaybackAdjustments adjustments, {
    bool updateSupport = true,
  }) async {
    await player.setRate(adjustments.speed);
    await player.setPitch(adjustments.pitch);
    try {
      final platform = player.platform;
      if (platform is! mk.NativePlayer) throw UnsupportedError('Native libmpv filters are unavailable');
      await platform.setProperty('af', buildWindowsAudioFilter(adjustments));
      if (updateSupport) equalizerSupportedNotifier.value = true;
      return adjustments.equalizer.isActive;
    } catch (error) {
      debugPrint('[PlayerHandler] Windows equalizer filter unavailable: $error');
      if (updateSupport && adjustments.equalizer.isActive) equalizerSupportedNotifier.value = false;
      return false;
    }
  }

  Future<void> _setJustAudioOutputVolume(
    AudioPlayer player,
    AndroidLoudnessEnhancer loudnessEnhancer,
    double multiplier,
    EqualizerSettings equalizer,
    bool equalizerApplied,
    double normalizationMultiplier,
  ) async {
    final raw = volumeNotifier.value * multiplier * normalizationMultiplier;
    final headroom = equalizerOutputHeadroomMultiplier(equalizer, effectApplied: equalizerApplied);
    if (Platform.isAndroid) {
      final effectiveRaw = raw * headroom;
      await player.setVolume(effectiveRaw.clamp(0.0, 1.0));
      await loudnessEnhancer.setEnabled(effectiveRaw > 1.0);
      await loudnessEnhancer.setTargetGain(effectiveRaw > 1.0 ? (effectiveRaw - 1.0) * 10.0 : 0.0);
    } else {
      await player.setVolume(raw * headroom);
    }
  }

  Future<void> _setWindowsOutputVolume(
    mk.Player player,
    double multiplier,
    EqualizerSettings equalizer,
    bool equalizerApplied,
    double normalizationMultiplier,
  ) => player.setVolume(
    volumeNotifier.value *
        multiplier *
        normalizationMultiplier *
        equalizerOutputHeadroomMultiplier(equalizer, effectApplied: equalizerApplied) *
        100.0,
  );

  Future<void> _applyOutputVolume() async {
    try {
      if (Platform.isWindows) {
        await _setWindowsOutputVolume(
          _windowsPlayer!,
          _transitionVolumeMultiplier,
          equalizerNotifier.value,
          _equalizerEffectApplied,
          _normalizationMultiplier,
        );
      } else {
        await _setJustAudioOutputVolume(
          _player,
          _loudnessEnhancer,
          _transitionVolumeMultiplier,
          equalizerNotifier.value,
          _equalizerEffectApplied,
          _normalizationMultiplier,
        );
      }
    } catch (error) {
      debugPrint('[PlayerHandler] Could not apply output volume: $error');
    }
  }

  double _normalizationMultiplierFor(String filePath) {
    if (!volumeNormalizationEnabledNotifier.value ||
        filePath.startsWith('http://') ||
        filePath.startsWith('https://')) {
      return 1.0;
    }
    return _loudnessCache?.profileFor(filePath)?.multiplier ?? 1.0;
  }

  Future<void> setVolumeNormalizationEnabled(bool enabled) async {
    if (volumeNormalizationEnabledNotifier.value == enabled) return;
    volumeNormalizationEnabledNotifier.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('volume_normalization_enabled', enabled);

    final currentPath = mediaItem.value?.id;
    final target = currentPath == null ? 1.0 : _normalizationMultiplierFor(currentPath);
    await _rampNormalizationMultiplier(target);
    if (!enabled) return;
    if (currentPath != null) _scheduleLoudnessAnalysis(currentPath, priority: true);
    unawaited(_queueLibraryLoudnessAnalysis());
  }

  Future<void> _rampNormalizationMultiplier(double target) async {
    final initial = _normalizationMultiplier;
    if ((target - initial).abs() < 0.0001) return;
    const steps = 8;
    for (var step = 1; step <= steps; step++) {
      _normalizationMultiplier = initial + (target - initial) * step / steps;
      await _applyOutputVolume();
      if (step < steps) await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }

  void _scheduleLoudnessAnalysis(String filePath, {bool priority = false}) {
    if (!volumeNormalizationEnabledNotifier.value ||
        filePath.startsWith('http://') ||
        filePath.startsWith('https://') ||
        _loudnessCache?.profileFor(filePath) != null) {
      return;
    }
    final identity = playbackLoudnessIdentity(filePath);
    if (!_queuedLoudnessPaths.add(identity)) return;
    if (priority) {
      _loudnessQueue.insert(0, filePath);
    } else {
      _loudnessQueue.add(filePath);
    }
    final progress = loudnessScanProgressNotifier.value;
    loudnessScanProgressNotifier.value = LoudnessScanProgress(
      scanning: true,
      completed: progress.scanning ? progress.completed : 0,
      total: (progress.scanning ? progress.total : 0) + 1,
    );
    unawaited(_runLoudnessWorker());
  }

  Future<void> _queueLibraryLoudnessAnalysis() async {
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!volumeNormalizationEnabledNotifier.value) return;
    try {
      final current = mediaItem.value?.id;
      final playlist = await _getCleanPlaylist();
      if (current != null) _scheduleLoudnessAnalysis(current, priority: true);
      for (final path in playlist) {
        if (!_sameTrackId(path, current ?? '')) _scheduleLoudnessAnalysis(path);
      }
    } catch (error) {
      debugPrint('[PlayerHandler] Could not queue loudness analysis: $error');
    }
  }

  Future<void> _runLoudnessWorker() async {
    if (_loudnessWorkerRunning) return;
    _loudnessWorkerRunning = true;
    final cache = _loudnessCache ?? await _loudnessCacheFuture;
    _loudnessCache = cache;
    try {
      while (_loudnessQueue.isNotEmpty && volumeNormalizationEnabledNotifier.value) {
        final filePath = _loudnessQueue.removeAt(0);
        final identity = playbackLoudnessIdentity(filePath);
        try {
          if (cache.profileFor(filePath) == null) {
            final profile = await _loudnessAnalyzer.analyze(filePath);
            if (profile != null) await cache.store(filePath, profile);
          }
        } finally {
          _queuedLoudnessPaths.remove(identity);
          final progress = loudnessScanProgressNotifier.value;
          loudnessScanProgressNotifier.value = LoudnessScanProgress(
            scanning: _loudnessQueue.isNotEmpty,
            completed: progress.completed + 1,
            total: progress.total,
          );
        }
      }
    } finally {
      _loudnessWorkerRunning = false;
      if (!volumeNormalizationEnabledNotifier.value) {
        _loudnessQueue.clear();
        _queuedLoudnessPaths.clear();
        loudnessScanProgressNotifier.value = const LoudnessScanProgress();
      } else if (_loudnessQueue.isEmpty) {
        final progress = loudnessScanProgressNotifier.value;
        loudnessScanProgressNotifier.value = LoudnessScanProgress(completed: progress.completed, total: progress.total);
      }
    }
  }

  // ─── Automatic crossfade ─────────────────────────────────────────
  void _maybeStartAutomaticCrossfade() {
    if (_crossfadeInProgress ||
        _activeTrackLoadGeneration != null ||
        _activeSeekGeneration != null ||
        !crossfadeEnabledNotifier.value ||
        currentLoopMode == LoopMode.one ||
        !_isBackendPlaying) {
      return;
    }
    final duration = _currentDuration;
    final fade = Duration(milliseconds: (crossfadeDurationSecondsNotifier.value * 1000).round());
    if (duration == null || fade <= Duration.zero || duration <= fade || _currentPosition <= Duration.zero) return;
    final remaining = duration - _currentPosition;
    if (remaining > fade + const Duration(milliseconds: 150) || remaining <= Duration.zero) return;
    _crossfadeInProgress = true;
    final generation = ++_crossfadeGeneration;
    unawaited(_performAutomaticCrossfade(generation, fade));
  }

  Future<_AutomaticTrackTarget?> _automaticNextTarget() async {
    final currentItem = mediaItem.value;
    if (currentItem == null) return null;
    final playlistNumber = _standalonePlaylistNumber;
    if (isStandaloneMode && playlistNumber == null) return null;
    final playlist = playlistNumber != null
        ? await _getCleanPlaylist(playlistNumber: playlistNumber)
        : isShuffle
        ? shuffledList
        : await _getCleanPlaylist();
    if (playlist.length < 2) return null;
    final currentIndex = _currentPlaylistIndex(playlist, currentItem.id);
    if (currentIndex < 0) return null;
    final candidateIndex = currentIndex + 1;
    if (candidateIndex >= playlist.length && currentLoopMode == LoopMode.off) return null;
    final nextIndex = candidateIndex % playlist.length;
    final path = playlist[nextIndex];
    final metadata = await _getTrackMetadata(path);
    return _AutomaticTrackTarget(
      path: path,
      title: metadata.title,
      artist: metadata.artist,
      standalone: playlistNumber != null,
      playlistNumber: playlistNumber,
      playlistIndex: nextIndex,
    );
  }

  Future<Duration?> _incomingResumePosition(String path, Duration? duration) async {
    if (!resumeLongTracksNotifier.value || !isLongFormTrack(duration)) return null;
    final saved = (await _playbackPreferenceStore).positionFor(path);
    return saved != null && isResumablePosition(saved, duration!) ? saved : null;
  }

  Future<bool> _runEqualPowerFade(
    int generation,
    Duration duration,
    Future<void> Function(double outgoing, double incoming) setVolumes,
  ) async {
    final steps = math.max(1, duration.inMilliseconds ~/ 50);
    final delay = Duration(microseconds: math.max(1, duration.inMicroseconds ~/ steps));
    for (var step = 0; step <= steps; step++) {
      if (generation != _crossfadeGeneration || !crossfadeEnabledNotifier.value) return false;
      final progress = step / steps;
      await setVolumes(math.cos(progress * math.pi / 2), math.sin(progress * math.pi / 2));
      if (step < steps) await Future<void>.delayed(delay);
    }
    return generation == _crossfadeGeneration;
  }

  Duration _availableCrossfadeDuration(Duration requested) {
    final duration = _currentDuration;
    if (duration == null) return requested;
    final remaining = duration - _currentPosition;
    if (remaining <= Duration.zero) return Duration.zero;
    return remaining < requested ? remaining : requested;
  }

  Future<void> _performAutomaticCrossfade(int generation, Duration fade) async {
    final outgoingItem = mediaItem.value;
    if (outgoingItem == null) {
      _crossfadeInProgress = false;
      return;
    }
    try {
      // Playlist reads, metadata lookup, resume persistence, and per-track
      // preference loading are part of crossfade preparation too. Keep them
      // inside the fallback boundary so an I/O failure cannot leave the
      // completion handler permanently suppressed by `_crossfadeInProgress`.
      await saveCurrentPlaybackPosition();
      final target = await _automaticNextTarget();
      if (target == null || generation != _crossfadeGeneration) {
        if (generation == _crossfadeGeneration) _crossfadeInProgress = false;
        return;
      }
      final adjustments = await _adjustmentsForTrack(target.path);
      if (generation != _crossfadeGeneration) return;

      if (Platform.isWindows) {
        await _performWindowsCrossfade(generation, fade, outgoingItem, target, adjustments);
      } else {
        await _performJustAudioCrossfade(generation, fade, outgoingItem, target, adjustments);
      }
    } catch (error, stackTrace) {
      debugPrint('[PlayerHandler] Crossfade failed; using normal transition: $error\n$stackTrace');
      if (generation == _crossfadeGeneration) {
        _crossfadeInProgress = false;
        _transitionVolumeMultiplier = 1.0;
        await _applyOutputVolume();
        final duration = _currentDuration;
        final finished = Platform.isWindows
            ? _windowsIsCompleted
            : _player.processingState == ProcessingState.completed;
        if (finished || (duration != null && duration - _currentPosition <= const Duration(milliseconds: 500))) {
          await _advanceAfterCompletion();
        }
      }
    }
  }

  Future<void> _performWindowsCrossfade(
    int generation,
    Duration fade,
    MediaItem outgoingItem,
    _AutomaticTrackTarget target,
    PlaybackAdjustments incomingAdjustments,
  ) async {
    final outgoing = _windowsPlayer!;
    final outgoingAdjustments = _currentAdjustments;
    final outgoingEqualizerApplied = _equalizerEffectApplied;
    final outgoingNormalization = _normalizationMultiplier;
    final incomingNormalization = _normalizationMultiplierFor(target.path);
    final incoming = mk.Player(configuration: const mk.PlayerConfiguration(pitch: true));
    _attachWindowsPlayer(incoming);
    var adopted = false;
    try {
      final uri = await _buildMediaKitUri(target.path);
      if (generation != _crossfadeGeneration) return;
      await incoming.open(mk.Media(uri), play: false);
      final incomingEqualizerApplied = await _applyWindowsPlaybackAdjustments(
        incoming,
        incomingAdjustments,
        updateSupport: false,
      );
      final resume = await _incomingResumePosition(target.path, incoming.state.duration);
      if (resume != null) await incoming.seek(resume);
      await _setWindowsOutputVolume(
        incoming,
        0,
        incomingAdjustments.equalizer,
        incomingEqualizerApplied,
        incomingNormalization,
      );
      await incoming.play();
      final completed = await _runEqualPowerFade(generation, _availableCrossfadeDuration(fade), (
        outgoingVolume,
        incomingVolume,
      ) async {
        await Future.wait([
          _setWindowsOutputVolume(
            outgoing,
            outgoingVolume,
            outgoingAdjustments.equalizer,
            outgoingEqualizerApplied,
            outgoingNormalization,
          ),
          _setWindowsOutputVolume(
            incoming,
            incomingVolume,
            incomingAdjustments.equalizer,
            incomingEqualizerApplied,
            incomingNormalization,
          ),
        ]);
      });
      if (!completed || !identical(outgoing, _windowsPlayer)) return;

      _windowsPlayer = incoming;
      adopted = true;
      _windowsPosition = incoming.state.position;
      _windowsDuration = incoming.state.duration;
      _windowsBufferedPosition = incoming.state.buffer;
      _windowsIsBuffering = incoming.state.buffering;
      _windowsIsCompleted = incoming.state.completed;
      _equalizerEffectApplied = incomingEqualizerApplied;
      _normalizationMultiplier = incomingNormalization;
      await _finishAutomaticCrossfade(outgoingItem, target, incomingAdjustments);
      unawaited(outgoing.stop().catchError((_) {}));
      unawaited(outgoing.dispose().catchError((_) {}));
    } finally {
      if (!adopted) {
        await incoming.stop().catchError((_) {});
        await incoming.dispose().catchError((_) {});
        if (identical(outgoing, _windowsPlayer)) {
          _crossfadeInProgress = false;
          await _setWindowsOutputVolume(
            outgoing,
            1.0,
            outgoingAdjustments.equalizer,
            outgoingEqualizerApplied,
            outgoingNormalization,
          );
        }
      }
    }
  }

  Future<void> _performJustAudioCrossfade(
    int generation,
    Duration fade,
    MediaItem outgoingItem,
    _AutomaticTrackTarget target,
    PlaybackAdjustments incomingAdjustments,
  ) async {
    final outgoing = _player;
    final outgoingLoudnessEnhancer = _loudnessEnhancer;
    final outgoingAdjustments = _currentAdjustments;
    final outgoingEqualizerApplied = _equalizerEffectApplied;
    final outgoingNormalization = _normalizationMultiplier;
    final incomingNormalization = _normalizationMultiplierFor(target.path);
    final backend = _createJustAudioBackend();
    final incoming = backend.player;
    _attachJustAudioPlayer(incoming);
    var adopted = false;
    try {
      final source = await _buildAudioSource(target.path);
      if (generation != _crossfadeGeneration) return;
      await incoming.setAudioSource(source);
      await incoming.setSpeed(incomingAdjustments.speed);
      await incoming.setPitch(incomingAdjustments.pitch);
      final incomingEqualizerApplied = await _applyAndroidEqualizer(
        backend.equalizer,
        incomingAdjustments.equalizer,
        updateSupport: false,
      );
      final resume = await _incomingResumePosition(target.path, incoming.duration);
      if (resume != null) await incoming.seek(resume);
      await _setJustAudioOutputVolume(
        incoming,
        backend.loudnessEnhancer,
        0,
        incomingAdjustments.equalizer,
        incomingEqualizerApplied,
        incomingNormalization,
      );
      // just_audio's play Future remains pending until playback is paused,
      // stopped, or completes. Awaiting it would leave the incoming player at
      // zero volume and prevent adoption until the entire next track ended.
      unawaited(
        incoming.play().catchError((Object error, StackTrace stackTrace) {
          debugPrint('[PlayerHandler] Incoming Android crossfade playback failed: $error\n$stackTrace');
          if (generation == _crossfadeGeneration) _crossfadeGeneration++;
        }),
      );
      final completed = await _runEqualPowerFade(generation, _availableCrossfadeDuration(fade), (
        outgoingVolume,
        incomingVolume,
      ) async {
        await Future.wait([
          _setJustAudioOutputVolume(
            outgoing,
            outgoingLoudnessEnhancer,
            outgoingVolume,
            outgoingAdjustments.equalizer,
            outgoingEqualizerApplied,
            outgoingNormalization,
          ),
          _setJustAudioOutputVolume(
            incoming,
            backend.loudnessEnhancer,
            incomingVolume,
            incomingAdjustments.equalizer,
            incomingEqualizerApplied,
            incomingNormalization,
          ),
        ]);
      });
      if (!completed || !identical(outgoing, _player)) return;

      _player = incoming;
      _loudnessEnhancer = backend.loudnessEnhancer;
      _androidEqualizer = backend.equalizer;
      _equalizerEffectApplied = incomingEqualizerApplied;
      _normalizationMultiplier = incomingNormalization;
      adopted = true;
      await _finishAutomaticCrossfade(outgoingItem, target, incomingAdjustments);
      unawaited(outgoing.stop().catchError((_) {}));
      unawaited(outgoing.dispose().catchError((_) {}));
    } finally {
      if (!adopted) {
        await incoming.stop().catchError((_) {});
        await incoming.dispose().catchError((_) {});
        if (identical(outgoing, _player)) {
          _crossfadeInProgress = false;
          await _setJustAudioOutputVolume(
            outgoing,
            outgoingLoudnessEnhancer,
            1.0,
            outgoingAdjustments.equalizer,
            outgoingEqualizerApplied,
            outgoingNormalization,
          );
        }
      }
    }
  }

  Future<void> _finishAutomaticCrossfade(
    MediaItem outgoingItem,
    _AutomaticTrackTarget target,
    PlaybackAdjustments adjustments,
  ) async {
    try {
      await (await _playbackPreferenceStore).clearPosition(outgoingItem.id);
    } catch (error) {
      debugPrint('[PlayerHandler] Could not clear completed track position: $error');
    }
    final generation = ++_loadGeneration;
    _crossfadeInProgress = false;
    _transitionVolumeMultiplier = 1.0;
    _currentTrackIsStream = target.path.startsWith('http://') || target.path.startsWith('https://');
    _audioEnvelope = null;
    _audioEnvelopeTrackId = null;
    _envelopeAnalyzer.cancel();
    standaloneModeNotifier.value = target.standalone;
    _standalonePlaylistNumber = target.playlistNumber;
    _standalonePlaylistIndex = target.playlistIndex;
    speedNotifier.value = adjustments.speed;
    pitchNotifier.value = adjustments.pitch;
    equalizerNotifier.value = adjustments.equalizer;
    _requestedPlaybackAdjustments = adjustments;
    trackTransitionNotifier.value = TrackTransitionState(
      revision: trackTransitionNotifier.value.revision + 1,
      direction: TrackTransitionDirection.next,
    );
    final duration = _currentDuration;
    mediaItem.add(
      MediaItem(
        id: target.path,
        title: target.title,
        artist: target.artist,
        duration: duration,
        extras: standalonePresentationExtras(target.standalone),
      ),
    );
    _positionController.add(_currentPosition);
    _durationController.add(duration);
    _lastPresencePlaying = null;
    unawaited(_updatePresenceForPlaying(true));
    await _applyOutputVolume();
    _updatePlaybackState(force: true);
    unawaited(
      _finishTrackLoad(
        generation: generation,
        filePath: target.path,
        title: target.title,
        artist: target.artist,
        artworkUri: null,
        externalSource: false,
      ),
    );
    unawaited(_prepareAudioEnvelope(generation: generation, filePath: target.path));
    unawaited(_prepareLoudnessAnalysis(generation: generation, filePath: target.path));
  }

  // ─── Core playback ────────────────────────────────────────────────
  @override
  Future<void> play() async {
    final restored = _pendingRestoredTrack;
    if (restored != null) {
      _pendingRestoredTrack = null;
      await loadTrack(
        restored.id,
        restored.title,
        restored.artist ?? 'Unknown Artist',
        standalone: restored.extras?['resonanceStandalone'] == true,
      );
      return;
    }
    final current = mediaItem.value;
    if (_playbackUnavailable && current != null) {
      _failedTrackIds.clear();
      _retryLoadGeneration = null;
      await loadTrack(
        current.id,
        current.title,
        current.artist ?? 'Unknown Artist',
        standalone: isStandaloneMode,
        artworkUri: current.artUri,
        standalonePlaylistNumber: _standalonePlaylistNumber,
        standalonePlaylistIndex: _standalonePlaylistIndex,
      );
      return;
    }
    _playbackRequested = true;
    if (Platform.isWindows) {
      try {
        if (!_isWindowsPlaying) await _windowsPlayer!.play();
      } catch (error) {
        await _handlePlaybackFailure(_loadGeneration, error);
        return;
      }
      _updatePlaybackState();
      _armPlaybackHealthCheck(_loadGeneration);
      return;
    }
    if (!_player.playing) {
      unawaited(
        _player.play().catchError((Object error, StackTrace stackTrace) async {
          debugPrint('[PlayerHandler] Playback start failed: $error\n$stackTrace');
          await _handlePlaybackFailure(_loadGeneration, error);
        }),
      );
    }
    _updatePlaybackState();
    _armPlaybackHealthCheck(_loadGeneration);
  }

  @override
  Future<void> pause() async {
    _playbackRequested = false;
    _playbackHealthTimer?.cancel();
    await saveCurrentPlaybackPosition();
    if (Platform.isWindows) {
      if (!_isWindowsPlaying) return;
      await _windowsPlayer!.pause();
      _updatePlaybackState();
      return;
    }
    if (!_player.playing) return;
    await _player.pause();
    _updatePlaybackState();
  }

  @override
  Future<void> seek(Duration position) async {
    final generation = ++_seekGeneration;
    _activeSeekGeneration = generation;
    final operation = _seekOperationQueue.then((_) => _seekBackend(position));
    _seekOperationQueue = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    try {
      await operation;
    } finally {
      if (_activeSeekGeneration == generation) {
        _activeSeekGeneration = null;
        // Position events are ignored while the backend seek is unresolved.
        // Re-evaluate immediately afterward so seeking near the end can still
        // begin the configured automatic crossfade.
        _maybeStartAutomaticCrossfade();
      }
    }
  }

  Future<void> _seekBackend(Duration position) async {
    if (_crossfadeInProgress) {
      _crossfadeGeneration++;
      _crossfadeInProgress = false;
      _transitionVolumeMultiplier = 1.0;
      await _applyOutputVolume();
    }
    if (Platform.isWindows) {
      // For local files on Windows: seek directly without pause/play cycle.
      // media_kit handles buffering internally; forcing pause/play causes
      // the play button to get stuck in the wrong state.
      if (!_currentTrackIsStream) {
        _windowsPosition = position;
        await _windowsPlayer!.seek(position);
        _updatePlaybackState();
        return;
      }

      // For streams: signal buffering, seek, then restore play state.
      final wasPlaying = _isWindowsPlaying;
      final player = _windowsPlayer!;
      _windowsIsBuffering = true;
      _windowsPosition = position;
      _updatePlaybackState();
      await player.seek(position);
      if (wasPlaying) await player.play();
      _updatePlaybackState();
      return;
    }

    // Android / other: just_audio handles seek internally for local files.
    // Only show a buffering state for streamed tracks.
    if (_currentTrackIsStream) {
      playbackState.add(
        playbackState.value.copyWith(
          processingState: AudioProcessingState.buffering,
          playing: _player.playing,
          updatePosition: position,
        ),
      );
    }
    await _player.seek(position);
    _updatePlaybackState();
  }

  @override
  Future<void> skipToNext() async => next();

  @override
  Future<void> skipToPrevious() async => previous();

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    switch (name) {
      case 'resonance.toggleShuffle':
        await toggleShuffle();
        return getShuffleMode();
      case 'resonance.toggleRepeat':
        await toggleLoopMode();
        return getLoopMode().name;
      default:
        return super.customAction(name, extras);
    }
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) =>
      setShuffleEnabled(shuffleMode != AudioServiceShuffleMode.none);

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) => setLoopMode(switch (repeatMode) {
    AudioServiceRepeatMode.none => LoopMode.off,
    AudioServiceRepeatMode.one => LoopMode.one,
    AudioServiceRepeatMode.all || AudioServiceRepeatMode.group => LoopMode.all,
  });

  @override
  Future<void> stop() async {
    await _seekOperationQueue;
    await saveCurrentPlaybackPosition();
    _pendingRestoredTrack = null;
    _playbackRequested = false;
    _playbackUnavailable = false;
    _playbackHealthTimer?.cancel();
    _failedTrackIds.clear();
    _retryLoadGeneration = null;
    _handledFailureGeneration = null;
    _loadGeneration++;
    _crossfadeGeneration++;
    _crossfadeInProgress = false;
    _transitionVolumeMultiplier = 1.0;
    _envelopeAnalyzer.cancel();
    _audioEnvelope = null;
    _audioEnvelopeTrackId = null;
    _streamUrlCache.clear();
    standaloneModeNotifier.value = false;
    _standalonePlaylistNumber = null;
    _standalonePlaylistIndex = null;
    trackTransitionNotifier.value = TrackTransitionState(revision: trackTransitionNotifier.value.revision + 1);

    try {
      if (Platform.isWindows) {
        await _windowsPlayer!.stop();
        _windowsPosition = Duration.zero;
        _windowsDuration = Duration.zero;
        _windowsBufferedPosition = Duration.zero;
        _windowsIsBuffering = false;
        _windowsIsCompleted = false;
      } else {
        await _player.stop();
      }
    } catch (e) {
      debugPrint('[PlayerHandler] Stop failed: $e');
    }

    mediaItem.add(null);
    playbackVisualNotifier.value = const PlaybackVisualState();
    playbackState.add(
      playbackState.value.copyWith(
        controls: const [],
        systemActions: const {},
        processingState: AudioProcessingState.idle,
        playing: false,
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
        queueIndex: null,
      ),
    );
    await DiscordPresenceService().clearPresence();
    await super.stop();
    if (Platform.isAndroid) {
      unawaited(
        const MethodChannel(
          'resonance/app_control',
        ).invokeMethod<void>('exitApp').catchError((e) => debugPrint('[PlayerHandler] Android app exit failed: $e')),
      );
    }
  }

  @override
  Future<void> setSpeed(double speed) async {
    await _applyPlaybackAdjustments(
      _requestedPlaybackAdjustments.copyWith(speed: speed.clamp(0.5, 2.0)),
      persist: true,
    );
  }

  Future<void> setPitch(double pitch) async {
    await _applyPlaybackAdjustments(
      _requestedPlaybackAdjustments.copyWith(pitch: pitch.clamp(0.5, 2.0)),
      persist: true,
    );
  }

  Future<void> setEqualizer(EqualizerSettings settings) async {
    await _applyPlaybackAdjustments(_requestedPlaybackAdjustments.copyWith(equalizer: settings), persist: true);
  }

  /// Compatibility shim for older companion clients during the protocol
  /// transition. New UI uses [setEqualizer].
  Future<void> setBassBoost(double strength) => setEqualizer(EqualizerSettings.fromLegacyBass(strength));

  Future<void> resetPlaybackAdjustments() => _applyPlaybackAdjustments(PlaybackAdjustments.neutral, persist: true);

  // ─── loadTrack ────────────────────────────────────────────────────
  Future<void> loadTrack(
    String filePath,
    String title,
    String artist, {
    bool standalone = false,
    Uri? artworkUri,
    int? standalonePlaylistNumber,
    int? standalonePlaylistIndex,
    TrackTransitionDirection transitionDirection = TrackTransitionDirection.none,
    bool preserveFailureHistory = false,
  }) async {
    final generation = ++_loadGeneration;
    _playbackRequested = false;
    _playbackUnavailable = false;
    _playbackHealthTimer?.cancel();
    _handledFailureGeneration = null;
    if (!preserveFailureHistory) {
      _failedTrackIds.clear();
      _retryLoadGeneration = null;
    }
    _activeTrackLoadGeneration = generation;
    try {
      await _loadTrackRequest(
        filePath,
        title,
        artist,
        generation: generation,
        standalone: standalone,
        artworkUri: artworkUri,
        standalonePlaylistNumber: standalonePlaylistNumber,
        standalonePlaylistIndex: standalonePlaylistIndex,
        transitionDirection: transitionDirection,
      );
    } finally {
      if (_activeTrackLoadGeneration == generation) {
        _activeTrackLoadGeneration = null;
      }
    }
  }

  Future<void> _loadTrackRequest(
    String filePath,
    String title,
    String artist, {
    required int generation,
    required bool standalone,
    required Uri? artworkUri,
    required int? standalonePlaylistNumber,
    required int? standalonePlaylistIndex,
    required TrackTransitionDirection transitionDirection,
  }) async {
    final myGen = generation;
    await _seekOperationQueue;
    if (_loadGeneration != myGen) return;
    _crossfadeGeneration++;
    _crossfadeInProgress = false;
    _transitionVolumeMultiplier = 1.0;
    await _applyOutputVolume();
    await saveCurrentPlaybackPosition();
    _pendingRestoredTrack = null;
    _audioEnvelope = null;
    _audioEnvelopeTrackId = null;
    standaloneModeNotifier.value = standalone;
    _standalonePlaylistNumber = standalone ? standalonePlaylistNumber : null;
    _standalonePlaylistIndex = standalone ? standalonePlaylistIndex : null;
    trackTransitionNotifier.value = TrackTransitionState(
      revision: trackTransitionNotifier.value.revision + 1,
      direction: transitionDirection,
    );
    await _playbackAdjustmentQueue;
    if (_loadGeneration != myGen) return;
    final isStream = filePath.startsWith('http://') || filePath.startsWith('https://');
    final adjustments = await _adjustmentsForTrack(filePath);
    if (_loadGeneration != myGen) return;

    _currentTrackIsStream = isStream;
    _normalizationMultiplier = _normalizationMultiplierFor(filePath);

    // Optimistic UI update
    mediaItem.add(
      MediaItem(
        id: filePath,
        title: title,
        artist: artist,
        artUri: artworkUri,
        extras: standalonePresentationExtras(standalone),
      ),
    );
    playbackState.add(
      playbackState.value.copyWith(
        processingState: isStream ? AudioProcessingState.loading : AudioProcessingState.ready,
        playing: false,
      ),
    );
    playbackVisualNotifier.value = PlaybackVisualState(trackId: filePath, loading: isStream);
    _playbackRequested = true;

    try {
      // Resolving a stream can take time, so silence the previous source while
      // that network work happens. Local sources are replaced directly by the
      // backend; an explicit pause only adds avoidable switching latency.
      if (isStream) {
        if (Platform.isWindows) {
          if (_isWindowsPlaying) await _windowsPlayer!.pause();
        } else if (_player.playing) {
          await _player.pause();
        }
      }
      if (_loadGeneration != myGen) return;

      if (Platform.isWindows) {
        String uri;
        try {
          uri = await _buildMediaKitUri(filePath);
        } catch (e) {
          if (_loadGeneration != myGen) return;
          debugPrint('[PlayerHandler] Failed to build media_kit URI for "$filePath": $e');
          rethrow;
        }

        if (_loadGeneration != myGen) return;

        _windowsIsBuffering = false;
        _windowsIsCompleted = false;
        _windowsPosition = Duration.zero;
        _windowsDuration = Duration.zero;
        _windowsBufferedPosition = Duration.zero;

        final player = _windowsPlayer!;
        // Keep source replacement and playback start in one media_kit command.
        // Splitting this into open(play: false) followed by play() regressed in
        // v2.3.0: mpv can acknowledge the open before the replacement source is
        // ready to accept play, leaving an otherwise valid local track at 0:00.
        await player.open(mk.Media(uri), play: true);
        if (_loadGeneration != myGen) {
          await player.stop();
          return;
        }
      } else {
        AudioSource source;
        try {
          source = await _buildAudioSource(filePath);
        } catch (e) {
          if (_loadGeneration != myGen) return;
          debugPrint('[PlayerHandler] Failed to build audio source for "$filePath": $e');
          rethrow;
        }

        if (_loadGeneration != myGen) return;
        await _player.setAudioSource(source);
        if (_loadGeneration != myGen) return;
      }

      if (_loadGeneration != myGen) return;
      await _applyPlaybackAdjustments(adjustments, persist: false);
      if (_loadGeneration != myGen) return;
      await _restorePlaybackPosition(filePath, myGen);
      if (_loadGeneration != myGen) return;
      if (!Platform.isWindows) {
        unawaited(
          _player.play().catchError((Object error, StackTrace stackTrace) async {
            debugPrint('[PlayerHandler] Playback start failed: $error\n$stackTrace');
            await _handlePlaybackFailure(myGen, error);
          }),
        );
      }
      _armPlaybackHealthCheck(myGen);

      // Do not stop the background visualizer decoder until the new source is
      // already ready (and Windows is already playing). Process cancellation
      // can briefly contend with the audio backend on both platforms.
      _envelopeAnalyzer.cancel();

      final dur = _currentDuration;
      mediaItem.add(
        MediaItem(
          id: filePath,
          title: title,
          artist: artist,
          duration: dur,
          artUri: artworkUri,
          // Presentation may have been dismissed while a slow stream was
          // resolving. Never restore the stale standalone flag captured when
          // this load began.
          extras: standalonePresentationExtras(standaloneModeNotifier.value),
        ),
      );

      _updatePlaybackState();
      final loadedFromOutsidePlaylist = standaloneModeNotifier.value && _standalonePlaylistNumber == null;
      unawaited(
        _finishTrackLoad(
          generation: myGen,
          filePath: filePath,
          title: title,
          artist: artist,
          artworkUri: artworkUri,
          externalSource: loadedFromOutsidePlaylist,
        ),
      );
      unawaited(_prepareAudioEnvelope(generation: myGen, filePath: filePath));
      unawaited(_prepareLoudnessAnalysis(generation: myGen, filePath: filePath));
    } catch (e, st) {
      if (_loadGeneration == myGen) {
        debugPrint('[PlayerHandler] Error loading track "$filePath": $e\n$st');
        _streamUrlCache.remove(filePath);
        if (standalone) setStandalonePresentation(false);
        playbackState.add(playbackState.value.copyWith(processingState: AudioProcessingState.idle, playing: false));
        _updatePlaybackState();
        await _handlePlaybackFailure(myGen, e);
      }
    }
  }

  Future<void> _finishTrackLoad({
    required int generation,
    required String filePath,
    required String title,
    required String artist,
    required Uri? artworkUri,
    required bool externalSource,
  }) async {
    try {
      // Let playback win the initial disk/CPU race. The playing stream owns
      // Discord updates, so do not perform a duplicate presence request here.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (_loadGeneration == generation) {
        final resolvedArtwork = artworkUri ?? await _albumArtUri(filePath);
        if (_loadGeneration == generation && resolvedArtwork != null) {
          final current = mediaItem.value;
          if (current != null && _sameTrackId(current.id, filePath) && current.artUri != resolvedArtwork) {
            mediaItem.add(current.copyWith(artUri: resolvedArtwork));
          }
        }
      }
    } catch (e) {
      debugPrint('[PlayerHandler] Artwork extraction failed for "$filePath": $e');
    }
    try {
      if (_loadGeneration == generation) {
        await _saveTrack(filePath, title, artist, externalSource: externalSource);
      }
    } catch (e) {
      debugPrint('[PlayerHandler] Non-playback track update failed for "$filePath": $e');
    }
  }

  Future<void> _prepareAudioEnvelope({required int generation, required String filePath}) async {
    if (filePath.startsWith('http://') || filePath.startsWith('https://')) return;
    // Playback gets exclusive priority during the source swap. Analysis starts
    // shortly afterward on one decoder thread and is cached for later plays.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (_loadGeneration != generation) return;
    final envelope = await _envelopeAnalyzer.analyze(filePath);
    if (_loadGeneration != generation || envelope == null) return;
    _audioEnvelope = envelope;
    _audioEnvelopeTrackId = filePath;
  }

  Future<void> _prepareLoudnessAnalysis({required int generation, required String filePath}) async {
    if (!volumeNormalizationEnabledNotifier.value) return;
    await Future<void>.delayed(const Duration(seconds: 2));
    if (_loadGeneration != generation) return;
    _scheduleLoudnessAnalysis(filePath, priority: true);
  }

  Future<void> playStandaloneStream({
    required String url,
    required String title,
    required String artist,
    String? thumbnailUrl,
  }) async {
    final artworkUri = thumbnailUrl == null || thumbnailUrl.isEmpty ? null : Uri.tryParse(thumbnailUrl);
    await MetadataCacheService.set(url, title, artist, artworkUrl: thumbnailUrl);
    await loadTrack(url, title, artist, standalone: true, artworkUri: artworkUri);
    if (!isStandaloneMode ||
        mediaItem.value?.id != url ||
        playbackState.value.processingState == AudioProcessingState.idle) {
      throw StateError('The YouTube stream could not be loaded.');
    }
  }

  /// Releases a local file if it is active and forgets all player-side state
  /// that could retain it. Unlike [stop], this never exits the Android app.
  Future<void> forgetTrack(String filePath) async {
    try {
      final store = await _playbackPreferenceStore;
      await Future.wait([store.clearPosition(filePath), store.clearAdjustments(filePath)]);
    } catch (error) {
      debugPrint('[PlayerHandler] Could not clear forgotten track preferences: $error');
    }
    final current = mediaItem.value;
    final pending = _pendingRestoredTrack;
    final isCurrent = current != null && _sameTrackId(current.id, filePath);
    final isPending = pending != null && _sameTrackId(pending.id, filePath);
    if (isCurrent || isPending) {
      _pendingRestoredTrack = null;
      _loadGeneration++;
      _envelopeAnalyzer.cancel();
      _audioEnvelope = null;
      _audioEnvelopeTrackId = null;
      if (Platform.isWindows) {
        await _windowsPlayer!.stop();
        _windowsPosition = Duration.zero;
        _windowsDuration = Duration.zero;
        _windowsBufferedPosition = Duration.zero;
        _windowsIsBuffering = false;
        _windowsIsCompleted = false;
      } else {
        await _player.stop();
      }
      standaloneModeNotifier.value = false;
      _standalonePlaylistNumber = null;
      _standalonePlaylistIndex = null;
      mediaItem.add(null);
      playbackVisualNotifier.value = const PlaybackVisualState();
      playbackState.add(
        playbackState.value.copyWith(
          controls: const [],
          systemActions: const {},
          processingState: AudioProcessingState.idle,
          playing: false,
          updatePosition: Duration.zero,
          bufferedPosition: Duration.zero,
          queueIndex: null,
        ),
      );
      await DiscordPresenceService().setIdle();
    }

    _streamUrlCache.remove(filePath);
    removeTrackFromActivePlaybackOrder(filePath, allOccurrences: true);
    final retainedQueue = queue.value.where((item) => !_sameTrackId(item.id, filePath)).toList(growable: false);
    if (retainedQueue.length != queue.value.length) await updateQueue(retainedQueue);
    final artworkUri = _artUriCache.remove(filePath);
    if (artworkUri?.scheme == 'file') {
      try {
        final artworkFile = File.fromUri(artworkUri!);
        if (await artworkFile.exists()) await artworkFile.delete();
      } catch (_) {}
    }
    if (filePath.runes.any((rune) => rune > 127)) {
      try {
        final tempDir = await getTemporaryDirectory();
        final tempCopy = File(
          p.join(tempDir.path, 'resonance_track_${filePath.hashCode.abs()}${p.extension(filePath)}'),
        );
        if (await tempCopy.exists()) await tempCopy.delete();
      } catch (_) {}
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final savedPath = prefs.getString('last_track_path');
      if (savedPath != null && _sameTrackId(savedPath, filePath)) {
        await prefs.remove('last_track_path');
        await prefs.remove('last_track_title');
        await prefs.remove('last_track_artist');
        await prefs.remove('last_track_external_source');
      }
    } catch (_) {}
  }

  // ─── Volume ───────────────────────────────────────────────────────
  Future<void> changeVolume(double rawVolume) async {
    final clamped = rawVolume.clamp(0.0, 2.0);
    volumeNotifier.value = clamped;
    await _applyOutputVolume();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('last_volume', clamped);
    } catch (_) {}
  }

  Future<void> incrementVolume() async => changeVolume(volumeNotifier.value + 0.05);
  Future<void> decrementVolume() async => changeVolume(volumeNotifier.value - 0.05);
  Future<void> incrementSpeed() async => setSpeed((speedNotifier.value + 0.1).clamp(0.5, 2.0));
  Future<void> decrementSpeed() async => setSpeed((speedNotifier.value - 0.1).clamp(0.5, 2.0));

  Future<int> getSeekStepSeconds() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getInt('seek_step_seconds') ?? 5).clamp(1, 15);
  }

  Future<void> setSeekStepSeconds(int seconds) async {
    final prefs = await SharedPreferences.getInstance();
    final value = seconds.clamp(1, 15);
    await prefs.setInt('seek_step_seconds', value);
    seekStepNotifier.value = value;
  }

  Future<void> seekBySeconds(int seconds) async {
    final duration = _currentDuration ?? Duration.zero;
    final target = _currentPosition + Duration(seconds: seconds);
    final clamped = target < Duration.zero
        ? Duration.zero
        : duration > Duration.zero && target > duration
        ? duration
        : target;
    await seek(clamped);
  }

  Future<void> toggleMute() async {
    if (volumeNotifier.value == 0) {
      await changeVolume(savedVolume);
    } else {
      savedVolume = volumeNotifier.value;
      await changeVolume(0);
    }
  }

  // ─── Metadata ─────────────────────────────────────────────────────
  Future<({String title, String artist})> _getTrackMetadata(String path) async {
    final isStream = path.startsWith('http://') || path.startsWith('https://');
    final cached = await MetadataCacheService.get(path);
    if (cached != null) return (title: cached.title, artist: cached.artist);
    if (isStream) return (title: 'Streaming Audio', artist: 'YouTube');
    return (title: p.basenameWithoutExtension(path), artist: 'Unknown Artist');
  }

  Future<Uri?> _albumArtUri(String path) async {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      final cached = await MetadataCacheService.get(path);
      return Uri.tryParse(cached?.artworkUrl ?? '');
    }
    if (_artUriCache.containsKey(path)) return _artUriCache[path];

    try {
      final source = File(path);
      if (!await source.exists()) return _cacheArtworkUri(path, null);
      final modified = await source.lastModified();
      final cacheDir = Directory(p.join((await getTemporaryDirectory()).path, 'notification_art'));
      await cacheDir.create(recursive: true);
      final cacheKey = '${path.hashCode}_${modified.millisecondsSinceEpoch}';

      for (final extension in const ['jpg', 'png', 'webp']) {
        final cached = File(p.join(cacheDir.path, '$cacheKey.$extension'));
        if (await cached.exists() && await cached.length() > 0) {
          return _cacheArtworkUri(path, Uri.file(cached.path));
        }
      }

      final metadata = await MetadataGod.readMetadata(file: path);
      final bytes = metadata.picture?.data;
      if (bytes == null || bytes.isEmpty) return _cacheArtworkUri(path, null);
      final extension = _imageExtension(bytes);
      final artwork = File(p.join(cacheDir.path, '$cacheKey.$extension'));
      await artwork.writeAsBytes(bytes, flush: true);
      return _cacheArtworkUri(path, Uri.file(artwork.path));
    } catch (e) {
      debugPrint('[PlayerHandler] Could not extract notification artwork: $e');
      return _cacheArtworkUri(path, null);
    }
  }

  Uri? _cacheArtworkUri(String path, Uri? uri) {
    if (!_artUriCache.containsKey(path) && _artUriCache.length >= 64) {
      _artUriCache.remove(_artUriCache.keys.first);
    }
    _artUriCache[path] = uri;
    return uri;
  }

  String _imageExtension(List<int> bytes) {
    if (bytes.length >= 8 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4e && bytes[3] == 0x47) {
      return 'png';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'webp';
    }
    return 'jpg';
  }

  Future<void> _advanceAfterCompletion() async {
    final target = await _automaticNextTarget();
    if (target == null) {
      if (currentLoopMode == LoopMode.all) await next();
      return;
    }
    await loadTrack(
      target.path,
      target.title,
      target.artist,
      standalone: target.standalone,
      standalonePlaylistNumber: target.playlistNumber,
      standalonePlaylistIndex: target.playlistIndex,
      transitionDirection: TrackTransitionDirection.next,
    );
  }

  Future<void> next() async {
    final currentItem = mediaItem.value;
    if (currentItem == null) return;
    final standalonePlaylistNumber = _standalonePlaylistNumber;
    if (isStandaloneMode && standalonePlaylistNumber == null) return;
    final playlist = standalonePlaylistNumber != null
        ? await _getCleanPlaylist(playlistNumber: standalonePlaylistNumber)
        : isShuffle
        ? shuffledList
        : await _getCleanPlaylist();
    if (playlist.isEmpty) return;
    final index = _currentPlaylistIndex(playlist, currentItem.id);
    if (index == -1) return;
    final nextIndex = (index + 1) % playlist.length;
    final nextPath = playlist[nextIndex];
    final meta = await _getTrackMetadata(nextPath);
    await loadTrack(
      nextPath,
      meta.title,
      meta.artist,
      standalone: standalonePlaylistNumber != null,
      standalonePlaylistNumber: standalonePlaylistNumber,
      standalonePlaylistIndex: nextIndex,
      transitionDirection: TrackTransitionDirection.next,
    );
  }

  /// Moves to the previous track. Standard previous buttons restart the
  /// current track after three seconds; direct gestures can opt out.
  Future<void> previous({bool restartCurrent = true}) async {
    final currentItem = mediaItem.value;
    if (currentItem == null) return;
    final standalonePlaylistNumber = _standalonePlaylistNumber;
    if (isStandaloneMode && standalonePlaylistNumber == null) return;
    final playlist = standalonePlaylistNumber != null
        ? await _getCleanPlaylist(playlistNumber: standalonePlaylistNumber)
        : isShuffle
        ? shuffledList
        : await _getCleanPlaylist();
    if (playlist.isEmpty) return;
    final index = _currentPlaylistIndex(playlist, currentItem.id);
    if (index == -1) return;
    if (restartCurrent && _currentPosition > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }
    final prevIndex = (index - 1 + playlist.length) % playlist.length;
    final meta = await _getTrackMetadata(playlist[prevIndex]);
    await loadTrack(
      playlist[prevIndex],
      meta.title,
      meta.artist,
      standalone: standalonePlaylistNumber != null,
      standalonePlaylistNumber: standalonePlaylistNumber,
      standalonePlaylistIndex: prevIndex,
      transitionDirection: TrackTransitionDirection.previous,
    );
  }

  int _currentPlaylistIndex(List<String> playlist, String currentTrack) {
    final rememberedIndex = _standalonePlaylistIndex;
    if (rememberedIndex != null &&
        rememberedIndex >= 0 &&
        rememberedIndex < playlist.length &&
        _sameTrackId(playlist[rememberedIndex], currentTrack)) {
      return rememberedIndex;
    }
    return playlist.indexWhere((path) => _sameTrackId(path, currentTrack));
  }

  Future<bool> isPlaying() async => Platform.isWindows ? _isWindowsPlaying : _player.playing;

  /// FIX: Use the correct player for the current platform.
  Future<void> playPause() async {
    if (Platform.isWindows) {
      if (_isWindowsPlaying) {
        await pause();
      } else {
        await play();
      }
    } else {
      if (_player.playing) {
        await pause();
      } else {
        await play();
      }
    }
  }

  Stream<Duration> get positionStream => _positionController.stream;

  Stream<Duration?> get durationStream => _durationController.stream;

  Future<void> setQueue(List<MediaItem> tracks) async {
    await updateQueue(tracks);
    if (tracks.isNotEmpty && mediaItem.value == null) {
      await playMediaItem(tracks[0]);
    }
  }

  @override
  Future<void> playMediaItem(MediaItem mediaItem) => loadTrack(
    mediaItem.id,
    mediaItem.title,
    mediaItem.artist ?? 'Unknown Artist',
    artworkUri: mediaItem.artUri,
    standalone: mediaItem.extras?['resonanceStandalone'] == true,
  );

  Future<void> toggleLoopMode() async {
    if (currentLoopMode == LoopMode.off) {
      currentLoopMode = LoopMode.one;
    } else if (currentLoopMode == LoopMode.one) {
      currentLoopMode = LoopMode.all;
    } else {
      currentLoopMode = LoopMode.off;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_loop_mode', currentLoopMode.name);
    playbackModeRevision.value++;
  }

  Future<void> setLoopMode(LoopMode mode) async {
    if (currentLoopMode == mode) return;
    currentLoopMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_loop_mode', currentLoopMode.name);
    playbackModeRevision.value++;
  }

  Future<void> toggleShuffle() async {
    isShuffle = !isShuffle;
    if (isShuffle) await shuffleQueue();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('last_shuffle', isShuffle);
    playbackModeRevision.value++;
  }

  Future<void> setShuffleEnabled(bool enabled) async {
    if (isShuffle == enabled) return;
    isShuffle = enabled;
    if (isShuffle) await shuffleQueue();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('last_shuffle', isShuffle);
    playbackModeRevision.value++;
  }

  Future<void> saveState() async {
    await saveCurrentPlaybackPosition();
    await _playbackAdjustmentQueue;
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setDouble('last_volume', volumeNotifier.value),
      prefs.setDouble('last_speed', _globalPlaybackAdjustments.speed),
      prefs.setDouble('last_pitch', _globalPlaybackAdjustments.pitch),
      prefs.setString('last_equalizer_settings_v1', jsonEncode(_globalPlaybackAdjustments.equalizer.toJson())),
      prefs.setDouble('last_bass_boost', _globalPlaybackAdjustments.equalizer.legacyBassEquivalent),
      prefs.setString('last_loop_mode', currentLoopMode.name),
      prefs.setBool('last_shuffle', isShuffle),
      prefs.setBool('volume_normalization_enabled', volumeNormalizationEnabledNotifier.value),
    ]);
    final current = mediaItem.value;
    if (current != null) {
      if (playbackSettingsScopeNotifier.value == PlaybackSettingsScope.perTrack) {
        await (await _playbackPreferenceStore).saveAdjustments(current.id, _currentAdjustments);
      }
      await _saveTrack(current.id, current.title, current.artist ?? 'Unknown Artist');
    }
  }

  Future<void> shuffleQueue() async {
    final clean = await _getCleanPlaylist();
    shuffledList = List.from(clean)..shuffle();
  }

  /// Removes a playlist entry from the session's already-generated shuffle
  /// order without reshuffling the remaining tracks.
  void removeTrackFromActivePlaybackOrder(String filePath, {bool allOccurrences = false}) {
    if (allOccurrences) {
      shuffledList.removeWhere((path) => _sameTrackId(path, filePath));
    } else {
      final index = shuffledList.indexWhere((path) => _sameTrackId(path, filePath));
      if (index >= 0) shuffledList.removeAt(index);
    }
    playbackModeRevision.value++;
  }

  Future<List<String>> _getCleanPlaylist({int? playlistNumber}) async {
    final service = FileService();
    final content = playlistNumber == null
        ? await service.readTextFromFile()
        : await service.readTextFromPlaylist(playlistNumber);
    return content.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty && !l.startsWith('#')).toList();
  }

  /// Returns the playback order already in use by the engine. In particular,
  /// opening the visual queue never generates a new shuffle order.
  Future<PlaybackQueueSnapshot> playbackQueueSnapshot() async {
    final current = mediaItem.value;
    final loopBehavior = switch (currentLoopMode) {
      LoopMode.off => QueueLoopBehavior.off,
      LoopMode.one => QueueLoopBehavior.one,
      LoopMode.all => QueueLoopBehavior.all,
    };
    if (current == null) {
      return PlaybackQueueSnapshot(current: null, upcoming: const [], loopBehavior: loopBehavior, shuffled: isShuffle);
    }

    final playlistNumber = _standalonePlaylistNumber;
    final paths = isStandaloneMode && playlistNumber == null
        ? const <String>[]
        : playlistNumber != null
        ? await _getCleanPlaylist(playlistNumber: playlistNumber)
        : isShuffle
        ? List<String>.from(shuffledList)
        : await _getCleanPlaylist();
    final currentIndex = _currentPlaylistIndex(paths, current.id);
    final upcomingPaths = switch (loopBehavior) {
      QueueLoopBehavior.one => const <String>[],
      QueueLoopBehavior.off => currentIndex < 0 ? paths : paths.sublist(currentIndex + 1),
      QueueLoopBehavior.all =>
        currentIndex < 0 ? paths : <String>[...paths.sublist(currentIndex + 1), ...paths.sublist(0, currentIndex)],
    };
    final upcoming = await Future.wait(
      upcomingPaths.map((path) async {
        final metadata = await _getTrackMetadata(path);
        return PlaybackQueueEntry(id: path, title: metadata.title, artist: metadata.artist);
      }),
    );
    return PlaybackQueueSnapshot(
      current: PlaybackQueueEntry(
        id: current.id,
        title: current.title,
        artist: current.artist ?? 'Unknown Artist',
        artworkUri: current.artUri,
      ),
      upcoming: upcoming,
      loopBehavior: loopBehavior,
      shuffled: isShuffle,
    );
  }

  Future<void> playPlaybackQueueEntry(PlaybackQueueEntry entry) =>
      loadTrack(entry.id, entry.title, entry.artist, transitionDirection: TrackTransitionDirection.next);

  bool getShuffleMode() => isShuffle;
  LoopMode getLoopMode() => currentLoopMode;

  Future<void> dispose() async {
    WidgetsBinding.instance.removeObserver(this);
    _periodicPositionSaveTimer?.cancel();
    _playbackHealthTimer?.cancel();
    await _seekOperationQueue;
    _loadGeneration++;
    _activeTrackLoadGeneration = null;
    _crossfadeGeneration++;
    _crossfadeInProgress = false;
    _envelopeAnalyzer.dispose();
    _loudnessAnalyzer.dispose();
    await saveState();
    await _windowsStreamProxy.dispose();
    if (Platform.isWindows) {
      await _windowsPlayer?.dispose();
    } else {
      await _player.dispose();
    }
    await DiscordPresenceService().clearPresence();
    await DiscordPresenceService().dispose();
    await _positionController.close();
    await _durationController.close();
    volumeNotifier.dispose();
    speedNotifier.dispose();
    pitchNotifier.dispose();
    equalizerNotifier.dispose();
    equalizerSupportedNotifier.dispose();
    crossfadeEnabledNotifier.dispose();
    crossfadeDurationSecondsNotifier.dispose();
    resumeLongTracksNotifier.dispose();
    volumeNormalizationEnabledNotifier.dispose();
    loudnessScanProgressNotifier.dispose();
    playbackSettingsScopeNotifier.dispose();
    seekStepNotifier.dispose();
    playbackModeRevision.dispose();
    standaloneModeNotifier.dispose();
    playbackVisualNotifier.dispose();
    trackTransitionNotifier.dispose();
    uiVisibleNotifier.dispose();
  }

  AudioProcessingState _getProcessingState(ProcessingState state) {
    switch (state) {
      case ProcessingState.loading:
        return AudioProcessingState.loading;
      case ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ProcessingState.ready:
        return AudioProcessingState.ready;
      case ProcessingState.completed:
        return AudioProcessingState.completed;
      default:
        return AudioProcessingState.idle;
    }
  }
}

class _WindowsStreamProxy {
  HttpServer? _server;
  final _streams = <String, _WindowsStreamInfo>{};
  int _nextId = 0;

  Future<String> register(Map<String, dynamic> info) async {
    if (!Platform.isWindows) {
      return info['url'] as String? ?? '';
    }

    final url = _pickPlayableUrl(info);
    if (url == null || url.isEmpty) {
      throw Exception('yt-dlp returned no playable stream URL');
    }

    final server = await _ensureServer();
    final id = (++_nextId).toString();
    _streams[id] = _WindowsStreamInfo(url: url, headers: _readHeaders(info));

    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
      pathSegments: ['stream', id],
    ).toString();
  }

  Future<HttpServer> _ensureServer() async {
    final existing = _server;
    if (existing != null) return existing;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    unawaited(server.listen(_handleRequest).asFuture<void>());
    return server;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final id = request.uri.pathSegments.length >= 2 ? request.uri.pathSegments[1] : null;
    final stream = id == null ? null : _streams[id];
    if (stream == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    try {
      final upstream = await client.getUrl(Uri.parse(stream.url));
      for (final entry in stream.headers.entries) {
        upstream.headers.set(entry.key, entry.value);
      }
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        upstream.headers.set(HttpHeaders.rangeHeader, range);
      }

      final upstreamResponse = await upstream.close();
      request.response.statusCode = upstreamResponse.statusCode;
      for (final header in [
        HttpHeaders.acceptRangesHeader,
        HttpHeaders.contentLengthHeader,
        HttpHeaders.contentRangeHeader,
        HttpHeaders.contentTypeHeader,
        HttpHeaders.etagHeader,
        HttpHeaders.lastModifiedHeader,
      ]) {
        final value = upstreamResponse.headers.value(header);
        if (value != null) {
          request.response.headers.set(header, value);
        }
      }
      await upstreamResponse.pipe(request.response);
    } catch (e) {
      debugPrint('[WindowsStreamProxy] request failed: $e');
      try {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      } catch (_) {}
    } finally {
      client.close(force: true);
    }
  }

  String? _pickPlayableUrl(Map<String, dynamic> info) {
    final direct = info['url'] as String?;
    if (direct != null && direct.startsWith('http')) return direct;

    final requestedDownloads = info['requested_downloads'];
    if (requestedDownloads is List && requestedDownloads.isNotEmpty) {
      final first = requestedDownloads.first;
      if (first is Map && first['url'] is String) return first['url'] as String;
    }

    final requestedFormats = info['requested_formats'];
    if (requestedFormats is List && requestedFormats.isNotEmpty) {
      for (final format in requestedFormats.reversed) {
        if (format is Map && format['url'] is String) return format['url'] as String;
      }
    }

    final formats = info['formats'];
    if (formats is List && formats.isNotEmpty) {
      for (final format in formats.reversed) {
        if (format is Map && format['url'] is String && (format['acodec'] as String?) != 'none') {
          return format['url'] as String;
        }
      }
    }

    return null;
  }

  Map<String, String> _readHeaders(Map<String, dynamic> info) {
    final rawHeaders = info['http_headers'];
    final headers = <String, String>{};
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        final key = entry.key?.toString();
        final value = entry.value?.toString();
        if (key != null && key.isNotEmpty && value != null && value.isNotEmpty) {
          headers[key] = value;
        }
      }
    }
    headers.putIfAbsent(HttpHeaders.userAgentHeader, () => 'Mozilla/5.0');
    return headers;
  }

  Future<void> dispose() async {
    await _server?.close(force: true);
    _server = null;
    _streams.clear();
  }
}

class _WindowsStreamInfo {
  final String url;
  final Map<String, String> headers;
  const _WindowsStreamInfo({required this.url, required this.headers});
}
