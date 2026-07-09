// lib/core/audio/audio_service.dart

import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:audio_service/audio_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/services/discord_presence_service.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:audio_metadata_extractor/audio_metadata_extractor.dart';
import 'package:metadata_god/metadata_god.dart';

class PlayerHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final _loudnessEnhancer = AndroidLoudnessEnhancer();
  late final AudioPlayer _player = AudioPlayer(audioPipeline: AudioPipeline(androidAudioEffects: [_loudnessEnhancer]));
  late final mk.Player? _windowsPlayer = Platform.isWindows
      ? mk.Player(configuration: const mk.PlayerConfiguration(pitch: true))
      : null;

  double savedVolume = 1.0;

  final ValueNotifier<double> volumeNotifier = ValueNotifier<double>(1.0);
  final ValueNotifier<double> speedNotifier = ValueNotifier<double>(1.0);
  final ValueNotifier<double> pitchNotifier = ValueNotifier<double>(1.0);
  final ValueNotifier<int> seekStepNotifier = ValueNotifier<int>(5);
  LoopMode currentLoopMode = LoopMode.all;
  bool isShuffle = false;
  List<String> shuffledList = [];
  final ValueNotifier<int> playbackModeRevision = ValueNotifier<int>(0);
  MediaItem? _pendingRestoredTrack;
  final Map<String, Uri?> _artUriCache = {};

  int _loadGeneration = 0;

  // Tracks whether the current track is a stream (URL), for seek behaviour.
  bool _currentTrackIsStream = false;

  // Session-scoped cache: YouTube URL → resolved CDN/HLS URL.
  final Map<String, String> _streamUrlCache = {};
  final _windowsStreamProxy = _WindowsStreamProxy();
  bool _windowsIsBuffering = false;
  bool _windowsIsCompleted = false;
  Duration _windowsPosition = Duration.zero;
  Duration _windowsDuration = Duration.zero;
  Duration _windowsBufferedPosition = Duration.zero;

  PlayerHandler() {
    if (Platform.isWindows) {
      final player = _windowsPlayer!;
      player.stream.playing.listen((_) => _updatePlaybackState());
      player.stream.position.listen((position) {
        _windowsPosition = position;
        _updatePlaybackState();
      });
      player.stream.duration.listen((duration) {
        _windowsDuration = duration;
        final currentItem = mediaItem.value;
        if (currentItem != null && duration > Duration.zero) {
          mediaItem.add(currentItem.copyWith(duration: duration));
        }
        _updatePlaybackState();
      });
      player.stream.buffer.listen((position) {
        _windowsBufferedPosition = position;
        _updatePlaybackState();
      });
      player.stream.buffering.listen((isBuffering) {
        _windowsIsBuffering = isBuffering;
        _updatePlaybackState();
      });
      player.stream.completed.listen((completed) async {
        if (!completed) return;
        _windowsIsCompleted = completed;
        _updatePlaybackState();
        final genAtCompletion = _loadGeneration;
        if (currentLoopMode == LoopMode.one) {
          await player.seek(Duration.zero);
          await player.play();
        } else if (currentLoopMode == LoopMode.all && _loadGeneration == genAtCompletion) {
          await next();
        }
      });
      player.stream.rate.listen((s) => speedNotifier.value = s);
      player.stream.pitch.listen((p) => pitchNotifier.value = p);
    } else {
      _player.playbackEventStream.listen((_) => _updatePlaybackState());
      _player.speedStream.listen((s) => speedNotifier.value = s);
      _player.playingStream.listen((_) => _updatePlaybackState());

      _player.durationStream.listen((duration) {
        final currentItem = mediaItem.value;
        if (currentItem != null && duration != null) {
          mediaItem.add(currentItem.copyWith(duration: duration));
        }
        _updatePlaybackState();
      });

      _player.positionStream.listen((_) => _updatePlaybackState());

      _player.processingStateStream.listen((state) async {
        _updatePlaybackState();
        if (state == ProcessingState.completed) {
          final genAtCompletion = _loadGeneration;
          if (currentLoopMode == LoopMode.one) {
            await _player.seek(Duration.zero);
            await _player.play();
          } else if (currentLoopMode == LoopMode.all) {
            if (_loadGeneration == genAtCompletion) {
              await next();
            }
          }
        }
      });
    }

    _playingStream.listen((isPlaying) async {
      if (isPlaying) {
        final current = mediaItem.value;
        if (current != null) {
          await DiscordPresenceService().updatePresence(current.title, current.artist ?? 'Unknown Artist');
        }
      } else {
        await DiscordPresenceService().setIdle();
      }
    });

    _initSavedState();
  }

  // ─── Diagnostic overrides ─────────────────────────────────────────
  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    debugPrint('[PlayerHandler] click($button)');
    await super.click(button);
  }

  // ─── Unicode path workaround ──────────────────────────────────────
  Future<String> _resolvePlayablePath(String filePath) async {
    final hasNonAscii = filePath.runes.any((r) => r > 127);
    if (!hasNonAscii) return filePath;
    try {
      final tempDir = await getTemporaryDirectory();
      final ext = p.extension(filePath);
      final safeName = 'resonance_track_${filePath.hashCode.abs()}$ext';
      final tempPath = p.join(tempDir.path, safeName);
      final tempFile = File(tempPath);
      final sourceFile = File(filePath);
      final needsCopy = !await tempFile.exists() || (await tempFile.length()) != (await sourceFile.length());
      if (needsCopy) await sourceFile.copy(tempPath);
      return tempPath;
    } catch (e) {
      debugPrint('Unicode path workaround failed for "$filePath": $e');
      return filePath;
    }
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
      final supportDir = await getApplicationSupportDirectory();
      final binDir = p.join(supportDir.path, 'bin');
      final ytDlpPath = p.join(binDir, 'yt-dlp.exe');
      final denoPath = p.join(binDir, 'deno.exe');

      final process = await Process.start(ytDlpPath, [
        '--js-runtimes',
        'deno:$denoPath',
        '--dump-single-json',
        '--no-warnings',
        '--no-playlist',
        '--skip-download',
        '--format',
        'bestaudio[ext=m4a]/bestaudio/best',
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
      final playablePath = await _resolvePlayablePath(filePath);
      return AudioSource.uri(Uri.file(playablePath));
    }
  }

  Future<String> _buildMediaKitUri(String filePath) async {
    final isStream = filePath.startsWith('http://') || filePath.startsWith('https://');
    if (isStream) {
      return _resolveStreamUrl(filePath);
    }
    final playablePath = await _resolvePlayablePath(filePath);
    return Uri.file(playablePath).toString();
  }

  bool get _isWindowsPlaying => _windowsPlayer?.state.playing ?? false;

  Stream<bool> get _playingStream => Platform.isWindows ? _windowsPlayer!.stream.playing : _player.playingStream;

  Duration get _currentPosition => Platform.isWindows ? _windowsPosition : _player.position;

  Duration? get _currentDuration => Platform.isWindows ? _windowsDuration : _player.duration;

  void _updatePlaybackState() {
    if (Platform.isWindows) {
      final playing = _isWindowsPlaying;
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
          processingState: _windowsIsCompleted
              ? AudioProcessingState.completed
              : _windowsIsBuffering
              ? AudioProcessingState.buffering
              : AudioProcessingState.ready,
          playing: playing,
          updatePosition: _windowsPosition,
          bufferedPosition: _windowsBufferedPosition,
          speed: speedNotifier.value,
          queueIndex: 0,
        ),
      );
      return;
    }

    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          _player.playing ? MediaControl.pause : MediaControl.play,
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
        processingState: _getProcessingState(_player.processingState),
        playing: _player.playing,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: _player.currentIndex,
      ),
    );
  }

  // ─── Saved state ──────────────────────────────────────────────────
  Future<void> _initSavedState() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final vol = prefs.getDouble('last_volume') ?? 0.5;
      await changeVolume(vol);

      final speed = prefs.getDouble('last_speed') ?? 1.0;
      if (Platform.isWindows) {
        await _windowsPlayer!.setRate(speed);
      } else {
        await _player.setSpeed(speed);
      }
      speedNotifier.value = speed;

      final pitch = prefs.getDouble('last_pitch') ?? 1.0;
      if (Platform.isWindows) {
        await _windowsPlayer!.setPitch(pitch);
      } else {
        await _player.setPitch(pitch);
      }
      pitchNotifier.value = pitch;

      final savedLoopMode = prefs.getString('last_loop_mode');
      currentLoopMode = LoopMode.values.firstWhere((mode) => mode.name == savedLoopMode, orElse: () => LoopMode.all);
      isShuffle = prefs.getBool('last_shuffle') ?? false;
      if (isShuffle) await shuffleQueue();
      playbackModeRevision.value++;

      final trackPath = prefs.getString('last_track_path');
      final trackTitle = prefs.getString('last_track_title');
      final trackArtist = prefs.getString('last_track_artist');

      if (trackPath != null && trackTitle != null && trackArtist != null) {
        await _preloadTrack(trackPath, trackTitle, trackArtist);
      }
    } catch (e) {
      debugPrint('Error initializing saved state: $e');
    }
  }

  Future<void> _preloadTrack(String filePath, String title, String artist) async {
    try {
      final isStream = filePath.startsWith('http://') || filePath.startsWith('https://');
      if (!isStream && !await File(filePath).exists()) {
        throw StateError('Saved track no longer exists');
      }
      final restored = MediaItem(id: filePath, title: title, artist: artist, artUri: await _albumArtUri(filePath));
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
      } catch (_) {}
    }
  }

  Future<void> _saveTrack(String filePath, String title, String artist) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_track_path', filePath);
      await prefs.setString('last_track_title', title);
      await prefs.setString('last_track_artist', artist);
    } catch (e) {
      debugPrint('Error saving track: $e');
    }
  }

  // ─── Core playback ────────────────────────────────────────────────
  @override
  Future<void> play() async {
    final restored = _pendingRestoredTrack;
    if (restored != null) {
      _pendingRestoredTrack = null;
      await loadTrack(restored.id, restored.title, restored.artist ?? 'Unknown Artist');
      return;
    }
    if (Platform.isWindows) {
      if (_isWindowsPlaying) return;
      await _windowsPlayer!.play();
      _updatePlaybackState();
      return;
    }
    if (_player.playing) return;
    await _player.play();
    _updatePlaybackState();
  }

  @override
  Future<void> pause() async {
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
  Future<void> stop() async {
    _pendingRestoredTrack = null;
    _loadGeneration++;
    _streamUrlCache.clear();

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
    if (Platform.isWindows) {
      await _windowsPlayer!.setRate(speed);
    } else {
      await _player.setSpeed(speed);
    }
    speedNotifier.value = speed;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('last_speed', speed);
    } catch (_) {}
    _updatePlaybackState();
  }

  Future<void> setPitch(double pitch) async {
    final clamped = pitch.clamp(0.5, 2.0);
    if (Platform.isWindows) {
      await _windowsPlayer!.setPitch(clamped);
    } else {
      await _player.setPitch(clamped);
    }
    pitchNotifier.value = clamped;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('last_pitch', clamped);
    } catch (_) {}
    _updatePlaybackState();
  }

  // ─── loadTrack ────────────────────────────────────────────────────
  Future<void> loadTrack(String filePath, String title, String artist) async {
    _pendingRestoredTrack = null;
    final myGen = ++_loadGeneration;
    final isStream = filePath.startsWith('http://') || filePath.startsWith('https://');

    _currentTrackIsStream = isStream;

    // Start artwork extraction alongside player preparation. The final
    // MediaItem update below supplies Android's notification/lockscreen with
    // a real file URI while keeping playback startup responsive.
    final artUriFuture = _albumArtUri(filePath);

    // Optimistic UI update
    mediaItem.add(MediaItem(id: filePath, title: title, artist: artist));
    playbackState.add(
      playbackState.value.copyWith(
        processingState: isStream ? AudioProcessingState.loading : AudioProcessingState.ready,
        playing: false,
      ),
    );

    try {
      if (Platform.isWindows) {
        if (_isWindowsPlaying) await _windowsPlayer!.pause();
      } else if (_player.playing) {
        await _player.pause();
      }
      if (_loadGeneration != myGen) return;

      final prefs = await SharedPreferences.getInstance();
      final savedSpeed = prefs.getDouble('last_speed') ?? 1.0;
      final savedPitch = prefs.getDouble('last_pitch') ?? 1.0;

      if (Platform.isWindows) {
        String uri;
        try {
          uri = await _buildMediaKitUri(filePath);
        } catch (e) {
          if (_loadGeneration != myGen) return;
          debugPrint('[PlayerHandler] Failed to build media_kit URI for "$filePath": $e');
          _streamUrlCache.remove(filePath);
          playbackState.add(playbackState.value.copyWith(processingState: AudioProcessingState.idle, playing: false));
          return;
        }

        if (_loadGeneration != myGen) return;

        _windowsIsBuffering = false;
        _windowsIsCompleted = false;
        _windowsPosition = Duration.zero;
        _windowsDuration = Duration.zero;
        _windowsBufferedPosition = Duration.zero;

        final player = _windowsPlayer!;
        // Open with play: true so it starts immediately.
        // This avoids the race where play() is called before media_kit
        // has finished its internal open sequence.
        await player.open(mk.Media(uri), play: true);
        if (_loadGeneration != myGen) {
          await player.stop();
          return;
        }
        await player.setRate(savedSpeed);
        await player.setPitch(savedPitch);
        await player.setVolume(volumeNotifier.value * 100.0);
      } else {
        AudioSource source;
        try {
          source = await _buildAudioSource(filePath);
        } catch (e) {
          if (_loadGeneration != myGen) return;
          debugPrint('[PlayerHandler] Failed to build audio source for "$filePath": $e');
          _streamUrlCache.remove(filePath);
          playbackState.add(playbackState.value.copyWith(processingState: AudioProcessingState.idle, playing: false));
          return;
        }

        if (_loadGeneration != myGen) return;
        await _player.setAudioSource(source);
        if (_loadGeneration != myGen) return;
        await _player.setSpeed(savedSpeed);
        await _player.setPitch(savedPitch);
      }

      if (_loadGeneration != myGen) return;

      final dur = _currentDuration;
      mediaItem.add(MediaItem(id: filePath, title: title, artist: artist, duration: dur, artUri: await artUriFuture));

      // On non-Windows platforms, explicitly call play() since we didn't
      // pass play: true to setAudioSource.
      if (!Platform.isWindows) {
        await play();
      }

      _updatePlaybackState();
      await _saveTrack(filePath, title, artist);
      await DiscordPresenceService().updatePresence(title, artist);
    } catch (e, st) {
      if (_loadGeneration == myGen) {
        debugPrint('[PlayerHandler] Error loading track "$filePath": $e\n$st');
        _streamUrlCache.remove(filePath);
        playbackState.add(playbackState.value.copyWith(processingState: AudioProcessingState.idle, playing: false));
        _updatePlaybackState();
      }
    }
  }

  // ─── Volume ───────────────────────────────────────────────────────
  Future<void> changeVolume(double rawVolume) async {
    final clamped = rawVolume.clamp(0.0, 2.0);
    volumeNotifier.value = clamped;

    if (Platform.isAndroid) {
      try {
        await _player.setVolume(clamped.clamp(0.0, 1.0));
        await _loudnessEnhancer.setEnabled(clamped > 1.0);
        await _loudnessEnhancer.setTargetGain(clamped > 1.0 ? (clamped - 1.0) * 10.0 : 0.0);
      } catch (e) {
        debugPrint('[PlayerHandler] LoudnessEnhancer unavailable: $e');
      }
    } else if (Platform.isWindows) {
      await _windowsPlayer!.setVolume(clamped * 100.0);
    } else {
      await _player.setVolume(clamped);
    }

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
    if (isStream) {
      final cached = await MetadataCacheService.get(path);
      if (cached != null) return (title: cached.title, artist: cached.artist);
      return (title: 'Streaming Audio', artist: 'YouTube');
    }
    try {
      final metadata = await AudioMetadata.extract(File(path));
      return (
        title: metadata?.trackName ?? p.basenameWithoutExtension(path),
        artist: metadata?.firstArtists ?? 'Unknown Artist',
      );
    } catch (_) {
      return (title: p.basenameWithoutExtension(path), artist: 'Unknown Artist');
    }
  }

  Future<Uri?> _albumArtUri(String path) async {
    if (!Platform.isAndroid || path.startsWith('http://') || path.startsWith('https://')) {
      return null;
    }
    if (_artUriCache.containsKey(path)) return _artUriCache[path];

    try {
      final source = File(path);
      if (!await source.exists()) return _artUriCache[path] = null;
      final modified = await source.lastModified();
      final cacheDir = Directory(p.join((await getTemporaryDirectory()).path, 'notification_art'));
      await cacheDir.create(recursive: true);
      final cacheKey = '${path.hashCode}_${modified.millisecondsSinceEpoch}';

      for (final extension in const ['jpg', 'png', 'webp']) {
        final cached = File(p.join(cacheDir.path, '$cacheKey.$extension'));
        if (await cached.exists() && await cached.length() > 0) {
          return _artUriCache[path] = Uri.file(cached.path);
        }
      }

      final metadata = await MetadataGod.readMetadata(file: path);
      final bytes = metadata.picture?.data;
      if (bytes == null || bytes.isEmpty) return _artUriCache[path] = null;
      final extension = _imageExtension(bytes);
      final artwork = File(p.join(cacheDir.path, '$cacheKey.$extension'));
      await artwork.writeAsBytes(bytes, flush: true);
      return _artUriCache[path] = Uri.file(artwork.path);
    } catch (e) {
      debugPrint('[PlayerHandler] Could not extract notification artwork: $e');
      return _artUriCache[path] = null;
    }
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

  Future<void> next() async {
    final currentItem = mediaItem.value;
    if (currentItem == null) return;
    final playlist = isShuffle ? shuffledList : await _getCleanPlaylist();
    if (playlist.isEmpty) return;
    int index = playlist.indexOf(currentItem.id);
    if (index == -1) index = 0;
    final nextPath = playlist[(index + 1) % playlist.length];
    final meta = await _getTrackMetadata(nextPath);
    await loadTrack(nextPath, meta.title, meta.artist);
  }

  Future<void> previous() async {
    final currentItem = mediaItem.value;
    if (currentItem == null) return;
    final playlist = isShuffle ? shuffledList : await _getCleanPlaylist();
    if (playlist.isEmpty) return;
    int index = playlist.indexOf(currentItem.id);
    if (index == -1) index = 0;
    if (_currentPosition > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }
    final prevIndex = (index - 1 + playlist.length) % playlist.length;
    final meta = await _getTrackMetadata(playlist[prevIndex]);
    await loadTrack(playlist[prevIndex], meta.title, meta.artist);
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

  Stream<Duration> get positionStream => Platform.isWindows ? _windowsPlayer!.stream.position : _player.positionStream;

  Stream<Duration?> get durationStream => Platform.isWindows ? _windowsPlayer!.stream.duration : _player.durationStream;

  Future<void> setQueue(List<MediaItem> tracks) async {
    await updateQueue(tracks);
    if (tracks.isNotEmpty && mediaItem.value == null) {
      await playMediaItem(tracks[0]);
    }
  }

  @override
  Future<void> playMediaItem(MediaItem mediaItem) async {
    try {
      if (Platform.isWindows) {
        final uri = await _buildMediaKitUri(mediaItem.id);
        await _windowsPlayer!.open(mk.Media(uri), play: true);
      } else {
        final source = await _buildAudioSource(mediaItem.id);
        await _player.setAudioSource(source);
        await play();
      }
      this.mediaItem.add(
        mediaItem.artUri == null ? mediaItem.copyWith(artUri: await _albumArtUri(mediaItem.id)) : mediaItem,
      );
      await _saveTrack(mediaItem.id, mediaItem.title, mediaItem.artist ?? 'Unknown Artist');
    } catch (e, st) {
      debugPrint('Error playing media item "${mediaItem.id}": $e\n$st');
      _updatePlaybackState();
    }
  }

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

  Future<void> toggleShuffle() async {
    isShuffle = !isShuffle;
    if (isShuffle) await shuffleQueue();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('last_shuffle', isShuffle);
    playbackModeRevision.value++;
  }

  Future<void> saveState() async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setDouble('last_volume', volumeNotifier.value),
      prefs.setDouble('last_speed', speedNotifier.value),
      prefs.setDouble('last_pitch', pitchNotifier.value),
      prefs.setString('last_loop_mode', currentLoopMode.name),
      prefs.setBool('last_shuffle', isShuffle),
    ]);
    final current = mediaItem.value;
    if (current != null) {
      await _saveTrack(current.id, current.title, current.artist ?? 'Unknown Artist');
    }
  }

  Future<void> shuffleQueue() async {
    final clean = await _getCleanPlaylist();
    shuffledList = List.from(clean)..shuffle();
  }

  Future<List<String>> _getCleanPlaylist() async {
    final content = await FileService().readTextFromFile();
    return content.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty && !l.startsWith('#')).toList();
  }

  bool getShuffleMode() => isShuffle;
  LoopMode getLoopMode() => currentLoopMode;

  Future<void> dispose() async {
    await saveState();
    await _windowsStreamProxy.dispose();
    await _windowsPlayer?.dispose();
    await _player.dispose();
    await DiscordPresenceService().clearPresence();
    await DiscordPresenceService().dispose();
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
