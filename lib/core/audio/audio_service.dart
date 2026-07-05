// lib/core/audio/audio_service.dart

import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/services/discord_presence_service.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:audio_metadata_extractor/audio_metadata_extractor.dart';

class PlayerHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final _player = AudioPlayer();

  double savedVolume = 1.0;
  final ValueNotifier<double> volumeNotifier = ValueNotifier<double>(1.0);
  final ValueNotifier<double> speedNotifier = ValueNotifier<double>(1.0);
  final ValueNotifier<double> pitchNotifier = ValueNotifier<double>(1.0);
  LoopMode currentLoopMode = LoopMode.all;
  bool isShuffle = false;
  List<String> shuffledList = [];

  int _loadGeneration = 0;

  // Session-scoped cache: YouTube URL → resolved CDN/HLS URL.
  // CDN URLs typically expire after ~6 hours so we invalidate on error.
  final Map<String, String> _streamUrlCache = {};

  PlayerHandler() {
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

    _player.playingStream.listen((isPlaying) async {
      if (isPlaying) {
        final current = mediaItem.value;
        if (current != null) {
          await DiscordPresenceService()
              .updatePresence(current.title, current.artist ?? 'Unknown Artist');
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

  @override
  Future<void> fastForward() async { await super.fastForward(); }

  @override
  Future<void> rewind() async { await super.rewind(); }

  @override
  Future<void> seekForward(bool begin) async { await super.seekForward(begin); }

  @override
  Future<void> seekBackward(bool begin) async { await super.seekBackward(begin); }

  @override
  Future<void> stop() async { await super.stop(); }

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    return super.customAction(name, extras);
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
      final needsCopy = !await tempFile.exists() ||
          (await tempFile.length()) != (await sourceFile.length());
      if (needsCopy) await sourceFile.copy(tempPath);
      return tempPath;
    } catch (e) {
      debugPrint('Unicode path workaround failed for "$filePath": $e');
      return filePath;
    }
  }

  // ─── Stream URL resolution ────────────────────────────────────────
  // Returns a URL suitable for just_audio to play directly.
  // Uses LockCachingAudioSource wrapper so seeking works on streams.
  Future<String> _resolveStreamUrl(String url) async {
    if (_streamUrlCache.containsKey(url)) {
      debugPrint('[PlayerHandler] Stream URL cache hit');
      return _streamUrlCache[url]!;
    }

    String resolved;

    if (Platform.isWindows) {
      final supportDir = await getApplicationSupportDirectory();
      final binDir = p.join(supportDir.path, 'bin');
      final ytDlpPath = p.join(binDir, 'yt-dlp.exe');
      final denoPath = p.join(binDir, 'deno.exe');

      final process = await Process.start(ytDlpPath, [
        '--js-runtimes', 'deno:$denoPath',
        '-g',
        '-f', 'bestaudio[ext=m4a]/bestaudio/best',
        '--no-playlist',
        url,
      ]);
      process.stderr.drain();
      final lines = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .toList();
      await process.exitCode;
      if (lines.isEmpty) throw Exception('yt-dlp returned no URL');
      resolved = lines.first.trim();

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

    _streamUrlCache[url] = resolved;
    return resolved;
  }

  // Build the right AudioSource for a URL.
  // For streams: LockCachingAudioSource enables seeking by buffering to disk.
  // For local files: plain AudioSource.uri.
  Future<AudioSource> _buildAudioSource(String filePath) async {
    final isStream =
        filePath.startsWith('http://') || filePath.startsWith('https://');

    if (isStream) {
      final resolvedUrl = await _resolveStreamUrl(filePath);
      final uri = Uri.parse(resolvedUrl);
      // LockCachingAudioSource buffers the stream locally so seeks work.
      // The cache is keyed by the *original* YouTube URL so the same track
      // reuses its buffer across the session.
      try {
        return LockCachingAudioSource(uri);
      } catch (_) {
        // Fallback to plain URI if LockCachingAudioSource fails
        return AudioSource.uri(uri);
      }
    } else {
      final playablePath = await _resolvePlayablePath(filePath);
      return AudioSource.uri(Uri.file(playablePath));
    }
  }

  void _updatePlaybackStateToLoading() {
    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.loading,
    ));
  }

  void _updatePlaybackState() {
    playbackState.add(playbackState.value.copyWith(
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
    ));
  }

  // ─── Saved state ──────────────────────────────────────────────────
  Future<void> _initSavedState() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final vol = prefs.getDouble('last_volume') ?? 0.5;
      await changeVolume(vol);

      final speed = prefs.getDouble('last_speed') ?? 1.0;
      await _player.setSpeed(speed);

      final pitch = prefs.getDouble('last_pitch') ?? 1.0;
      await _player.setPitch(pitch);
      pitchNotifier.value = pitch;

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
      final isStream =
          filePath.startsWith('http://') || filePath.startsWith('https://');
      if (isStream) {
        // Don't auto-resolve streams on startup — just show the track in UI.
        mediaItem.add(MediaItem(id: filePath, title: title, artist: artist));
        _updatePlaybackState();
        return;
      }
      final source = await _buildAudioSource(filePath);
      await _player.setAudioSource(source);
      mediaItem.add(MediaItem(
          id: filePath, title: title, artist: artist,
          duration: _player.duration));
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
    if (_player.playing) return;
    await _player.play();
    _updatePlaybackState();
  }

  @override
  Future<void> pause() async {
    if (!_player.playing) return;
    await _player.pause();
    _updatePlaybackState();
  }

  @override
  Future<void> seek(Duration position) async {
    await _player.seek(position);
    _updatePlaybackState();
  }

  @override
  Future<void> skipToNext() async => next();

  @override
  Future<void> skipToPrevious() async => previous();

  @override
  Future<void> setSpeed(double speed) async {
    await _player.setSpeed(speed);
    speedNotifier.value = speed;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('last_speed', speed);
    } catch (_) {}
    _updatePlaybackState();
  }

  Future<void> setPitch(double pitch) async {
    final clamped = pitch.clamp(0.5, 2.0);
    await _player.setPitch(clamped);
    pitchNotifier.value = clamped;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('last_pitch', clamped);
    } catch (_) {}
    _updatePlaybackState();
  }

  // ─── loadTrack ────────────────────────────────────────────────────
  // Optimistic update: mediaItem shifts immediately.
  // Serial guard: stale loads abort before touching _player.
  Future<void> loadTrack(String filePath, String title, String artist) async {
    final myGen = ++_loadGeneration;

    // Optimistic UI shift
    mediaItem.add(MediaItem(id: filePath, title: title, artist: artist));
    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.loading,
      playing: false,
    ));

    try {
      if (_player.playing) await _player.pause();
      if (_loadGeneration != myGen) return;

      final source = await _buildAudioSource(filePath);
      if (_loadGeneration != myGen) return;

      await _player.setAudioSource(source);
      if (_loadGeneration != myGen) return;

      final prefs = await SharedPreferences.getInstance();
      await _player.setSpeed(prefs.getDouble('last_speed') ?? 1.0);
      await _player.setPitch(prefs.getDouble('last_pitch') ?? 1.0);

      if (_loadGeneration != myGen) return;

      // Emit updated mediaItem with duration if available immediately
      final dur = _player.duration;
      mediaItem.add(MediaItem(
          id: filePath, title: title, artist: artist, duration: dur));

      await _player.play();
      _updatePlaybackState();
      await _saveTrack(filePath, title, artist);
      await DiscordPresenceService().updatePresence(title, artist);
    } catch (e, st) {
      if (_loadGeneration == myGen) {
        debugPrint('Error loading track "$filePath": $e\n$st');
        // Invalidate cached stream URL on error (it may have expired)
        _streamUrlCache.remove(filePath);
        _updatePlaybackState();
      }
    }
  }

  // ─── Volume — true gain above 1.0 ────────────────────────────────
  // just_audio's setVolume() on Android/Windows accepts values > 1.0
  // as a gain multiplier (it uses ExoPlayer/WASAPI gain staging).
  // We allow up to 2.0 (200%) and pass the raw value directly.
  Future<void> changeVolume(double rawVolume) async {
    final clamped = rawVolume.clamp(0.0, 2.0);
    volumeNotifier.value = clamped;
    await _player.setVolume(clamped); // pass raw — just_audio handles gain
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('last_volume', clamped);
    } catch (_) {}
  }

  Future<void> incrementVolume() async =>
      changeVolume(volumeNotifier.value + 0.05);

  Future<void> decrementVolume() async =>
      changeVolume(volumeNotifier.value - 0.05);

  Future<void> incrementSpeed() async =>
      setSpeed((speedNotifier.value + 0.1).clamp(0.5, 2.0));

  Future<void> decrementSpeed() async =>
      setSpeed((speedNotifier.value - 0.1).clamp(0.5, 2.0));

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
    if (_player.position > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
      return;
    }
    final prevIndex = (index - 1 + playlist.length) % playlist.length;
    final meta = await _getTrackMetadata(playlist[prevIndex]);
    await loadTrack(playlist[prevIndex], meta.title, meta.artist);
  }

  Future<bool> isPlaying() async => _player.playing;

  Future<void> playPause() async {
    if (_player.playing) await pause(); else await play();
  }

  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;

  Future<void> setQueue(List<MediaItem> tracks) async {
    await updateQueue(tracks);
    if (tracks.isNotEmpty && mediaItem.value == null) {
      await playMediaItem(tracks[0]);
    }
  }

  @override
  Future<void> playMediaItem(MediaItem item) async {
    try {
      final source = await _buildAudioSource(item.id);
      await _player.setAudioSource(source);
      mediaItem.add(item);
      await _player.play();
      await _saveTrack(item.id, item.title, item.artist ?? 'Unknown Artist');
    } catch (e, st) {
      debugPrint('Error playing media item "${item.id}": $e\n$st');
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
  }

  Future<void> toggleShuffle() async {
    isShuffle = !isShuffle;
    if (isShuffle) await shuffleQueue();
  }

  Future<void> shuffleQueue() async {
    final clean = await _getCleanPlaylist();
    shuffledList = List.from(clean)..shuffle();
  }

  Future<List<String>> _getCleanPlaylist() async {
    final content = await FileService().readTextFromFile();
    return content
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .toList();
  }

  bool getShuffleMode() => isShuffle;
  LoopMode getLoopMode() => currentLoopMode;

  Future<void> dispose() async {
    await _player.dispose();
    await DiscordPresenceService().clearPresence();
    await DiscordPresenceService().dispose();
  }

  AudioProcessingState _getProcessingState(ProcessingState state) {
    switch (state) {
      case ProcessingState.loading:    return AudioProcessingState.loading;
      case ProcessingState.buffering:  return AudioProcessingState.buffering;
      case ProcessingState.ready:      return AudioProcessingState.ready;
      case ProcessingState.completed:  return AudioProcessingState.completed;
      default:                         return AudioProcessingState.idle;
    }
  }
}