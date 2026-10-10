// lib/core/audio/audio_service.dart

import 'dart:async';
import 'package:resonance/services/listening_statistics.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:resonance/core/audio/playback_interruption_controller.dart';
import 'package:path_provider/path_provider.dart';
import 'package:resonance/core/audio/audio_envelope_analyzer.dart';
import 'package:resonance/core/audio/loudness_normalization.dart';
import 'package:resonance/core/audio/playback_preferences.dart';
import 'package:resonance/core/audio/shuffle_order.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/models/playback_queue_snapshot.dart';
import 'package:resonance/services/discord_presence_service.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:metadata_god/metadata_god.dart';
import 'package:resonance/services/youtube/youtube_access_service.dart';
import 'package:resonance/services/youtube/youtube_playback_history_coordinator.dart';
import 'package:resonance/services/local_playback_history_coordinator.dart';
import 'package:resonance/services/android_auto_catalog.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';
import 'package:resonance/core/youtube/youtube_failure_classifier.dart';
import 'package:resonance/services/youtube/windows_ytdlp_runner.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/services/youtube/youtube_music_related_service.dart';

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

@immutable
class PlaybackRangePreviewState {
  const PlaybackRangePreviewState({
    required this.path,
    required this.position,
    required this.playing,
    this.loading = false,
  });
  final String path;
  final Duration position;
  final bool playing;
  final bool loading;
}

bool resolvedStreamCacheIsFresh(ResolvedYoutubeStream stream, DateTime resolvedAt, DateTime now, Duration maxAge) {
  if (now.difference(resolvedAt) >= maxAge) return false;
  final expirySeconds = int.tryParse(stream.uri.queryParameters['expire'] ?? '');
  if (expirySeconds == null) return true;
  final expiry = DateTime.fromMillisecondsSinceEpoch(expirySeconds * 1000);
  return now.isBefore(expiry.subtract(const Duration(minutes: 1)));
}

/// A safe, platform-neutral description of an output route exposed by the
/// Windows media_kit backend. Android routes audio through the OS and does
/// not expose an equivalent per-player device API in just_audio.
@immutable
class PlaybackOutputDevice {
  final String name;
  final String description;

  const PlaybackOutputDevice({required this.name, required this.description});

  const PlaybackOutputDevice.systemDefault() : this(name: 'auto', description: '');

  bool get isSystemDefault => name == 'auto';

  String get label => isSystemDefault ? 'System default' : (description.trim().isEmpty ? name : description.trim());

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is PlaybackOutputDevice && name == other.name && description == other.description;

  @override
  int get hashCode => Object.hash(name, description);
}

class NoAudioOutputDeviceException implements Exception {
  final String message;

  const NoAudioOutputDeviceException([
    this.message =
        'No audio output device is available. Connect or enable speakers, headphones, or another output device, then try again.',
  ]);

  @override
  String toString() => message;
}

/// A session-only entry used by standalone YouTube playback. It never enters
/// the user's persisted playlist; it simply lets next/previous follow the
/// visible Suggestions or YouTube Music Home order.
@immutable
class StandaloneStreamQueueItem {
  final String url;
  final String title;
  final String artist;
  final String? thumbnailUrl;

  const StandaloneStreamQueueItem({required this.url, required this.title, required this.artist, this.thumbnailUrl});
}

@visibleForTesting
PlaybackQueueSnapshot standaloneStreamQueueSnapshot({
  required List<StandaloneStreamQueueItem> items,
  required int currentIndex,
  required QueueLoopBehavior loopBehavior,
}) {
  if (items.isEmpty || currentIndex < 0 || currentIndex >= items.length) {
    return PlaybackQueueSnapshot(current: null, upcoming: const [], loopBehavior: loopBehavior, shuffled: false);
  }
  PlaybackQueueEntry asEntry(StandaloneStreamQueueItem item) => PlaybackQueueEntry(
    id: item.url,
    title: item.title,
    artist: item.artist,
    artworkUri: item.thumbnailUrl?.trim().isEmpty != false ? null : Uri.tryParse(item.thumbnailUrl!),
  );

  final upcomingItems = switch (loopBehavior) {
    QueueLoopBehavior.one => const <StandaloneStreamQueueItem>[],
    QueueLoopBehavior.off => items.sublist(currentIndex + 1),
    QueueLoopBehavior.all => <StandaloneStreamQueueItem>[
      ...items.sublist(currentIndex + 1),
      ...items.sublist(0, currentIndex),
    ],
  };
  return PlaybackQueueSnapshot(
    current: asEntry(items[currentIndex]),
    upcoming: List.unmodifiable(upcomingItems.map(asEntry)),
    loopBehavior: loopBehavior,
    shuffled: false,
  );
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
bool supportsPlaybackHealthMonitoring({required bool isWindows, required bool isStream}) => true;

/// Samples progress within one uninterrupted playback window. Seeking cancels
/// that window so a backward jump cannot be mistaken for a stalled source.
class PlaybackProgressWatchdog {
  Timer? _timer;

  void cancel() => _timer?.cancel();

  void start({
    required Duration grace,
    required Duration Function() position,
    Duration? initialPosition,
    required bool Function() shouldMonitor,
    required bool Function() isCompleted,
    required void Function() onProgress,
    required void Function() onStalled,
  }) {
    cancel();
    final baseline = initialPosition ?? position();
    _timer = Timer(grace, () {
      if (!shouldMonitor()) return;
      if (isCompleted() || playbackPositionAdvanced(baseline, position())) {
        onProgress();
      } else {
        onStalled();
      }
    });
  }
}

/// Native seeks stay serialized, but only the latest waiting target is applied.
/// Source replacement invalidates pending requests without touching its player.
class LatestSeekOperationQueue {
  Future<void> _tail = Future<void>.value();
  int _revision = 0;

  Future<void> get idle => _tail;

  void cancelPending() => _revision++;

  Future<void> run(Future<void> Function() operation, {required bool Function() isSourceCurrent}) {
    final revision = ++_revision;
    final current = _tail.then((_) async {
      if (revision != _revision || !isSourceCurrent()) return;
      await operation();
    });
    _tail = current.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return current;
  }
}

/// Keeps pause/open/source replacement commands from crossing on the native
/// player. A failed command still releases the queue for the next selection.
@visibleForTesting
class BackendSourceOperationQueue {
  Future<void> _tail = Future<void>.value();

  Future<void> get idle => _tail;

  Future<void> run(Future<void> Function() operation) {
    final current = _tail.then((_) => operation());
    _tail = current.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return current;
  }
}

@visibleForTesting
bool hasUsableOutputDeviceNames(Iterable<String> names) =>
    names.any((name) => name.trim().isNotEmpty && name != 'auto');

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

@visibleForTesting
int loopingStandaloneQueueIndex({required int currentIndex, required int offset, required int length}) {
  if (length <= 0 || currentIndex < 0 || currentIndex >= length) return -1;
  return (currentIndex + offset) % length;
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
  final AndroidAutoCatalog _androidAutoCatalog = AndroidAutoCatalog();
  late AudioPlayer _player;
  late AndroidLoudnessEnhancer _loudnessEnhancer;
  late AndroidEqualizer _androidEqualizer;
  mk.Player? _windowsPlayer;

  double savedVolume = 1.0;

  final ValueNotifier<double> volumeNotifier = ValueNotifier<double>(1.0);
  final ValueNotifier<double> trackVolumePercentNotifier = ValueNotifier<double>(0);
  Future<void>? _volumeApplyTask;
  bool _volumeApplyPending = false;
  Timer? _volumeSaveTimer;
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
  final Map<int, PlaylistShuffleOrder> _shuffleOrders = {};
  final _shuffleOrderForPaths = Expando<PlaylistShuffleOrder>();
  int _shuffleSelectionGeneration = -1;
  final _playlistOrderOperations = BackendSourceOperationQueue();
  StreamSubscription<PlaylistMutation>? _playlistMutationSubscription;
  final ValueNotifier<int> playbackModeRevision = ValueNotifier<int>(0);
  final ValueNotifier<bool> standaloneModeNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<PlaybackVisualState> playbackVisualNotifier = ValueNotifier<PlaybackVisualState>(
    const PlaybackVisualState(),
  );
  final ValueNotifier<YoutubeFailure?> youtubeFailureNotifier = ValueNotifier<YoutubeFailure?>(null);
  final ValueNotifier<TrackTransitionState> trackTransitionNotifier = ValueNotifier<TrackTransitionState>(
    const TrackTransitionState(),
  );
  final ValueNotifier<bool> uiVisibleNotifier = ValueNotifier<bool>(true);

  /// Available Windows output routes. Android delegates route selection to
  /// the system output switcher, so it exposes only the default route here.
  final ValueNotifier<List<PlaybackOutputDevice>> availableOutputDevicesNotifier =
      ValueNotifier<List<PlaybackOutputDevice>>(const [PlaybackOutputDevice.systemDefault()]);
  final ValueNotifier<PlaybackOutputDevice> selectedOutputDeviceNotifier = ValueNotifier<PlaybackOutputDevice>(
    const PlaybackOutputDevice.systemDefault(),
  );
  final ValueNotifier<String?> outputDeviceErrorNotifier = ValueNotifier<String?>(null);
  MediaItem? _pendingRestoredTrack;
  final Map<String, Uri?> _artUriCache = {};
  final AudioEnvelopeAnalyzer _envelopeAnalyzer = AudioEnvelopeAnalyzer();
  AudioEnvelope? _audioEnvelope;
  String? _audioEnvelopeTrackId;

  int? _standalonePlaylistNumber;
  int? _standalonePlaylistIndex;
  List<StandaloneStreamQueueItem> _standaloneStreamQueue = const [];
  int? _standaloneStreamQueueIndex;
  bool _standaloneRelatedEnabled = false;
  int _standaloneRelatedGeneration = 0;

  int _loadGeneration = 0;
  int? _activeTrackLoadGeneration;
  int? _pendingStreamSourceGeneration;
  int _seekGeneration = 0;
  int? _activeSeekGeneration;
  final _seekOperations = LatestSeekOperationQueue();
  int _crossfadeGeneration = 0;
  bool _crossfadeInProgress = false;
  bool _syncSessionActive = false;
  bool _syncPeerControlled = false;
  int _syncCommandDepth = 0;
  bool _equalizerEffectApplied = false;
  double _transitionVolumeMultiplier = 1.0;
  double _normalizationMultiplier = 1.0;
  late final Future<LoudnessProfileCache> _loudnessCacheFuture;
  LoudnessProfileCache? _loudnessCache;
  final LoudnessAnalyzer _loudnessAnalyzer = LoudnessAnalyzer();
  final List<String> _loudnessQueue = <String>[];
  final Set<String> _queuedLoudnessPaths = <String>{};
  bool _loudnessWorkerRunning = false;
  late Future<PlaybackPreferenceStore> _playbackPreferenceStore;
  PlaybackAdjustments _globalPlaybackAdjustments = PlaybackAdjustments.neutral;
  PlaybackAdjustments _requestedPlaybackAdjustments = PlaybackAdjustments.neutral;
  Future<void> _playbackAdjustmentQueue = Future<void>.value();
  final _backendSourceOperations = BackendSourceOperationQueue();
  Timer? _periodicPositionSaveTimer;
  final _playbackHealthWatchdog = PlaybackProgressWatchdog();
  bool? _lastPresencePlaying;
  late final _interruptions = PlaybackInterruptionController(
    pauseBackend: _pauseForAudioInterruption,
    resumeBackend: _playCurrentBackend,
    onError: (error, stack) => debugPrint('[PlayerHandler] Audio interruption failed: $error\n$stack'),
  );
  bool get _playbackRequested => _interruptions.canPlay;
  set _playbackRequested(bool value) => _interruptions.desiredPlaying = value;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  StreamSubscription<void>? _noisySubscription;
  AudioPlayer? _androidCrossfadePlayer;
  AudioSession? _androidAudioSession;
  bool _playbackUnavailable = false;
  int? _retryLoadGeneration;
  int? _handledFailureGeneration;
  final Set<String> _failedTrackIds = <String>{};
  String? _savedWindowsOutputDeviceName;

  final StreamController<Duration> _positionController = StreamController<Duration>.broadcast();
  final StreamController<Duration?> _durationController = StreamController<Duration?>.broadcast();

  // Tracks whether the current track is a stream (URL), for seek behaviour.
  bool _currentTrackIsStream = false;

  bool get isStandaloneMode => standaloneModeNotifier.value || mediaItem.value?.extras?['resonanceStandalone'] == true;
  bool get isStandaloneStreamSession =>
      isStandaloneMode &&
      _standalonePlaylistNumber == null &&
      (mediaItem.value?.id.startsWith('http://') == true || mediaItem.value?.id.startsWith('https://') == true);

  bool get syncPeerControlled => _syncPeerControlled;
  bool get syncSessionActive => _syncSessionActive;

  void setSyncSessionMode({required bool active, required bool peerControlled}) {
    _syncSessionActive = active;
    _syncPeerControlled = active && peerControlled;
    if (active && _crossfadeInProgress) {
      _crossfadeGeneration++;
      _crossfadeInProgress = false;
    }
  }

  Future<T> runSynchronizedCommand<T>(Future<T> Function() command) async {
    _syncCommandDepth++;
    try {
      return await command();
    } finally {
      _syncCommandDepth--;
    }
  }

  bool get _syncControlLocked => _syncPeerControlled && _syncCommandDepth == 0;

  double get visualizerAmplitude {
    final envelope = _audioEnvelope;
    final trackId = _audioEnvelopeTrackId;
    final current = mediaItem.value;
    if (envelope != null && trackId != null && current != null && _sameTrackId(trackId, current.id)) {
      return envelope.amplitudeAt(currentSourcePosition);
    }
    return current == null ? 0 : fallbackVisualizerAmplitude(current.id, currentSourcePosition);
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
      _standaloneStreamQueue = const [];
      _standaloneStreamQueueIndex = null;
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
  final Map<String, ({ResolvedYoutubeStream stream, DateTime resolvedAt})> _streamUrlCache = {};
  final Map<String, Future<ResolvedYoutubeStream>> _streamResolutionInFlight = {};
  final Map<int, String> _androidStreamRequests = {};
  final Set<int> _cancelledAndroidStreamRequests = {};
  int _nextAndroidStreamRequestId = 0;
  static const _streamCacheLifetime = Duration(minutes: 30);
  bool _windowsIsBuffering = false;
  bool _windowsIsCompleted = false;
  PlaybackRange _activePlaybackRange = PlaybackRange.full;
  final playbackRangeNotifier = ValueNotifier<PlaybackRange>(PlaybackRange.full);
  final playbackRangeRevision = ValueNotifier<int>(0);
  final playbackRangePreviewNotifier = ValueNotifier<PlaybackRangePreviewState?>(null);
  StreamSubscription<Duration>? _rangePreviewPositionSubscription;
  StreamSubscription<dynamic>? _rangePreviewPlayingSubscription;
  StreamSubscription<bool>? _rangePreviewCompletedSubscription;
  PlaybackRange _previewRange = PlaybackRange.full;
  Duration? _originalTrackDuration;
  mk.Player? _rangePreviewWindows;
  AudioPlayer? _rangePreviewAndroid;
  int _rangePreviewGeneration = 0;
  int? _rangePreviewOwner;
  bool _resumeAfterRangePreview = false;
  Duration _windowsPosition = Duration.zero;
  Duration _windowsDuration = Duration.zero;
  Duration _windowsBufferedPosition = Duration.zero;
  DateTime _lastPlaybackBroadcast = DateTime.fromMillisecondsSinceEpoch(0);
  // Next/previous can be invoked by a button, media key, gesture, or an
  // automatic completion callback at nearly the same time. Serialize those
  // transitions so each operation observes the queue state left by the one
  // before it instead of racing on the same current index.
  Future<void> _navigationTail = Future<void>.value();

  PlayerHandler({
    AudioSession? audioSession,
    @visibleForTesting mk.Player? windowsPlayer,
    @visibleForTesting Future<ResolvedYoutubeStream> Function(String)? streamResolver,
    YoutubeAccessService? youtubeAccessService,
    YoutubePlaybackHistoryCoordinator? youtubeHistoryCoordinator,
    LocalPlaybackHistoryCoordinator? localHistoryCoordinator,
  }) : _streamResolver = streamResolver,
       _youtubeAccessService = youtubeAccessService,
       _youtubeHistoryCoordinator = youtubeHistoryCoordinator,
       _localHistoryCoordinator = localHistoryCoordinator {
    _youtubeAccessService?.addListener(_handleYoutubeAccessChanged);
    _playbackPreferenceStore = PlaybackPreferenceStore.load();
    _loudnessCacheFuture = LoudnessProfileCache.load();
    if (Platform.isWindows) {
      final player = windowsPlayer ?? mk.Player(configuration: const mk.PlayerConfiguration(pitch: true));
      _windowsPlayer = player;
      _attachWindowsPlayer(player);
    } else {
      final backend = _createJustAudioBackend();
      _player = backend.player;
      _loudnessEnhancer = backend.loudnessEnhancer;
      _androidEqualizer = backend.equalizer;
      _attachJustAudioPlayer(_player);
      if (Platform.isAndroid) {
        if (audioSession != null) {
          _attachAudioSession(audioSession);
        } else {
          unawaited(AudioSession.instance.then(_attachAudioSession));
        }
      }
    }

    _playlistMutationSubscription = FileService.mutations.listen((mutation) {
      if (mutation.kind == PlaylistMutationKind.deleted) _shuffleOrders.remove(mutation.playlistNumber);
      // Queue views re-read the file and reconcile before publishing their rows.
      playbackModeRevision.value++;
    });
    WidgetsBinding.instance.addObserver(this);
    _periodicPositionSaveTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_isBackendPlaying) unawaited(saveCurrentPlaybackPosition());
    });
    unawaited(_initSavedState());
  }

  final YoutubeAccessService? _youtubeAccessService;
  final Future<ResolvedYoutubeStream> Function(String)? _streamResolver;
  final YoutubePlaybackHistoryCoordinator? _youtubeHistoryCoordinator;
  final LocalPlaybackHistoryCoordinator? _localHistoryCoordinator;
  int _youtubeAccessRevision = 0;
  final _forceAuthenticatedStreamIds = <String>{};

  void _cancelSupersededAndroidStreams(String? selectedUrl) {
    if (!Platform.isAndroid) return;
    for (final entry in _androidStreamRequests.entries.toList()) {
      if (entry.value == selectedUrl || !_cancelledAndroidStreamRequests.add(entry.key)) continue;
      _streamResolutionInFlight.remove(entry.value);
      unawaited(
        const MethodChannel(
          'resonance/android_youtube',
        ).invokeMethod<void>('cancelStreamData', {'requestId': entry.key}).catchError((Object _) {}),
      );
    }
  }

  void _handleYoutubeAccessChanged() {
    final revision = _youtubeAccessService?.revision ?? 0;
    if (revision == _youtubeAccessRevision) return;
    _youtubeAccessRevision = revision;
    _streamUrlCache.clear();
    _streamResolutionInFlight.clear();
    _forceAuthenticatedStreamIds.clear();
  }

  ({AudioPlayer player, AndroidLoudnessEnhancer loudnessEnhancer, AndroidEqualizer equalizer})
  _createJustAudioBackend() {
    final loudnessEnhancer = AndroidLoudnessEnhancer();
    final equalizer = AndroidEqualizer();
    final player = AudioPlayer(
      handleInterruptions: !Platform.isAndroid,
      handleAudioSessionActivation: !Platform.isAndroid,
      audioPipeline: AudioPipeline(androidAudioEffects: [loudnessEnhancer, equalizer]),
    );
    return (player: player, loudnessEnhancer: loudnessEnhancer, equalizer: equalizer);
  }

  void _attachAudioSession(AudioSession session) {
    if (_interruptions.disposed) return;
    _androidAudioSession = session;
    _interruptionSubscription = session.interruptionEventStream.listen((event) {
      if (event.begin) unawaited(stopPlaybackRangePreview(resume: false));
      _interruptions.handle(event);
    });
    _noisySubscription = session.becomingNoisyEventStream.listen((_) {
      _playbackRequested = false;
      unawaited(
        _pauseForAudioInterruption().catchError((Object error) {
          debugPrint('[PlayerHandler] Headphone disconnect pause failed: $error');
        }),
      );
    });
  }

  Future<void> _pauseForAudioInterruption() async {
    await stopPlaybackRangePreview(resume: false);
    _playbackHealthWatchdog.cancel();
    _crossfadeGeneration++;
    _crossfadeInProgress = false;
    await Future.wait([_player.pause(), if (_androidCrossfadePlayer case final incoming?) incoming.pause()]);
    await _applyOutputVolume();
    _updatePlaybackState();
    unawaited(saveCurrentPlaybackPosition());
  }

  Future<void> _startJustAudioPlayer(AudioPlayer player, int generation) async {
    bool isCurrent() =>
        _loadGeneration == generation &&
        _playbackRequested &&
        (identical(player, _player) || identical(player, _androidCrossfadePlayer));
    if (!isCurrent()) return;
    if (Platform.isAndroid) {
      await _interruptions.pauseComplete;
      if (!isCurrent()) return;
      final session = _androidAudioSession ?? await AudioSession.instance;
      if (!isCurrent()) return;
      final granted = await session.setActive(true);
      if (!isCurrent()) return;
      if (!granted) {
        // Rejected focus is not a stalled stream. Do not retry over a call.
        _playbackRequested = false;
        await _pauseForAudioInterruption();
        return;
      }
    }
    // just_audio's play future lasts until the track stops; never await it.
    unawaited(
      player.play().catchError((Object error, StackTrace stack) async {
        if (!isCurrent()) return;
        if (identical(player, _androidCrossfadePlayer)) _crossfadeGeneration++;
        debugPrint('[PlayerHandler] Playback start failed: $error\n$stack');
        await _handlePlaybackFailure(generation, error, allowStreamRecovery: _currentTrackIsStream);
      }),
    );
  }

  void _attachWindowsPlayer(mk.Player player) {
    player.stream.audioDevices.listen((devices) {
      if (!identical(player, _windowsPlayer)) return;
      final normalized = _normalizeOutputDevices(devices);
      availableOutputDevicesNotifier.value = normalized;
      if (_hasUsableOutputDevice(devices)) {
        outputDeviceErrorNotifier.value = null;
      }
      final selected = selectedOutputDeviceNotifier.value;
      final selectedStillAvailable = selected.isSystemDefault || devices.any((device) => device.name == selected.name);
      if (!selectedStillAvailable) {
        // A USB/Bluetooth/HDMI endpoint may disappear while a track is
        // playing. Fall back to the system route before the next open.
        unawaited(setOutputDevice('auto', persist: true));
      }
      if (_playbackRequested && !_hasUsableOutputDevice(devices)) {
        outputDeviceErrorNotifier.value = const NoAudioOutputDeviceException().message;
        unawaited(_markPlaybackUnavailable(_loadGeneration));
      }
      final savedName = _savedWindowsOutputDeviceName;
      if (savedName != null) {
        _savedWindowsOutputDeviceName = null;
        unawaited(setOutputDevice(savedName, persist: false));
      }
    });
    player.stream.audioDevice.listen((device) {
      if (!identical(player, _windowsPlayer)) return;
      final known = availableOutputDevicesNotifier.value.firstWhere(
        (candidate) => candidate.name == device.name,
        orElse: () => PlaybackOutputDevice(name: device.name, description: device.description),
      );
      selectedOutputDeviceNotifier.value = known;
    });
    player.stream.playing.listen((playing) {
      if (!identical(player, _windowsPlayer)) return;
      _updatePlaybackState();
      unawaited(_updatePresenceForPlaying(playing));
    });
    player.stream.position.listen((position) {
      if (!identical(player, _windowsPlayer)) return;
      if (_pendingStreamSourceGeneration == _loadGeneration || _playbackUnavailable) return;
      _windowsPosition = position;
      _positionController.add(_currentPosition);
      _updatePlaybackState();
      _maybeStartAutomaticCrossfade();
    });
    player.stream.duration.listen((duration) {
      if (!identical(player, _windowsPlayer)) return;
      if (_pendingStreamSourceGeneration == _loadGeneration || _playbackUnavailable) return;
      _windowsDuration = duration;
      _durationController.add(_currentDuration);
      final currentItem = mediaItem.value;
      if (currentItem != null && duration > Duration.zero) {
        mediaItem.add(currentItem.copyWith(duration: _currentDuration));
      }
      _updatePlaybackState();
    });
    player.stream.buffer.listen((position) {
      if (!identical(player, _windowsPlayer)) return;
      if (_pendingStreamSourceGeneration == _loadGeneration || _playbackUnavailable) return;
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
      if (_pendingStreamSourceGeneration == _loadGeneration || _playbackUnavailable) return;
      _windowsIsCompleted = completed;
      _updatePlaybackState();
      if (_crossfadeInProgress || _activeTrackLoadGeneration != null) return;
      final genAtCompletion = _loadGeneration;
      await _clearCurrentPlaybackPosition();
      if (_loadGeneration != genAtCompletion) return;
      if (currentLoopMode == LoopMode.one) {
        ListeningStatistics.instance.onSessionEnded();
        await player.seek(_activePlaybackRange.start);
        if (_loadGeneration != genAtCompletion) return;
        await player.play();
      } else if (_loadGeneration == genAtCompletion) {
        await _queueNavigation(_advanceAfterCompletion);
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

  List<PlaybackOutputDevice> _normalizeOutputDevices(List<mk.AudioDevice> devices) {
    final result = <PlaybackOutputDevice>[const PlaybackOutputDevice.systemDefault()];
    for (final device in devices) {
      if (device.name.trim().isEmpty || device.name == 'auto') continue;
      if (result.any((candidate) => candidate.name == device.name)) continue;
      result.add(PlaybackOutputDevice(name: device.name, description: device.description));
    }
    return List.unmodifiable(result);
  }

  bool _hasUsableOutputDevice(List<mk.AudioDevice> devices) =>
      hasUsableOutputDeviceNames(devices.map((device) => device.name));

  bool get supportsOutputDeviceSelection => Platform.isWindows;

  /// Selects a Windows output route and persists its stable media_kit name.
  /// Returns false instead of throwing if the endpoint disappeared or the
  /// native backend cannot switch to it.
  Future<bool> setOutputDevice(String name, {bool persist = true}) async {
    if (!Platform.isWindows || _windowsPlayer == null) return false;
    final player = _windowsPlayer!;
    try {
      await player.platform?.waitForPlayerInitialization;
      final device = name == 'auto'
          ? mk.AudioDevice.auto()
          : player.state.audioDevices.firstWhere((candidate) => candidate.name == name);
      await player.setAudioDevice(device);
      final selected = device.name == 'auto'
          ? const PlaybackOutputDevice.systemDefault()
          : PlaybackOutputDevice(name: device.name, description: device.description);
      selectedOutputDeviceNotifier.value = selected;
      outputDeviceErrorNotifier.value = null;
      if (persist) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('windows_output_device', device.name);
      }
      return true;
    } catch (error) {
      debugPrint('[PlayerHandler] Could not select Windows output device "$name": $error');
      outputDeviceErrorNotifier.value =
          'The selected output is unavailable. Choose another device or connect an audio output.';
      if (name != 'auto') {
        try {
          await player.setAudioDevice(mk.AudioDevice.auto());
          selectedOutputDeviceNotifier.value = const PlaybackOutputDevice.systemDefault();
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('windows_output_device', 'auto');
        } catch (fallbackError) {
          debugPrint('[PlayerHandler] Could not fall back to the system output: $fallbackError');
        }
      }
      return false;
    }
  }

  Future<void> refreshOutputDevices() async {
    if (!Platform.isWindows || _windowsPlayer == null) return;
    try {
      await _windowsPlayer!.platform?.waitForPlayerInitialization;
      availableOutputDevicesNotifier.value = _normalizeOutputDevices(_windowsPlayer!.state.audioDevices);
    } catch (error) {
      debugPrint('[PlayerHandler] Could not refresh output devices: $error');
    }
  }

  Future<void> _ensureWindowsAudioOutput(mk.Player player) async {
    await player.platform?.waitForPlayerInitialization;
    final devices = player.state.audioDevices;
    availableOutputDevicesNotifier.value = _normalizeOutputDevices(devices);
    if (!_hasUsableOutputDevice(devices)) {
      throw const NoAudioOutputDeviceException();
    }
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
      if (_pendingStreamSourceGeneration == _loadGeneration || _playbackUnavailable) return;
      _durationController.add(duration);
      final currentItem = mediaItem.value;
      if (currentItem != null && duration != null) {
        mediaItem.add(currentItem.copyWith(duration: duration));
      }
      _updatePlaybackState();
    });

    player.positionStream.listen((position) {
      if (!identical(player, _player)) return;
      if (_pendingStreamSourceGeneration == _loadGeneration || _playbackUnavailable) return;
      _positionController.add(position);
      _updatePlaybackState();
      _maybeStartAutomaticCrossfade();
    });

    player.processingStateStream.listen((state) async {
      if (!identical(player, _player)) return;
      _updatePlaybackState();
      if (state == ProcessingState.completed) {
        if (_crossfadeInProgress || _activeTrackLoadGeneration != null || !_playbackRequested || _playbackUnavailable) {
          return;
        }
        final genAtCompletion = _loadGeneration;
        await _clearCurrentPlaybackPosition();
        if (_loadGeneration != genAtCompletion || !_playbackRequested) return;
        if (currentLoopMode == LoopMode.one) {
          ListeningStatistics.instance.onSessionEnded();
          await player.seek(Duration.zero);
          if (_loadGeneration != genAtCompletion) return;
          unawaited(_startJustAudioPlayer(player, genAtCompletion));
        } else if (_loadGeneration == genAtCompletion) {
          await _queueNavigation(_advanceAfterCompletion);
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
  Future<ResolvedYoutubeStream> _resolveStream(String url) async {
    final accessRevision = _youtubeAccessService?.revision ?? 0;
    final cached = _streamUrlCache[url];
    if (cached != null &&
        cached.stream.accessRevision == accessRevision &&
        resolvedStreamCacheIsFresh(cached.stream, cached.resolvedAt, DateTime.now(), _streamCacheLifetime)) {
      debugPrint('[PlayerHandler] Stream URL cache hit for $url');
      return cached.stream;
    }
    final pending = _streamResolutionInFlight[url];
    if (pending != null) return pending;

    final resolution = _resolveStreamUncached(url, accessRevision);
    _streamResolutionInFlight[url] = resolution;
    try {
      return await resolution;
    } finally {
      if (identical(_streamResolutionInFlight[url], resolution)) {
        _streamResolutionInFlight.remove(url);
      }
    }
  }

  Future<ResolvedYoutubeStream> _resolveStreamUncached(String url, int accessRevision) async {
    final clock = Stopwatch()..start();
    debugPrint('[PlayerHandler] Resolving stream URL for $url');
    late ResolvedYoutubeStream resolved;

    if (_streamResolver case final resolver?) {
      resolved = await resolver(url);
    } else if (Platform.isWindows) {
      final arguments = [
        '--dump-single-json',
        '--no-warnings',
        '--no-playlist',
        '--skip-download',
        '--format',
        'bestaudio[has_drm!=true]/best[has_drm!=true]',
        url,
      ];
      final runner = WindowsYtdlpRunner.instance;
      final authenticated = _youtubeAccessService?.isConfigured == true;
      final useGuest = !authenticated || !_forceAuthenticatedStreamIds.contains(url);
      late WindowsYtdlpResult result;
      try {
        result = await runner.run(
          arguments,
          guest: useGuest,
          reportFailure: !authenticated || !useGuest,
          sourceUrl: url,
          requireOutput: true,
        );
      } on YoutubeFailure {
        if (!authenticated || !useGuest) rethrow;
        _forceAuthenticatedStreamIds.add(url);
        result = await runner.run(arguments, sourceUrl: url, requireOutput: true);
      }
      final info = jsonDecode(result.stdout) as Map<String, dynamic>;
      final selected = _pickWindowsPlayableFormat(info);
      final streamUrl = selected?['url']?.toString();
      if (streamUrl == null || !streamUrl.startsWith('http')) {
        throw StateError('yt-dlp returned no playable stream URL');
      }
      resolved = ResolvedYoutubeStream(
        uri: Uri.parse(streamUrl),
        headers: Map.unmodifiable(_readWindowsStreamHeaders(selected!, info)),
        accessRevision: accessRevision,
        title: info['title']?.toString(),
        artist: (info['uploader'] ?? info['channel'])?.toString(),
        thumbnailUrl: info['thumbnail']?.toString(),
      );
    } else if (Platform.isAndroid) {
      const channel = MethodChannel('resonance/android_youtube');
      final requestId = ++_nextAndroidStreamRequestId;
      _androidStreamRequests[requestId] = url;
      try {
        final result = await channel.invokeMethod<Object?>('getStreamData', {
          'url': url,
          'requestId': requestId,
          'forceAuthenticated': _forceAuthenticatedStreamIds.contains(url),
        });
        if (_cancelledAndroidStreamRequests.contains(requestId)) throw StateError('Stream request superseded');
        if (result is! Map) throw StateError('Android bridge returned invalid stream data');
        final data = Map<String, Object?>.from(result);
        final streamUrl = data['url']?.toString();
        if (streamUrl == null || streamUrl.isEmpty) throw StateError('Android bridge returned empty stream URL');
        final rawHeaders = data['headers'];
        final headers = rawHeaders is Map
            ? rawHeaders.map((key, value) => MapEntry(key.toString(), value.toString()))
            : const <String, String>{};
        resolved = ResolvedYoutubeStream(
          uri: Uri.parse(streamUrl),
          headers: Map.unmodifiable(headers),
          accessRevision: accessRevision,
          title: data['title']?.toString(),
          artist: data['artist']?.toString(),
          thumbnailUrl: data['thumbnail']?.toString(),
        );
      } catch (error) {
        if (_cancelledAndroidStreamRequests.contains(requestId)) {
          throw StateError('Stream request superseded');
        }
        final failure = YoutubeFailureClassifier.classify(
          error,
          authenticated: _youtubeAccessService?.isConfigured ?? false,
          sourceUrl: url,
        );
        _youtubeAccessService?.observeFailure(failure);
        throw failure;
      } finally {
        _androidStreamRequests.remove(requestId);
        _cancelledAndroidStreamRequests.remove(requestId);
      }
    } else {
      throw UnsupportedError('Streaming not supported on this platform');
    }

    if ((_youtubeAccessService?.revision ?? 0) != accessRevision) {
      throw StateError('YouTube access changed during stream resolution');
    }
    if (!_streamUrlCache.containsKey(url) && _streamUrlCache.length >= 96) {
      _streamUrlCache.remove(_streamUrlCache.keys.first);
    }
    _streamUrlCache[url] = (stream: resolved, resolvedAt: DateTime.now());
    debugPrint('[PlayerHandler] Resolved YouTube stream in ${clock.elapsedMilliseconds} ms');
    return resolved;
  }

  /// Warms the first likely selections while the user browses. Foreground
  /// playback joins an in-flight resolution for the same URL.
  Future<void> warmStreamCandidates(Iterable<String> urls) async {
    final candidates = urls
        .where((url) => url.startsWith('https://') || url.startsWith('http://'))
        .toSet()
        .take(Platform.isAndroid ? 1 : 4);
    await Future.wait(
      candidates.map((url) async {
        try {
          await _resolveStream(url);
        } catch (error) {
          debugPrint('[PlayerHandler] Could not warm stream $url: $error');
        }
      }),
    );
  }

  Future<void> _prefetchAdjacentStreams(int generation) async {
    final items = _standaloneStreamQueue;
    final index = _standaloneStreamQueueIndex;
    if (_loadGeneration != generation || index == null || items.length < 2) return;
    // Resolve the likely next selection first. The previous selection is
    // usually already cached, but warm it as well when a session starts here.
    await Future.wait(
      (Platform.isAndroid ? [1] : [1, -1]).map((offset) async {
        if (_loadGeneration != generation) return;
        final target = items[loopingStandaloneQueueIndex(currentIndex: index, offset: offset, length: items.length)];
        if (target.url == mediaItem.value?.id) return;
        try {
          await _resolveStream(target.url);
        } catch (error) {
          // Prefetch is optional. Foreground loading reports the real failure.
          debugPrint('[PlayerHandler] Could not prefetch stream ${target.url}: $error');
        }
      }),
    );
  }

  Future<void> _prefetchPlaylistNeighborStreams(int generation) async {
    if (_loadGeneration != generation || (isStandaloneMode && _standalonePlaylistNumber == null)) return;
    final current = mediaItem.value;
    if (current == null) return;
    final playlist = await _effectivePlaybackOrder(playlistNumber: _standalonePlaylistNumber);
    if (_loadGeneration != generation || playlist.length < 2) return;
    final index = _currentPlaylistIndex(playlist, current.id);
    if (index < 0) return;
    final neighbors = [
      playlist[(index + 1) % playlist.length],
      playlist[(index - 1 + playlist.length) % playlist.length],
    ];
    await warmStreamCandidates(neighbors);
  }

  Future<AudioSource> _buildAudioSource(String filePath, {PlaybackRange? range}) async {
    final isStream = filePath.startsWith('http://') || filePath.startsWith('https://');
    if (isStream) {
      final resolved = await _resolveStream(filePath);
      return AudioSource.uri(resolved.uri, headers: resolved.headers);
    } else {
      final bounds = range ?? await playbackRangeFor(filePath);
      final source = AudioSource.uri(Uri.file(filePath));
      return bounds.isFull ? source : ClippingAudioSource(child: source, start: bounds.start, end: bounds.end);
    }
  }

  Future<mk.Media> _buildMediaKitMedia(String filePath, {PlaybackRange? range}) async {
    final isStream = filePath.startsWith('http://') || filePath.startsWith('https://');
    if (isStream) {
      final resolved = await _resolveStream(filePath);
      return mk.Media(resolved.uri.toString(), httpHeaders: resolved.headers);
    }
    final bounds = range ?? await playbackRangeFor(filePath);
    return mk.Media(Uri.file(filePath).toString(), start: bounds.start, end: bounds.end);
  }

  bool get _isWindowsPlaying => _windowsPlayer?.state.playing ?? false;

  bool get _isBackendPlaying => Platform.isWindows ? _isWindowsPlaying : _player.playing;

  Duration get _currentPosition => _playbackUnavailable
      ? Duration.zero
      : (Platform.isWindows
            ? _activePlaybackRange.relative(_windowsPosition, sourceDuration: _windowsDuration)
            : _player.position);

  Duration? get _currentDuration => _playbackUnavailable
      ? null
      : (Platform.isWindows ? _activePlaybackRange.durationOf(_windowsDuration) : _player.duration);

  Duration get currentSourcePosition => _activePlaybackRange.source(_currentPosition);
  PlaybackRange get currentPlaybackRange => _activePlaybackRange;
  void _setActivePlaybackRange(PlaybackRange range) {
    _activePlaybackRange = range;
    playbackRangeNotifier.value = range;
  }

  Future<PlaybackRange> savedPlaybackRangeFor(String path) async => (await _playbackPreferenceStore).rangeFor(path);
  Duration? get currentSourceDuration => Platform.isWindows
      ? (_windowsDuration > Duration.zero ? _windowsDuration : _originalTrackDuration)
      : _originalTrackDuration ?? _player.duration;
  Duration sourcePositionFor(Duration relative) => _activePlaybackRange.source(relative);
  Duration relativePositionFor(Duration source) =>
      _activePlaybackRange.relative(source, sourceDuration: currentSourceDuration);

  Future<Duration?> originalDurationFor(String path) async {
    if (path.startsWith('http://') || path.startsWith('https://')) return null;
    if (mediaItem.value?.id == path &&
        _pendingStreamSourceGeneration != _loadGeneration &&
        (Platform.isWindows || _activePlaybackRange.isFull || _originalTrackDuration != null) &&
        currentSourceDuration != null &&
        currentSourceDuration! > Duration.zero) {
      return currentSourceDuration;
    }
    final metadata = await MetadataGod.readMetadata(file: path);
    final ms = metadata.durationMs;
    return ms == null || !ms.isFinite || ms <= 0 ? null : Duration(milliseconds: ms.round());
  }

  Future<PlaybackRange> playbackRangeFor(String path) async {
    if (path.startsWith('http://') || path.startsWith('https://')) return PlaybackRange.full;
    final saved = (await _playbackPreferenceStore).rangeFor(path);
    if (saved.isFull) return saved;
    Duration? duration;
    try {
      duration = await originalDurationFor(path);
    } catch (_) {}
    return saved.bounded(duration);
  }

  Future<void> _configureWindowsRange(mk.Player player, PlaybackRange range) async {
    final platform = player.platform;
    if (platform is mk.NativePlayer) {
      // mpv retains start/end properties when a later Media has null bounds.
      await platform.setProperty('start', (range.start.inMicroseconds / 1000000).toString());
      await platform.setProperty('end', range.end == null ? 'none' : (range.end!.inMicroseconds / 1000000).toString());
    }
  }

  Future<void> savePlaybackRange(String path, PlaybackRange range) async {
    if (_syncControlLocked) return;
    final selectedGeneration = _loadGeneration;
    final store = await _playbackPreferenceStore;
    final bounded = range.bounded(await originalDurationFor(path));
    if (!await store.saveRange(path, bounded)) throw StateError('Could not save playback range.');
    playbackRangeRevision.value++;
    await store.clearPosition(path);
    if (selectedGeneration != _loadGeneration) return;
    await _reloadActivePlaybackRange(path);
  }

  Future<void> _reloadActivePlaybackRange(String path) async {
    final selectedGeneration = _loadGeneration;
    final item = mediaItem.value;
    if (item?.id != path || _pendingRestoredTrack != null) return;
    final sourcePosition = currentSourcePosition;
    final playing = _isBackendPlaying;
    final queue = _standaloneStreamQueue;
    final queueIndex = _standaloneStreamQueueIndex;
    await loadTrack(
      path,
      item!.title,
      item.artist ?? '',
      artworkUri: item.artUri,
      standalone: standaloneModeNotifier.value,
      standalonePlaylistNumber: _standalonePlaylistNumber,
      standalonePlaylistIndex: _standalonePlaylistIndex,
      playWhenReady: false,
      preservePosition: false,
    );
    if (_loadGeneration != selectedGeneration + 1 || mediaItem.value?.id != path) return;
    _standaloneStreamQueue = queue;
    _standaloneStreamQueueIndex = queueIndex;
    final relative = relativePositionFor(sourcePosition);
    await seek(currentDuration != null && relative >= currentDuration! ? Duration.zero : relative);
    if (playing && _loadGeneration == selectedGeneration + 1) await play();
  }

  /// Audition through an isolated backend while the real queue stays paused.
  /// Any normal transport command invalidates preview ownership.
  Future<void> previewPlaybackRange(String path, PlaybackRange range) async {
    if (_syncControlLocked || _interruptions.blocked) return;
    final owner = _loadGeneration;
    final previousPreviewGeneration = _rangePreviewGeneration;
    final wasPlaying = _isBackendPlaying || _resumeAfterRangePreview;
    await stopPlaybackRangePreview(resume: false);
    if (owner != _loadGeneration || _rangePreviewGeneration != previousPreviewGeneration + 1) return;
    await pause();
    if (owner != _loadGeneration ||
        _rangePreviewGeneration != previousPreviewGeneration + 2 ||
        _syncControlLocked ||
        _interruptions.blocked) {
      return;
    }
    final generation = ++_rangePreviewGeneration;
    _rangePreviewOwner = owner;
    _resumeAfterRangePreview = wasPlaying;
    _previewRange = range;
    playbackRangePreviewNotifier.value = PlaybackRangePreviewState(
      path: path,
      position: range.start,
      playing: false,
      loading: true,
    );
    void publish(Duration position, bool playing, {bool loading = false}) {
      if (generation != _rangePreviewGeneration || owner != _loadGeneration) return;
      playbackRangePreviewNotifier.value = PlaybackRangePreviewState(
        path: path,
        position: position,
        playing: playing,
        loading: loading,
      );
    }

    try {
      if (Platform.isWindows) {
        final player = mk.Player();
        _rangePreviewWindows = player;
        _rangePreviewPositionSubscription = player.stream.position.listen(
          (position) => publish(position, player.state.playing && !player.state.completed),
        );
        _rangePreviewPlayingSubscription = player.stream.playing.listen(
          (playing) => publish(player.state.position, playing && !player.state.completed),
        );
        _rangePreviewCompletedSubscription = player.stream.completed.listen((completed) {
          if (completed) publish(range.end ?? player.state.duration, false);
        });
        await player.setVolume((volumeNotifier.value * 100).clamp(0, 100));
        await _configureWindowsRange(player, range);
        if (generation != _rangePreviewGeneration || owner != _loadGeneration) return;
        await player.open(await _buildMediaKitMedia(path, range: range), play: false);
        if (generation == _rangePreviewGeneration && owner == _loadGeneration) await player.play();
      } else {
        final player = AudioPlayer(handleInterruptions: false, handleAudioSessionActivation: !Platform.isAndroid);
        _rangePreviewAndroid = player;
        _rangePreviewPositionSubscription = player.positionStream.listen(
          (position) =>
              publish(range.source(position), player.playing && player.processingState != ProcessingState.completed),
        );
        _rangePreviewPlayingSubscription = player.playerStateStream.listen(
          (state) => publish(
            range.source(player.position),
            state.playing && state.processingState != ProcessingState.completed,
            loading: state.processingState == ProcessingState.loading,
          ),
        );
        await player.setVolume(volumeNotifier.value.clamp(0, 1));
        await player.setAudioSource(await _buildAudioSource(path, range: range));
        if (Platform.isAndroid && generation == _rangePreviewGeneration && owner == _loadGeneration) {
          final session = _androidAudioSession ?? await AudioSession.instance;
          if (!await session.setActive(true)) throw StateError('Audio focus unavailable.');
        }
        if (generation == _rangePreviewGeneration && owner == _loadGeneration && !_interruptions.blocked) {
          unawaited(player.play().catchError((Object _) {}));
        }
      }
    } catch (_) {
      if (generation == _rangePreviewGeneration) await stopPlaybackRangePreview();
      rethrow;
    }
  }

  Future<void> stopPlaybackRangePreview({bool resume = true}) async {
    final generation = ++_rangePreviewGeneration;
    final owner = _rangePreviewOwner;
    final windows = _rangePreviewWindows;
    final android = _rangePreviewAndroid;
    final restore =
        resume && _resumeAfterRangePreview && _rangePreviewOwner == _loadGeneration && !_interruptions.blocked;
    _rangePreviewWindows = null;
    _rangePreviewAndroid = null;
    _rangePreviewOwner = null;
    _resumeAfterRangePreview = false;
    playbackRangePreviewNotifier.value = null;
    final positionSub = _rangePreviewPositionSubscription;
    final playingSub = _rangePreviewPlayingSubscription;
    final completedSub = _rangePreviewCompletedSubscription;
    _rangePreviewPositionSubscription = null;
    _rangePreviewPlayingSubscription = null;
    _rangePreviewCompletedSubscription = null;
    await positionSub?.cancel();
    await playingSub?.cancel();
    await completedSub?.cancel();
    if (windows != null) {
      await windows.dispose().catchError((Object error) {
        debugPrint('[PlayerHandler] Preview cleanup failed: $error');
      });
    }
    if (android != null) {
      await android.dispose().catchError((Object error) {
        debugPrint('[PlayerHandler] Preview cleanup failed: $error');
      });
    }
    if (restore && generation == _rangePreviewGeneration && owner == _loadGeneration && !_interruptions.blocked) {
      await play();
    }
  }

  Duration get currentPosition => _currentPosition;

  Future<void> seekPlaybackRangePreview(Duration sourcePosition) async {
    final generation = _rangePreviewGeneration;
    final range = _previewRange;
    final relative = range.relative(sourcePosition);
    final windows = _rangePreviewWindows;
    final android = _rangePreviewAndroid;
    if (generation != _rangePreviewGeneration) return;
    if (windows != null) await windows.seek(range.source(relative));
    if (android != null) await android.seek(relative);
  }

  Duration? get currentDuration => _currentDuration;

  Duration get _streamStartupGrace => Platform.isWindows ? const Duration(seconds: 4) : const Duration(seconds: 6);

  String _failureTrackKey(String trackId) {
    if (trackId.startsWith('http://') || trackId.startsWith('https://')) return trackId;
    final normalized = p.normalize(p.absolute(trackId));
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  void _armPlaybackHealthCheck(
    int generation, {
    Duration grace = const Duration(seconds: 5),
    Object? reason,
    Duration? initialPosition,
  }) {
    _playbackHealthWatchdog.cancel();
    final monitoredStream = _currentTrackIsStream;
    if (!supportsPlaybackHealthMonitoring(isWindows: Platform.isWindows, isStream: monitoredStream) ||
        !_playbackRequested ||
        _playbackUnavailable ||
        _activeSeekGeneration != null) {
      return;
    }
    final seekGeneration = _seekGeneration;
    final windowsPlayer = Platform.isWindows ? _windowsPlayer : null;
    final justAudioPlayer = Platform.isWindows ? null : _player;
    bool isCompleted() =>
        Platform.isWindows ? _windowsIsCompleted : _player.processingState == ProcessingState.completed;
    _playbackHealthWatchdog.start(
      grace: grace,
      position: () => _currentPosition,
      initialPosition: initialPosition,
      shouldMonitor: () =>
          _loadGeneration == generation &&
          _seekGeneration == seekGeneration &&
          _activeSeekGeneration == null &&
          _playbackRequested &&
          !_playbackUnavailable &&
          _currentTrackIsStream == monitoredStream &&
          (Platform.isWindows ? identical(windowsPlayer, _windowsPlayer) : identical(justAudioPlayer, _player)),
      isCompleted: isCompleted,
      onProgress: () {
        _failedTrackIds.clear();
        _retryLoadGeneration = null;
        if (monitoredStream && !isCompleted()) {
          _armPlaybackHealthCheck(generation, grace: const Duration(seconds: 8));
        }
      },
      onStalled: () => unawaited(
        _handlePlaybackFailure(generation, reason ?? 'playback made no progress', allowStreamRecovery: monitoredStream),
      ),
    );
  }

  Future<void> _handlePlaybackFailure(int generation, Object reason, {bool allowStreamRecovery = false}) async {
    final recoveringStream = _currentTrackIsStream && allowStreamRecovery;
    if (_loadGeneration != generation ||
        _activeSeekGeneration != null ||
        _handledFailureGeneration == generation ||
        !_playbackRequested ||
        (_currentTrackIsStream && !recoveringStream)) {
      return;
    }
    final current = mediaItem.value;
    if (current == null) return;
    _handledFailureGeneration = generation;
    _playbackHealthWatchdog.cancel();
    debugPrint('[PlayerHandler] Playback failed for "${current.id}" (generation $generation): $reason');

    if (_retryLoadGeneration != generation) {
      if (recoveringStream) {
        _streamUrlCache.remove(current.id);
        if (_youtubeAccessService?.isConfigured == true) {
          _forceAuthenticatedStreamIds.add(current.id);
        }
      }
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
    if (!_playbackRequested) return;
    final playlistNumber = _standalonePlaylistNumber;
    if (isStandaloneMode && playlistNumber == null) {
      await _markPlaybackUnavailable(generation);
      return;
    }
    final playlist = await _effectivePlaybackOrder(playlistNumber: playlistNumber);
    if (_loadGeneration != generation || !_playbackRequested) return;
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
    if (_loadGeneration != generation || !_playbackRequested) return;
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
    if (generation != null && _loadGeneration != generation) return;
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
    final streamSourcePending = _pendingStreamSourceGeneration == _loadGeneration;
    final playing =
        !_playbackUnavailable && !streamSourcePending && (Platform.isWindows ? _isWindowsPlaying : _player.playing);
    final currentItem = mediaItem.value;
    ListeningStatistics.instance.observe(
      item: currentItem,
      playing: playing,
      position: _currentPosition,
      speed: speedNotifier.value,
      playlist: _standalonePlaylistNumber ?? (isStandaloneMode ? null : FileService.activePlaylistNumber),
      loading: streamSourcePending || _playbackUnavailable,
    );
    if (currentItem == null) {
      _youtubeHistoryCoordinator?.onSessionEnded();
      _localHistoryCoordinator?.onSessionEnded();
    } else {
      _youtubeHistoryCoordinator?.onPlaybackSnapshot(
        mediaIdentity: currentItem.id,
        playing: playing,
        position: _currentPosition,
      );
      _localHistoryCoordinator?.onPlaybackSnapshot(item: currentItem, playing: playing, position: _currentPosition);
    }
    final backendProcessingState = _playbackUnavailable
        ? AudioProcessingState.idle
        : streamSourcePending
        ? AudioProcessingState.loading
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
        updatePosition: streamSourcePending
            ? Duration.zero
            : Platform.isWindows
            ? _currentPosition
            : _player.position,
        bufferedPosition: streamSourcePending
            ? Duration.zero
            : Platform.isWindows
            ? _activePlaybackRange.relative(_windowsBufferedPosition, sourceDuration: _windowsDuration)
            : _player.bufferedPosition,
        speed: Platform.isWindows ? speedNotifier.value : _player.speed,
        queueIndex: Platform.isWindows ? 0 : _player.currentIndex,
      ),
    );
  }

  // ─── Saved state ──────────────────────────────────────────────────
  Future<void> reloadPortablePreferences() async {
    _playbackPreferenceStore = PlaybackPreferenceStore.load();
    playbackRangeRevision.value++;
    await _initSavedState(preload: false);
    final item = mediaItem.value;
    if (item != null && !item.id.startsWith('http') && _pendingRestoredTrack == null) {
      await _reloadActivePlaybackRange(item.id);
    }
  }

  Future<void> _initSavedState({bool preload = true}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (Platform.isWindows) {
        final savedOutput = prefs.getString('windows_output_device');
        if (savedOutput != null && savedOutput.isNotEmpty) {
          _savedWindowsOutputDeviceName = savedOutput;
          unawaited(setOutputDevice(savedOutput, persist: false));
        }
      }
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

      if (preload && trackPath != null && trackTitle != null && trackArtist != null) {
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
      trackVolumePercentNotifier.value = (await _playbackPreferenceStore).adjustmentsFor(filePath).volumePercent;
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

  Future<void> setTrackVolumePercent(double percent) async {
    final source = mediaItem.value?.id;
    if (source == null || !percent.isFinite) return;
    final value = percent.clamp(-100.0, 100.0);
    trackVolumePercentNotifier.value = value;
    await (await _playbackPreferenceStore).saveTrackVolume(source, value);
    await _applyOutputVolume();
  }

  Future<void> setPlaybackSettingsScope(PlaybackSettingsScope scope) async {
    if (playbackSettingsScopeNotifier.value == scope) return;
    playbackSettingsScopeNotifier.value = scope;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('playback_settings_scope', scope.name);
    final current = mediaItem.value;
    final adjustments = scope == PlaybackSettingsScope.global
        ? _globalPlaybackAdjustments.copyWith(volumePercent: trackVolumePercentNotifier.value)
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
    final saved = (await _playbackPreferenceStore).adjustmentsFor(filePath);
    return playbackSettingsScopeNotifier.value == PlaybackSettingsScope.global
        ? _globalPlaybackAdjustments.copyWith(volumePercent: saved.volumePercent)
        : saved;
  }

  Future<void> _persistPlaybackAdjustments(
    PlaybackAdjustments adjustments, {
    required PlaybackSettingsScope scope,
    required String? trackId,
  }) async {
    if (scope == PlaybackSettingsScope.global) {
      _globalPlaybackAdjustments = adjustments.copyWith(volumePercent: 0);
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
      await (await _playbackPreferenceStore).saveAdjustments(trackId, adjustments, preserveVolume: true);
    }
  }

  PlaybackAdjustments get _currentAdjustments => PlaybackAdjustments(
    speed: speedNotifier.value,
    pitch: pitchNotifier.value,
    equalizer: equalizerNotifier.value,
    volumePercent: trackVolumePercentNotifier.value,
  );

  Future<void> _applyPlaybackAdjustments(PlaybackAdjustments adjustments, {required bool persist}) {
    final normalized = PlaybackAdjustments(
      speed: adjustments.speed.clamp(0.5, 2.0),
      pitch: adjustments.pitch.clamp(0.5, 2.0),
      equalizer: adjustments.equalizer,
      volumePercent: adjustments.volumePercent,
    );
    _requestedPlaybackAdjustments = normalized;
    final persistenceScope = playbackSettingsScopeNotifier.value;
    final persistenceTrackId = mediaItem.value?.id;
    if (persist && persistenceScope == PlaybackSettingsScope.global) {
      // Keep subsequent track loads on the latest requested global values even
      // while the platform calls are waiting their turn in the queue.
      _globalPlaybackAdjustments = normalized.copyWith(volumePercent: 0);
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
    if (persist) {
      normalized = normalized.copyWith(volumePercent: trackVolumePercentNotifier.value);
    }
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
    double trackVolumePercent,
  ) async {
    final raw =
        volumeNotifier.value *
        multiplier *
        normalizationMultiplier *
        trackVolumeMultiplier(trackVolumePercent, volumeNotifier.value);
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
    double trackVolumePercent,
  ) => player.setVolume(
    volumeNotifier.value *
        multiplier *
        normalizationMultiplier *
        trackVolumeMultiplier(trackVolumePercent, volumeNotifier.value) *
        equalizerOutputHeadroomMultiplier(equalizer, effectApplied: equalizerApplied) *
        100.0,
  );

  Future<void> _applyOutputVolume() {
    _volumeApplyPending = true;
    return _volumeApplyTask ??= _drainOutputVolume();
  }

  Future<void> _drainOutputVolume() async {
    try {
      do {
        _volumeApplyPending = false;
        try {
          await _writeOutputVolume().timeout(const Duration(seconds: 2));
        } on TimeoutException {
          debugPrint('[PlayerHandler] Output volume write timed out');
        }
      } while (_volumeApplyPending);
    } finally {
      _volumeApplyTask = null;
    }
  }

  Future<void> _writeOutputVolume() async {
    try {
      if (Platform.isWindows) {
        await _setWindowsOutputVolume(
          _windowsPlayer!,
          _transitionVolumeMultiplier,
          equalizerNotifier.value,
          _equalizerEffectApplied,
          _normalizationMultiplier,
          trackVolumePercentNotifier.value,
        );
      } else {
        await _setJustAudioOutputVolume(
          _player,
          _loudnessEnhancer,
          _transitionVolumeMultiplier,
          equalizerNotifier.value,
          _equalizerEffectApplied,
          _normalizationMultiplier,
          trackVolumePercentNotifier.value,
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
        !_playbackRequested ||
        _syncSessionActive ||
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
    final playlist = await _effectivePlaybackOrder(playlistNumber: playlistNumber);
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
      if (generation != _crossfadeGeneration || !crossfadeEnabledNotifier.value || !_playbackRequested) return false;
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
          await _queueNavigation(_advanceAfterCompletion);
        }
      }
    }
  }

  Duration _incomingCrossfadeDuration(Duration fade, Duration? length, Duration position) {
    if (length == null || length <= position) return fade;
    final maximum = Duration(microseconds: (length - position).inMicroseconds ~/ 2);
    return fade < maximum ? fade : maximum;
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
      final range = await playbackRangeFor(target.path);
      Duration? originalDuration;
      if (!range.isFull) {
        try {
          originalDuration = await originalDurationFor(target.path);
        } catch (_) {}
      }
      final media = await _buildMediaKitMedia(target.path, range: range);
      if (generation != _crossfadeGeneration) return;
      await _configureWindowsRange(incoming, range);
      await incoming.open(media, play: false);
      final incomingEqualizerApplied = await _applyWindowsPlaybackAdjustments(
        incoming,
        incomingAdjustments,
        updateSupport: false,
      );
      final resume = await _incomingResumePosition(target.path, range.durationOf(incoming.state.duration));
      if (resume != null) await incoming.seek(range.source(resume));
      await _setWindowsOutputVolume(
        incoming,
        0,
        incomingAdjustments.equalizer,
        incomingEqualizerApplied,
        incomingNormalization,
        incomingAdjustments.volumePercent,
      );
      if (generation != _crossfadeGeneration || !identical(outgoing, _windowsPlayer)) return;
      await incoming.play();
      final completed = await _runEqualPowerFade(
        generation,
        _incomingCrossfadeDuration(
          _availableCrossfadeDuration(fade),
          range.durationOf(incoming.state.duration),
          resume ?? Duration.zero,
        ),
        (outgoingVolume, incomingVolume) async {
          await Future.wait([
            _setWindowsOutputVolume(
              outgoing,
              outgoingVolume,
              outgoingAdjustments.equalizer,
              outgoingEqualizerApplied,
              outgoingNormalization,
              outgoingAdjustments.volumePercent,
            ),
            _setWindowsOutputVolume(
              incoming,
              incomingVolume,
              incomingAdjustments.equalizer,
              incomingEqualizerApplied,
              incomingNormalization,
              incomingAdjustments.volumePercent,
            ),
          ]);
        },
      );
      if (!completed || !identical(outgoing, _windowsPlayer)) return;

      _setActivePlaybackRange(range);
      _originalTrackDuration = originalDuration;
      _windowsPlayer = incoming;
      adopted = true;
      _windowsPosition = incoming.state.position;
      _windowsDuration = incoming.state.duration;
      _windowsBufferedPosition = incoming.state.buffer;
      _windowsIsBuffering = incoming.state.buffering;
      _windowsIsCompleted = incoming.state.completed;
      _equalizerEffectApplied = incomingEqualizerApplied;
      _normalizationMultiplier = incomingNormalization;
      await _finishAutomaticCrossfade(generation, outgoingItem, target, incomingAdjustments);
      unawaited(outgoing.stop().catchError((_) {}));
      unawaited(outgoing.dispose().catchError((_) {}));
    } finally {
      if (!adopted) {
        await incoming.stop().catchError((_) {});
        await incoming.dispose().catchError((_) {});
        if (generation == _crossfadeGeneration && identical(outgoing, _windowsPlayer)) {
          _crossfadeInProgress = false;
          await _setWindowsOutputVolume(
            outgoing,
            1.0,
            outgoingAdjustments.equalizer,
            outgoingEqualizerApplied,
            outgoingNormalization,
            outgoingAdjustments.volumePercent,
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
    _androidCrossfadePlayer = incoming;
    _attachJustAudioPlayer(incoming);
    var adopted = false;
    try {
      final range = await playbackRangeFor(target.path);
      Duration? originalDuration;
      if (!range.isFull) {
        try {
          originalDuration = await originalDurationFor(target.path);
        } catch (_) {}
      }
      final source = await _buildAudioSource(target.path, range: range);
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
        incomingAdjustments.volumePercent,
      );
      if (generation != _crossfadeGeneration || !identical(outgoing, _player)) return;
      // just_audio's play Future remains pending until playback is paused,
      // stopped, or completes. Awaiting it would leave the incoming player at
      // zero volume and prevent adoption until the entire next track ended.
      await _startJustAudioPlayer(incoming, _loadGeneration);
      if (generation != _crossfadeGeneration || !_playbackRequested) return;
      final completed = await _runEqualPowerFade(
        generation,
        _incomingCrossfadeDuration(_availableCrossfadeDuration(fade), incoming.duration, resume ?? Duration.zero),
        (outgoingVolume, incomingVolume) async {
          await Future.wait([
            _setJustAudioOutputVolume(
              outgoing,
              outgoingLoudnessEnhancer,
              outgoingVolume,
              outgoingAdjustments.equalizer,
              outgoingEqualizerApplied,
              outgoingNormalization,
              outgoingAdjustments.volumePercent,
            ),
            _setJustAudioOutputVolume(
              incoming,
              backend.loudnessEnhancer,
              incomingVolume,
              incomingAdjustments.equalizer,
              incomingEqualizerApplied,
              incomingNormalization,
              incomingAdjustments.volumePercent,
            ),
          ]);
        },
      );
      if (!completed || !identical(outgoing, _player)) return;

      _setActivePlaybackRange(range);
      _originalTrackDuration = originalDuration;
      _player = incoming;
      _loudnessEnhancer = backend.loudnessEnhancer;
      _androidEqualizer = backend.equalizer;
      _equalizerEffectApplied = incomingEqualizerApplied;
      _normalizationMultiplier = incomingNormalization;
      adopted = true;
      await _finishAutomaticCrossfade(generation, outgoingItem, target, incomingAdjustments);
      unawaited(outgoing.stop().catchError((_) {}));
      unawaited(outgoing.dispose().catchError((_) {}));
    } finally {
      if (identical(_androidCrossfadePlayer, incoming)) _androidCrossfadePlayer = null;
      if (!adopted) {
        await incoming.stop().catchError((_) {});
        await incoming.dispose().catchError((_) {});
        if (_interruptions.blocked && identical(outgoing, _player)) await _applyOutputVolume();
        if (generation == _crossfadeGeneration && identical(outgoing, _player)) {
          _crossfadeInProgress = false;
          await _setJustAudioOutputVolume(
            outgoing,
            outgoingLoudnessEnhancer,
            1.0,
            outgoingAdjustments.equalizer,
            outgoingEqualizerApplied,
            outgoingNormalization,
            outgoingAdjustments.volumePercent,
          );
        }
      }
    }
  }

  Future<void> _finishAutomaticCrossfade(
    int crossfadeGeneration,
    MediaItem outgoingItem,
    _AutomaticTrackTarget target,
    PlaybackAdjustments adjustments,
  ) async {
    if (crossfadeGeneration != _crossfadeGeneration) return;
    // Commit synchronously; awaiting disk persistence here let an already
    // adopted crossfade overwrite a subsequent user selection.
    unawaited(_clearCrossfadedPosition(outgoingItem.id));
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
    trackVolumePercentNotifier.value = adjustments.volumePercent;
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
    if (_loadGeneration != generation) return;
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
  Future<void> _clearCrossfadedPosition(String trackId) async {
    try {
      await (await _playbackPreferenceStore).clearPosition(trackId);
    } catch (error) {
      debugPrint('[PlayerHandler] Could not clear completed track position: $error');
    }
  }

  @override
  Future<void> play() async {
    await stopPlaybackRangePreview(resume: false);
    if (_syncControlLocked) return;
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
    await _playCurrentBackend();
  }

  Future<void> _playCurrentBackend() async {
    if (!_playbackRequested || _playbackUnavailable) return;
    if (_pendingStreamSourceGeneration == _loadGeneration) return;
    if (Platform.isWindows) {
      try {
        if (!_isWindowsPlaying) await _windowsPlayer!.play();
      } catch (error) {
        await _handlePlaybackFailure(_loadGeneration, error, allowStreamRecovery: _currentTrackIsStream);
        return;
      }
      _updatePlaybackState();
      _armPlaybackHealthCheck(
        _loadGeneration,
        grace: _currentTrackIsStream ? _streamStartupGrace : const Duration(seconds: 5),
      );
      return;
    }
    if (!_player.playing) {
      await _startJustAudioPlayer(_player, _loadGeneration);
    }
    _updatePlaybackState();
    _armPlaybackHealthCheck(
      _loadGeneration,
      grace: _currentTrackIsStream ? _streamStartupGrace : const Duration(seconds: 5),
    );
  }

  @override
  Future<void> pause() async {
    await stopPlaybackRangePreview(resume: false);
    if (_syncControlLocked) return;
    _playbackRequested = false;
    _playbackHealthWatchdog.cancel();
    if (Platform.isAndroid && _crossfadeInProgress) await _pauseForAudioInterruption();
    if (_pendingStreamSourceGeneration == _loadGeneration) {
      await _queueBackendLoad(() async {
        if (_playbackRequested) return;
        if (Platform.isWindows) {
          if (_isWindowsPlaying) await _windowsPlayer!.pause();
        } else if (_player.playing) {
          await _player.pause();
        }
      });
      return;
    }
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
    await stopPlaybackRangePreview(resume: false);
    if (_syncControlLocked || _playbackUnavailable || _pendingStreamSourceGeneration == _loadGeneration) return;
    final generation = ++_seekGeneration;
    final sourceGeneration = _loadGeneration;
    final duration = _currentDuration;
    final target = position < Duration.zero
        ? Duration.zero
        : duration != null && duration > Duration.zero && position > duration
        ? duration
        : position;
    _activeSeekGeneration = generation;
    _playbackHealthWatchdog.cancel();
    final operation = _seekOperations.run(
      () => _seekBackend(target, sourceGeneration),
      isSourceCurrent: () => _loadGeneration == sourceGeneration,
    );
    var applied = false;
    try {
      await operation;
      applied = true;
    } finally {
      if (_activeSeekGeneration == generation) {
        _activeSeekGeneration = null;
        if (_loadGeneration == sourceGeneration) {
          // Start from the new position, never from the pre-seek timestamp.
          _armPlaybackHealthCheck(
            sourceGeneration,
            grace: _currentTrackIsStream ? _streamStartupGrace : const Duration(seconds: 5),
            // Native position events can lag behind the seek command.
            initialPosition: applied ? target : null,
          );
        }
        // Position events are ignored while the backend seek is unresolved.
        // Re-evaluate immediately afterward so seeking near the end can still
        // begin the configured automatic crossfade.
        _maybeStartAutomaticCrossfade();
      }
    }
  }

  void _cancelPendingSeeks() {
    _seekGeneration++;
    _activeSeekGeneration = null;
    _seekOperations.cancelPending();
  }

  Future<void> _seekBackend(Duration position, int sourceGeneration) async {
    if (_crossfadeInProgress) {
      _crossfadeGeneration++;
      _crossfadeInProgress = false;
      _transitionVolumeMultiplier = 1.0;
      await _applyOutputVolume();
    }
    if (_loadGeneration != sourceGeneration) return;
    if (Platform.isWindows) {
      // Both backends preserve play/pause during seek. Use native buffering
      // state; a synthetic true value can stick when no false event follows.
      final player = _windowsPlayer!;
      final sourcePosition = _activePlaybackRange.source(position);
      _windowsPosition = sourcePosition;
      _updatePlaybackState();
      await player.seek(sourcePosition);
      if (_loadGeneration != sourceGeneration || !identical(player, _windowsPlayer)) return;
      _windowsIsBuffering = player.state.buffering;
      _windowsIsCompleted = player.state.completed;
      _updatePlaybackState();
      return;
    }

    final player = _player;
    await player.seek(position);
    if (_loadGeneration != sourceGeneration || !identical(player, _player)) return;
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
    await stopPlaybackRangePreview(resume: false);
    _playbackRequested = false;
    _playbackHealthWatchdog.cancel();
    _cancelPendingSeeks();
    await _seekOperations.idle;
    await saveCurrentPlaybackPosition();
    _pendingRestoredTrack = null;
    _playbackUnavailable = false;
    _failedTrackIds.clear();
    _retryLoadGeneration = null;
    _handledFailureGeneration = null;
    _loadGeneration++;
    _cancelSupersededAndroidStreams(null);
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
    _standaloneStreamQueue = const [];
    _standaloneStreamQueueIndex = null;
    trackTransitionNotifier.value = TrackTransitionState(revision: trackTransitionNotifier.value.revision + 1);

    try {
      await _backendSourceOperations.idle;
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
    _youtubeHistoryCoordinator?.onSessionEnded();
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
    if (_syncControlLocked) return;
    await _applyPlaybackAdjustments(
      _requestedPlaybackAdjustments.copyWith(speed: speed.clamp(0.5, 2.0)),
      persist: true,
    );
  }

  Future<void> setPitch(double pitch) async {
    if (_syncControlLocked) return;
    await _applyPlaybackAdjustments(
      _requestedPlaybackAdjustments.copyWith(pitch: pitch.clamp(0.5, 2.0)),
      persist: true,
    );
  }

  Future<void> setEqualizer(EqualizerSettings settings) async {
    if (_syncControlLocked) return;
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
    bool playWhenReady = true,
    bool preservePosition = true,
  }) async {
    if (_syncControlLocked) return;
    final stopPreview = stopPlaybackRangePreview(resume: false);
    final interruptSource =
        // Each explicit track load begins a new listening session.
        _activeTrackLoadGeneration != null ||
        _currentTrackIsStream ||
        filePath.startsWith('http://') ||
        filePath.startsWith('https://');
    final outgoingPositionSave = preservePosition ? saveCurrentPlaybackPosition() : Future<void>.value();
    ListeningStatistics.instance.onSessionEnded();
    final generation = ++_loadGeneration;
    _cancelPendingSeeks();
    // Invalidate transitions before the first await: a newer selection owns
    // both the audio source and its presentation immediately.
    _crossfadeGeneration++;
    _crossfadeInProgress = false;
    _pendingStreamSourceGeneration = generation;
    _cancelSupersededAndroidStreams(filePath);
    _playbackRequested = playWhenReady;
    _playbackUnavailable = false;
    _playbackHealthWatchdog.cancel();
    _handledFailureGeneration = null;
    if (!preserveFailureHistory) {
      _failedTrackIds.clear();
      _retryLoadGeneration = null;
    }
    _activeTrackLoadGeneration = generation;
    _lastTrackLoadFailure = null;
    try {
      await stopPreview;
      if (_loadGeneration != generation) return;
      if (Platform.isAndroid && interruptSource) {
        // Stop interrupts obsolete preparation and discards its buffered audio.
        try {
          await _player.stop();
        } catch (_) {}
        if (_loadGeneration != generation) return;
      }
      if (Platform.isWindows && interruptSource) {
        await _queueBackendLoad(() async {
          if (_loadGeneration != generation) return;
          try {
            await _windowsPlayer!.stop();
          } catch (error) {
            // Opening the replacement can recover a failed old source.
            debugPrint('[PlayerHandler] Could not discard previous source: $error');
          }
        });
      }
      await outgoingPositionSave;
      if (_loadGeneration != generation) return;
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
        restorePosition: preservePosition,
      );
    } finally {
      if (_activeTrackLoadGeneration == generation) {
        _activeTrackLoadGeneration = null;
      }
    }
  }

  Object? _lastTrackLoadFailure;

  Future<void> _queueBackendLoad(Future<void> Function() operation) {
    return _backendSourceOperations.run(operation);
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
    required bool restorePosition,
  }) async {
    final myGen = generation;
    await _seekOperations.idle;
    if (_loadGeneration != myGen) return;
    _crossfadeGeneration++;
    _crossfadeInProgress = false;
    _transitionVolumeMultiplier = 1.0;
    await _applyOutputVolume();
    if (_loadGeneration != myGen) return;
    _pendingRestoredTrack = null;
    _audioEnvelope = null;
    _audioEnvelopeTrackId = null;
    standaloneModeNotifier.value = standalone;
    _standalonePlaylistNumber = standalone ? standalonePlaylistNumber : null;
    _standalonePlaylistIndex = standalonePlaylistIndex;
    if (!standalone || standalonePlaylistNumber != null) {
      _standaloneStreamQueue = const [];
      _standaloneStreamQueueIndex = null;
    }
    trackTransitionNotifier.value = TrackTransitionState(
      revision: trackTransitionNotifier.value.revision + 1,
      direction: transitionDirection,
    );
    await _playbackAdjustmentQueue;
    if (_loadGeneration != myGen) return;
    final isStream = filePath.startsWith('http://') || filePath.startsWith('https://');
    final adjustments = await _adjustmentsForTrack(filePath);
    final range = await playbackRangeFor(filePath);
    Duration? originalDuration;
    if (!range.isFull) {
      try {
        originalDuration = await originalDurationFor(filePath);
      } catch (_) {}
    }
    if (_loadGeneration != myGen) return;
    _setActivePlaybackRange(range);
    _originalTrackDuration = originalDuration;

    _currentTrackIsStream = isStream;
    _pendingStreamSourceGeneration = myGen;
    if (isStream) {
      _windowsPosition = Duration.zero;
      _windowsDuration = Duration.zero;
      _windowsBufferedPosition = Duration.zero;
      _positionController.add(Duration.zero);
      _durationController.add(Duration.zero);
    }
    _normalizationMultiplier = _normalizationMultiplierFor(filePath);
    trackVolumePercentNotifier.value = adjustments.volumePercent;

    // Optimistic UI update
    // A deliberate reload of the same local path is a new listening session.
    _localHistoryCoordinator?.onSessionEnded();
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
    try {
      if (_loadGeneration != myGen) return;

      if (Platform.isWindows) {
        mk.Media media;
        try {
          media = await _buildMediaKitMedia(filePath, range: range);
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
        await _queueBackendLoad(() async {
          if (_loadGeneration != myGen) return;
          await _ensureWindowsAudioOutput(player);
          if (_loadGeneration != myGen) return;
          // Keep source replacement and playback start in one media_kit
          // command. A stale open may finish after a newer selection; pause
          // it here, then let the queued replacement open the selected song.
          await _configureWindowsRange(player, range);
          if (_loadGeneration != myGen) return;
          await player.open(media, play: _playbackRequested);
          if (_loadGeneration != myGen || !_playbackRequested) await player.pause();
          if (_loadGeneration == myGen) {
            _windowsDuration = player.state.duration;
            _windowsPosition = player.state.position;
          }
        });
      } else {
        AudioSource source;
        try {
          source = await _buildAudioSource(filePath, range: range);
        } catch (e) {
          if (_loadGeneration != myGen) return;
          debugPrint('[PlayerHandler] Failed to build audio source for "$filePath": $e');
          rethrow;
        }

        if (_loadGeneration != myGen) return;
        // just_audio interrupts an older load when a newer source is set.
        // Queuing these calls made a fresh tap wait for the obsolete load.
        await _player.setAudioSource(source);
        if (_loadGeneration != myGen) return;
      }

      if (_loadGeneration != myGen) return;
      _pendingStreamSourceGeneration = null;
      _positionController.add(_currentPosition);
      _durationController.add(_currentDuration);
      await _applyPlaybackAdjustments(adjustments, persist: false);
      if (_loadGeneration != myGen) return;
      if (restorePosition) await _restorePlaybackPosition(filePath, myGen);
      if (_loadGeneration != myGen) return;
      if (!Platform.isWindows && _playbackRequested) {
        await _startJustAudioPlayer(_player, myGen);
      }
      if (_loadGeneration != myGen) return;
      _armPlaybackHealthCheck(myGen, grace: isStream ? _streamStartupGrace : const Duration(seconds: 5));

      // Do not stop the background visualizer decoder until the new source is
      // already ready (and Windows is already playing). Process cancellation
      // can briefly contend with the audio backend on both platforms.
      _envelopeAnalyzer.cancel();

      final dur = _currentDuration;
      final currentMetadata = mediaItem.value;
      final currentTitle = currentMetadata?.id == filePath ? currentMetadata!.title : title;
      final currentArtist = currentMetadata?.id == filePath ? currentMetadata!.artist ?? artist : artist;
      final currentArtwork = currentMetadata?.id == filePath ? currentMetadata!.artUri ?? artworkUri : artworkUri;
      mediaItem.add(
        MediaItem(
          id: filePath,
          title: currentTitle,
          artist: currentArtist,
          duration: dur,
          artUri: currentArtwork,
          // Presentation may have been dismissed while a slow stream was
          // resolving. Never restore the stale standalone flag captured when
          // this load began.
          extras: standalonePresentationExtras(standaloneModeNotifier.value),
        ),
      );
      if (isStream && (currentTitle == 'YouTube video' || currentArtist == 'Loading details…')) {
        final resolved = _streamUrlCache[filePath]?.stream;
        final resolvedTitle = resolved?.title?.trim() ?? '';
        final resolvedArtist = resolved?.artist?.trim() ?? '';
        if (resolvedTitle.isNotEmpty && resolvedArtist.isNotEmpty) {
          unawaited(
            updateStandaloneStreamMetadata(
              YoutubeTrack(
                title: resolvedTitle,
                artist: resolvedArtist,
                url: filePath,
                thumbnailUrl: resolved?.thumbnailUrl?.isNotEmpty == true
                    ? resolved!.thumbnailUrl
                    : currentArtwork?.toString(),
              ),
            ),
          );
        }
      }

      _updatePlaybackState();
      if (isStream && _standaloneStreamQueue.isNotEmpty) {
        unawaited(_prefetchAdjacentStreams(myGen));
      } else {
        unawaited(
          _prefetchPlaylistNeighborStreams(myGen).catchError((Object error) {
            if (!_interruptions.disposed) debugPrint('[PlayerHandler] Optional neighbor prefetch failed: $error');
          }),
        );
      }
      final loadedFromOutsidePlaylist = standaloneModeNotifier.value && _standalonePlaylistNumber == null;
      unawaited(
        _finishTrackLoad(
          generation: myGen,
          filePath: filePath,
          title: mediaItem.value?.title ?? title,
          artist: mediaItem.value?.artist ?? artist,
          artworkUri: mediaItem.value?.artUri ?? artworkUri,
          externalSource: loadedFromOutsidePlaylist,
        ),
      );
      unawaited(_prepareAudioEnvelope(generation: myGen, filePath: filePath));
      unawaited(_prepareLoudnessAnalysis(generation: myGen, filePath: filePath));
    } catch (e, st) {
      if (_loadGeneration == myGen) {
        _pendingStreamSourceGeneration = null;
        _lastTrackLoadFailure = e;
        if (!standalone && e is YoutubeFailure) {
          youtubeFailureNotifier.value = e;
        }
        debugPrint('[PlayerHandler] Error loading track "$filePath": $e\n$st');
        _streamUrlCache.remove(filePath);
        if (e is NoAudioOutputDeviceException) {
          // Do not retry/advance through the queue when the machine has no
          // endpoint at all. Waiting for the user to connect an output keeps
          // the queue intact and, importantly, avoids asking the native
          // backend to open audio with an invalid device.
          outputDeviceErrorNotifier.value = e.message;
          _playbackRequested = false;
          _playbackUnavailable = true;
          playbackState.add(playbackState.value.copyWith(processingState: AudioProcessingState.idle, playing: false));
          _updatePlaybackState(force: true);
          return;
        }
        // stop() can leave the outgoing source attached to the backend. A
        // failed replacement must stay unavailable so Play retries the selected
        // track rather than playing that old source under the new metadata.
        // Keep standalone presentation and its queue intact for retry/skip.
        _playbackUnavailable = true;
        playbackState.add(playbackState.value.copyWith(processingState: AudioProcessingState.idle, playing: false));
        _updatePlaybackState();
        await _handlePlaybackFailure(myGen, e, allowStreamRecovery: isStream && e is! YoutubeFailure);
        if (_loadGeneration == myGen) await _markPlaybackUnavailable(myGen);
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
    List<StandaloneStreamQueueItem>? queueItems,
    int? queueIndex,
    bool relatedQueue = true,
  }) async {
    _standaloneRelatedGeneration++;
    _standaloneRelatedEnabled = relatedQueue;
    final requestedQueue = queueItems ?? const <StandaloneStreamQueueItem>[];
    final resolvedIndex = queueIndex != null && queueIndex >= 0 && queueIndex < requestedQueue.length
        ? queueIndex
        : requestedQueue.indexWhere((item) => item.url == url);
    _standaloneStreamQueue = requestedQueue.isEmpty ? const [] : List.unmodifiable(requestedQueue);
    _standaloneStreamQueueIndex = resolvedIndex >= 0 ? resolvedIndex : null;
    final artworkUri = thumbnailUrl == null || thumbnailUrl.isEmpty ? null : Uri.tryParse(thumbnailUrl);
    unawaited(MetadataCacheService.set(url, title, artist, artworkUrl: thumbnailUrl));
    final playback = loadTrack(url, title, artist, standalone: true, artworkUri: artworkUri);
    if (relatedQueue) unawaited(_refreshStandaloneRelatedQueue(url, playback));
    await playback;
    if (!isStandaloneMode ||
        mediaItem.value?.id != url ||
        playbackState.value.processingState == AudioProcessingState.idle) {
      final failure = _lastTrackLoadFailure;
      if (failure != null) throw failure;
      throw StateError('The YouTube stream could not be loaded.');
    }
  }

  Future<void> updateStandaloneStreamMetadata(YoutubeTrack track) async {
    final current = mediaItem.value;
    if (current == null ||
        !isStandaloneStreamSession ||
        YoutubeTrack(title: '', artist: '', url: current.id).videoId != track.videoId) {
      return;
    }
    final artwork = track.thumbnailUrl == null ? current.artUri : Uri.tryParse(track.thumbnailUrl!);
    await MetadataCacheService.set(current.id, track.title, track.artist, artworkUrl: track.thumbnailUrl);
    if (mediaItem.value?.id != current.id) return;
    mediaItem.add(current.copyWith(title: track.title, artist: track.artist, artUri: artwork));
    _standaloneStreamQueue = [
      for (final item in _standaloneStreamQueue)
        if (item.url == current.id)
          StandaloneStreamQueueItem(
            url: item.url,
            title: track.title,
            artist: track.artist,
            thumbnailUrl: track.thumbnailUrl,
          )
        else
          item,
    ];
  }

  Future<void> _refreshStandaloneRelatedQueue(String seedUrl, Future<void> playback) async {
    final seedId = YoutubeTrack(title: '', artist: '', url: seedUrl).videoId;
    if (seedId == null) return;
    final generation = ++_standaloneRelatedGeneration;
    try {
      await playback;
      if (generation != _standaloneRelatedGeneration || !_standaloneRelatedEnabled) return;
      final related = await const YoutubeMusicRelatedService().fetch(seedId);
      if (generation != _standaloneRelatedGeneration ||
          !_standaloneRelatedEnabled ||
          !isStandaloneStreamSession ||
          mediaItem.value?.id != seedUrl ||
          related.isEmpty) {
        return;
      }
      final currentIndex = _standaloneStreamQueueIndex ?? 0;
      final history = currentIndex >= 0 && currentIndex < _standaloneStreamQueue.length
          ? _standaloneStreamQueue.take(currentIndex + 1).toList()
          : <StandaloneStreamQueueItem>[
              StandaloneStreamQueueItem(
                url: seedUrl,
                title: mediaItem.value?.title ?? 'YouTube video',
                artist: mediaItem.value?.artist ?? 'YouTube',
                thumbnailUrl: mediaItem.value?.artUri?.toString(),
              ),
            ];
      final seen = history.map((item) => YoutubeTrack(title: '', artist: '', url: item.url).videoId).toSet();
      final upcoming = [
        for (final track in related)
          if (seen.add(track.videoId))
            StandaloneStreamQueueItem(
              url: track.url,
              title: track.title,
              artist: track.artist,
              thumbnailUrl: track.thumbnailUrl,
            ),
      ];
      if (upcoming.isEmpty) return;
      _standaloneStreamQueue = List.unmodifiable([...history, ...upcoming]);
      _standaloneStreamQueueIndex = history.length - 1;
      mediaItem.add(mediaItem.value);
      unawaited(warmStreamCandidates(upcoming.take(2).map((item) => item.url)));
    } catch (error) {
      debugPrint('[PlayerHandler] YouTube Music related queue unavailable: $error');
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
    _volumeSaveTimer?.cancel();
    _volumeSaveTimer = Timer(const Duration(milliseconds: 300), () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setDouble('last_volume', volumeNotifier.value);
      } catch (_) {}
    });
    await _applyOutputVolume();
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
    if (!_playbackRequested) return;
    final generation = _loadGeneration;
    if (isStandaloneMode && _standalonePlaylistNumber == null && _standaloneStreamQueue.isNotEmpty) {
      await _moveStandaloneStreamQueue(1, TrackTransitionDirection.next);
      return;
    }
    final target = await _automaticNextTarget();
    if (_loadGeneration != generation || !_playbackRequested) return;
    if (target == null) {
      if (currentLoopMode == LoopMode.all) await _nextInternal();
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

  Future<void> next() => _queueNavigation(_nextInternal);

  Future<void> _nextInternal() async {
    if (_syncControlLocked) return;
    final generation = _loadGeneration;
    final currentItem = mediaItem.value;
    if (currentItem == null) return;
    final standalonePlaylistNumber = _standalonePlaylistNumber;
    if (isStandaloneMode && standalonePlaylistNumber == null) {
      await _moveStandaloneStreamQueue(1, TrackTransitionDirection.next);
      return;
    }
    final playlist = await _effectivePlaybackOrder(playlistNumber: standalonePlaylistNumber);
    if (_loadGeneration != generation || playlist.isEmpty) return;
    final index = _currentPlaylistIndex(playlist, currentItem.id);
    if (index == -1) return;
    final nextIndex = (index + 1) % playlist.length;
    final nextPath = playlist[nextIndex];
    final meta = await _getTrackMetadata(nextPath);
    if (_loadGeneration != generation) return;
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
  Future<void> previous({bool restartCurrent = true}) =>
      _queueNavigation(() => _previousInternal(restartCurrent: restartCurrent));

  Future<void> _previousInternal({bool restartCurrent = true}) async {
    if (_syncControlLocked) return;
    final generation = _loadGeneration;
    final currentItem = mediaItem.value;
    if (currentItem == null) return;
    final standalonePlaylistNumber = _standalonePlaylistNumber;
    if (isStandaloneMode && standalonePlaylistNumber == null) {
      if (restartCurrent && _currentPosition > const Duration(seconds: 3)) {
        await seek(Duration.zero);
        return;
      }
      await _moveStandaloneStreamQueue(-1, TrackTransitionDirection.previous);
      return;
    }
    final playlist = await _effectivePlaybackOrder(playlistNumber: standalonePlaylistNumber);
    if (_loadGeneration != generation || playlist.isEmpty) return;
    final index = _currentPlaylistIndex(playlist, currentItem.id);
    if (index == -1) return;
    if (restartCurrent && _currentPosition > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }
    final prevIndex = (index - 1 + playlist.length) % playlist.length;
    final meta = await _getTrackMetadata(playlist[prevIndex]);
    if (_loadGeneration != generation) return;
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

  Future<void> _queueNavigation(Future<void> Function() operation) {
    final run = _navigationTail.then<void>((_) async {
      try {
        await operation();
      } catch (error, stackTrace) {
        // Navigation is initiated by UI callbacks, media keys, and backend
        // listeners. A metadata/file error must not become an uncaught async
        // exception (or prevent the next queued navigation from running).
        debugPrint('[PlayerHandler] Track navigation failed: $error\n$stackTrace');
      }
    });
    _navigationTail = run.catchError((_) {});
    return run;
  }

  int _currentPlaylistIndex(List<String> playlist, String currentTrack) {
    final shuffle = _shuffleOrderForPaths[playlist];
    if (isShuffle && shuffle != null) {
      shuffle.select(
        currentTrack,
        preferredIndex: _shuffleSelectionGeneration == _loadGeneration ? null : _standalonePlaylistIndex,
        same: _sameTrackId,
      );
      _shuffleSelectionGeneration = _loadGeneration;
      return shuffle.index;
    }
    final rememberedIndex = _standalonePlaylistIndex;
    if (rememberedIndex != null &&
        rememberedIndex >= 0 &&
        rememberedIndex < playlist.length &&
        _sameTrackId(playlist[rememberedIndex], currentTrack)) {
      return rememberedIndex;
    }
    return playlist.indexWhere((path) => _sameTrackId(path, currentTrack));
  }

  Future<void> _moveStandaloneStreamQueue(int offset, TrackTransitionDirection direction) async {
    final items = _standaloneStreamQueue;
    if (items.isEmpty) return;
    var index = _standaloneStreamQueueIndex;
    if (index == null || index < 0 || index >= items.length) {
      index = items.indexWhere((item) => item.url == mediaItem.value?.id);
    }
    if (index < 0) return;
    final targetIndex = loopingStandaloneQueueIndex(currentIndex: index, offset: offset, length: items.length);
    await _loadStandaloneStreamQueueItem(targetIndex, direction);
  }

  Future<void> _loadStandaloneStreamQueueItem(int targetIndex, TrackTransitionDirection direction) async {
    final items = _standaloneStreamQueue;
    if (targetIndex < 0 || targetIndex >= items.length) return;
    final target = items[targetIndex];
    _standaloneStreamQueueIndex = targetIndex;
    final artworkUri = target.thumbnailUrl == null || target.thumbnailUrl!.isEmpty
        ? null
        : Uri.tryParse(target.thumbnailUrl!);
    unawaited(MetadataCacheService.set(target.url, target.title, target.artist, artworkUrl: target.thumbnailUrl));
    // Commit the selection now. Resolution of an uncached YouTube URL can
    // take seconds; later skips should supersede it instead of waiting for
    // that obsolete request to finish.
    final playback =
        loadTrack(
          target.url,
          target.title,
          target.artist,
          standalone: true,
          artworkUri: artworkUri,
          transitionDirection: direction,
        ).catchError((Object error, StackTrace stackTrace) {
          debugPrint('[PlayerHandler] Standalone stream load failed: $error\n$stackTrace');
        });
    unawaited(playback);
    if (_standaloneRelatedEnabled) unawaited(_refreshStandaloneRelatedQueue(target.url, playback));
  }

  Future<bool> isPlaying() async => Platform.isWindows ? _isWindowsPlaying : _player.playing;

  /// FIX: Use the correct player for the current platform.
  Future<void> playPause() async {
    if (_syncControlLocked) return;
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

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId, [Map<String, dynamic>? options]) =>
      _androidAutoCatalog.children(parentMediaId);

  @override
  Future<MediaItem?> getMediaItem(String mediaId) => _androidAutoCatalog.item(mediaId);

  @override
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) async {
    final location = await _androidAutoCatalog.resolve(mediaId);
    if (location == null) return;
    final item = await _androidAutoCatalog.track(mediaId);
    if (item == null) return;
    await loadTrack(
      location.path,
      item.title,
      item.artist ?? 'Unknown Artist',
      artworkUri: item.artUri,
      standalone: true,
      standalonePlaylistNumber: location.playlist,
      standalonePlaylistIndex: location.index,
    );
  }

  Future<void> toggleLoopMode() async {
    if (_syncControlLocked) return;
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
    if (_syncControlLocked) return;
    if (currentLoopMode == mode) return;
    currentLoopMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_loop_mode', currentLoopMode.name);
    playbackModeRevision.value++;
  }

  Future<void> toggleShuffle() async {
    if (_syncControlLocked) return;
    isShuffle = !isShuffle;
    if (isShuffle) await shuffleQueue(reset: true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('last_shuffle', isShuffle);
    playbackModeRevision.value++;
  }

  Future<void> setShuffleEnabled(bool enabled) async {
    if (_syncControlLocked) return;
    if (isShuffle == enabled) return;
    isShuffle = enabled;
    if (isShuffle) await shuffleQueue(reset: true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('last_shuffle', isShuffle);
    playbackModeRevision.value++;
  }

  Future<void> saveState() async {
    await ListeningStatistics.instance.flush();
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
        await (await _playbackPreferenceStore).saveAdjustments(current.id, _currentAdjustments, preserveVolume: true);
      }
      await _saveTrack(current.id, current.title, current.artist ?? 'Unknown Artist');
    }
  }

  Future<void> shuffleQueue({bool reset = false}) async {
    await _effectivePlaybackOrder(reset: reset);
  }

  Future<List<String>> _effectivePlaybackOrder({int? playlistNumber, bool reset = false}) async {
    var result = <String>[];
    await _playlistOrderOperations.run(() async {
      final number = playlistNumber ?? await FileService().getActivePlaylistNumber();
      final clean = await _getCleanPlaylist(playlistNumber: number);
      if (!isShuffle) {
        result = clean;
        return;
      }
      final existing = _shuffleOrders[number];
      final order = existing ?? PlaylistShuffleOrder();
      if (reset || existing == null) {
        order.reset(clean, current: mediaItem.value?.id, same: _sameTrackId);
        // The reset already selected the current occurrence at the front;
        // its old unshuffled index must not move that cursor again.
        _shuffleSelectionGeneration = _loadGeneration;
      } else {
        order.reconcile(clean, same: _sameTrackId);
      }
      _shuffleOrders[number] = order;
      result = order.paths;
      _shuffleOrderForPaths[result] = order;
    });
    return result;
  }

  /// FileService mutations are the authority for the order. Reconcile on the
  /// next read instead of deleting twice when a mutation already arrived.
  void removeTrackFromActivePlaybackOrder(String filePath, {bool allOccurrences = false}) {
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
    if (isStandaloneMode && playlistNumber == null && _standaloneStreamQueue.isNotEmpty) {
      var currentIndex = _standaloneStreamQueueIndex;
      if (currentIndex == null ||
          currentIndex < 0 ||
          currentIndex >= _standaloneStreamQueue.length ||
          _standaloneStreamQueue[currentIndex].url != current.id) {
        currentIndex = _standaloneStreamQueue.indexWhere((item) => item.url == current.id);
      }
      return standaloneStreamQueueSnapshot(
        items: _standaloneStreamQueue,
        currentIndex: currentIndex,
        // Search and Home session queues intentionally wrap regardless of the
        // persisted playlist repeat setting.
        loopBehavior: QueueLoopBehavior.all,
      );
    }
    final paths = isStandaloneMode && playlistNumber == null
        ? const <String>[]
        : await _effectivePlaybackOrder(playlistNumber: playlistNumber);
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

  /// Resolves queue artwork on demand. Queue surfaces call this only for rows
  /// Flutter actually builds, avoiding an expensive metadata scan of a long
  /// local playlist before the queue can open.
  Future<Uri?> queueArtworkUri(String trackId) => _albumArtUri(trackId);

  Future<void> playPlaybackQueueEntry(PlaybackQueueEntry entry) async {
    if (isStandaloneMode && _standalonePlaylistNumber == null && _standaloneStreamQueue.isNotEmpty) {
      final index = _standaloneStreamQueue.indexWhere((item) => item.url == entry.id);
      if (index >= 0) {
        await _loadStandaloneStreamQueueItem(index, TrackTransitionDirection.next);
        return;
      }
    }
    await loadTrack(entry.id, entry.title, entry.artist, transitionDirection: TrackTransitionDirection.next);
  }

  bool getShuffleMode() => isShuffle;
  LoopMode getLoopMode() => currentLoopMode;

  Future<void> dispose() async {
    await stopPlaybackRangePreview(resume: false);
    _playbackRequested = false;
    _interruptions.dispose();
    await _interruptionSubscription?.cancel();
    await _noisySubscription?.cancel();
    _cancelPendingSeeks();
    await _playlistMutationSubscription?.cancel();
    _youtubeAccessService?.removeListener(_handleYoutubeAccessChanged);
    WidgetsBinding.instance.removeObserver(this);
    _periodicPositionSaveTimer?.cancel();
    _playbackHealthWatchdog.cancel();
    _volumeSaveTimer?.cancel();
    await _seekOperations.idle;
    _loadGeneration++;
    _activeTrackLoadGeneration = null;
    await _backendSourceOperations.idle;
    _crossfadeGeneration++;
    _crossfadeInProgress = false;
    _envelopeAnalyzer.dispose();
    _loudnessAnalyzer.dispose();
    await saveState();
    if (Platform.isWindows) {
      await _windowsPlayer?.dispose();
    } else {
      await _player.dispose();
    }
    await DiscordPresenceService().clearPresence();
    await DiscordPresenceService().dispose();
    await _positionController.close();
    await _durationController.close();
    playbackRangeNotifier.dispose();
    playbackRangeRevision.dispose();
    playbackRangePreviewNotifier.dispose();
    volumeNotifier.dispose();
    trackVolumePercentNotifier.dispose();
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
    youtubeFailureNotifier.dispose();
    trackTransitionNotifier.dispose();
    uiVisibleNotifier.dispose();
    availableOutputDevicesNotifier.dispose();
    selectedOutputDeviceNotifier.dispose();
    outputDeviceErrorNotifier.dispose();
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

Map<String, dynamic>? _pickWindowsPlayableFormat(Map<String, dynamic> info) {
  final direct = info['url'] as String?;
  if (direct != null && direct.startsWith('http')) return info;

  final requestedDownloads = info['requested_downloads'];
  if (requestedDownloads is List && requestedDownloads.isNotEmpty) {
    final first = requestedDownloads.first;
    if (first is Map && first['url'] is String) return Map<String, dynamic>.from(first);
  }

  final requestedFormats = info['requested_formats'];
  if (requestedFormats is List && requestedFormats.isNotEmpty) {
    for (final format in requestedFormats.reversed) {
      if (format is Map && format['url'] is String) return Map<String, dynamic>.from(format);
    }
  }

  final formats = info['formats'];
  if (formats is List && formats.isNotEmpty) {
    for (final format in formats.reversed) {
      if (format is Map && format['url'] is String && (format['acodec'] as String?) != 'none') {
        return Map<String, dynamic>.from(format);
      }
    }
  }

  return null;
}

Map<String, String> _readWindowsStreamHeaders(Map<String, dynamic> selected, Map<String, dynamic> info) {
  final rawHeaders = selected['http_headers'] ?? info['http_headers'];
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
