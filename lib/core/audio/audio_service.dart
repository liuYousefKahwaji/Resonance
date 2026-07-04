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

  PlayerHandler() {
    _player.playbackEventStream.listen((event) {
      _updatePlaybackState();
    });

    _player.volumeStream.listen((volume) {
      volumeNotifier.value = volume;
    });

    _player.speedStream.listen((speed) {
      speedNotifier.value = speed;
    });

    _player.playingStream.listen((isPlaying) {
      _updatePlaybackState();
    });

    _player.durationStream.listen((duration) {
      final currentItem = mediaItem.value;
      if (currentItem != null && duration != null) {
        mediaItem.add(currentItem.copyWith(duration: duration));
      }
      _updatePlaybackState();
    });

    // ── Frequent position updates for notification seekbar ──
    _player.positionStream.listen((position) {
      _updatePlaybackState();
    });

    _player.processingStateStream.listen((state) async {
      if (state == ProcessingState.completed) {
        if (currentLoopMode == LoopMode.one) {
          _player.seek(Duration.zero);
          _player.pause();
          _player.play();
        } else if (currentLoopMode == LoopMode.all) {
          await _player.seek(Duration.zero);
          await next();
        }
      }
    });

    _player.playingStream.listen((isPlaying) async {
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

  // ─── Diagnostic overrides ──────────────────────────────────────────
  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    debugPrint('[PlayerHandler] click($button)');
    await super.click(button);
  }

  @override
  Future<void> fastForward() async {
    debugPrint('[PlayerHandler] fastForward()');
    await super.fastForward();
  }

  @override
  Future<void> rewind() async {
    debugPrint('[PlayerHandler] rewind()');
    await super.rewind();
  }

  @override
  Future<void> seekForward(bool begin) async {
    debugPrint('[PlayerHandler] seekForward($begin)');
    await super.seekForward(begin);
  }

  @override
  Future<void> seekBackward(bool begin) async {
    debugPrint('[PlayerHandler] seekBackward($begin)');
    await super.seekBackward(begin);
  }

  @override
  Future<void> stop() async {
    debugPrint('[PlayerHandler] stop()');
    await super.stop();
  }

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    debugPrint('[PlayerHandler] customAction($name, $extras)');
    return super.customAction(name, extras);
  }

  // ─── Unicode path workaround ──────────────────────────────────────
  Future<String> _resolvePlayablePath(String filePath) async {
    final hasNonAscii = filePath.runes.any((rune) => rune > 127);
    if (!hasNonAscii) return filePath;

    try {
      final tempDir = await getTemporaryDirectory();
      final ext = p.extension(filePath);
      final safeName = 'resonance_track_${filePath.hashCode.abs()}$ext';
      final tempPath = p.join(tempDir.path, safeName);
      final tempFile = File(tempPath);
      final sourceFile = File(filePath);

      final needsCopy = !await tempFile.exists() || (await tempFile.length()) != (await sourceFile.length());

      if (needsCopy) {
        await sourceFile.copy(tempPath);
      }

      return tempPath;
    } catch (e) {
      debugPrint('Unicode path workaround failed for "$filePath": $e');
      return filePath;
    }
  }

  Future<String> _resolveStreamUrl(String url) async {
    if (Platform.isWindows) {
      final supportDir = await getApplicationSupportDirectory();
      final binDir = p.join(supportDir.path, 'bin');
      final ytDlpPath = p.join(binDir, 'yt-dlp.exe');
      final denoPath = p.join(binDir, 'deno.exe');

      final process = await Process.start(ytDlpPath, [
        '--js-runtimes',
        'deno:$denoPath',
        '-g',
        '-f',
        'bestaudio/best',
        url,
      ]);

      process.stderr.drain();
      final lines = await process.stdout.transform(utf8.decoder).transform(const LineSplitter()).toList();
      await process.exitCode;

      if (lines.isNotEmpty) {
        return lines.first.trim();
      }
      throw Exception('Failed to extract streaming URL via yt-dlp');
    } else if (Platform.isAndroid) {
      const channel = MethodChannel('resonance/android_youtube');
      final streamUrl = await channel.invokeMethod<String>('getStreamUrl', {'url': url});
      if (streamUrl != null && streamUrl.isNotEmpty) {
        return streamUrl;
      }
      throw Exception('Failed to extract streaming URL via MethodChannel');
    }
    throw UnsupportedError('Platform not supported for streaming');
  }

  void _updatePlaybackStateToLoading() {
    playbackState.add(
      playbackState.value.copyWith(
        processingState: AudioProcessingState.loading,
      ),
    );
  }

  // ─── Playback state updates ──────────────────────────────────────
  void _updatePlaybackState() {
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
        updatePosition: _player.position, // ✅ correct parameter
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

      final savedVolume = prefs.getDouble('last_volume') ?? 0.5;
      await changeVolume(savedVolume);

      final savedSpeed = prefs.getDouble('last_speed') ?? 1.0;
      await _player.setSpeed(savedSpeed);

      final savedPitch = prefs.getDouble('last_pitch') ?? 1.0;
      await _player.setPitch(savedPitch);
      pitchNotifier.value = savedPitch;

      final trackPath = prefs.getString('last_track_path');
      final trackTitle = prefs.getString('last_track_title');
      final trackArtist = prefs.getString('last_track_artist');

      if (trackPath != null && trackTitle != null && trackArtist != null) {
        await _preloadTrack(trackPath, trackTitle, trackArtist);
      }
    } catch (e) {
      debugPrint("Error initializing saved state: $e");
    }
  }

  Future<void> _preloadTrack(String filePath, String title, String artist) async {
    try {
      final isStream = filePath.startsWith('http://') || filePath.startsWith('https://');
      Uri uri;
      if (isStream) {
        final resolvedUrl = await _resolveStreamUrl(filePath);
        uri = Uri.parse(resolvedUrl);
      } else {
        final playablePath = await _resolvePlayablePath(filePath);
        uri = Uri.file(playablePath);
      }
      await _player.setAudioSource(AudioSource.uri(uri));
      final duration = _player.duration;
      MediaItem item = MediaItem(id: filePath, title: title, artist: artist, duration: duration);
      mediaItem.add(item);
      _updatePlaybackState();
    } catch (e) {
      debugPrint("Error preloading track: $e");
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
      debugPrint("Error saving track: $e");
    }
  }

  // ─── Core playback methods ───────────────────────────────────────
  @override
  Future<void> play() async {
    debugPrint('[PlayerHandler] play()');
    if (_player.playing) return;
    await _player.play();
    _updatePlaybackState(); // immediate update
  }

  @override
  Future<void> setSpeed(double speed) async {
    debugPrint('[PlayerHandler] setSpeed($speed)');
    await _player.setSpeed(speed);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('last_speed', speed);
    } catch (e) {
      debugPrint("Error saving speed: $e");
    }
    _updatePlaybackState();
  }

  Future<void> setPitch(double pitch) async {
  final clamped = pitch.clamp(0.5, 2.0);
  await _player.setPitch(clamped);
  pitchNotifier.value = clamped;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('last_pitch', clamped);
  } catch (e) {
    debugPrint("Error saving pitch: $e");
  }
  _updatePlaybackState();
}

  @override
  Future<void> pause() async {
    debugPrint('[PlayerHandler] pause()');
    if (!_player.playing) return;
    await _player.pause();
    _updatePlaybackState(); // immediate update
  }

  @override
  Future<void> seek(Duration position) async {
    debugPrint('[PlayerHandler] seek($position)');
    await _player.seek(position);
    _updatePlaybackState(); // immediate update after seek
  }

  @override
  Future<void> skipToNext() async {
    debugPrint('[PlayerHandler] skipToNext()');
    await next();
  }

  @override
  Future<void> skipToPrevious() async {
    debugPrint('[PlayerHandler] skipToPrevious()');
    await previous();
  }

  Future<void> loadTrack(String filePath, String title, String artist) async {
    try {
      final wasPlaying = _player.playing;
      if (wasPlaying) {
        await _player.pause();
      }

      final isStream = filePath.startsWith('http://') || filePath.startsWith('https://');
      Uri uri;
      if (isStream) {
        _updatePlaybackStateToLoading();
        final resolvedUrl = await _resolveStreamUrl(filePath);
        uri = Uri.parse(resolvedUrl);
      } else {
        final playablePath = await _resolvePlayablePath(filePath);
        uri = Uri.file(playablePath);
      }

      await _player.setAudioSource(AudioSource.uri(uri));

      final prefs = await SharedPreferences.getInstance();

      final savedSpeed = prefs.getDouble('last_speed') ?? 1.0;
      await _player.setSpeed(savedSpeed);

      final savedPitch = prefs.getDouble('last_pitch') ?? 1.0;
      await _player.setPitch(savedPitch);

      final duration = _player.duration;
      MediaItem item = MediaItem(id: filePath, title: title, artist: artist, duration: duration);
      mediaItem.add(item);

      await _player.play();
      _updatePlaybackState();
      await _saveTrack(filePath, title, artist);
      await DiscordPresenceService().updatePresence(title, artist);
    } catch (e, st) {
      debugPrint('Error loading track "$filePath": $e\n$st');
      _updatePlaybackState();
    }
  }

  Future<void> changeVolume(double volume) async {
    final clamped = volume.clamp(0.0, 1.0);
    volumeNotifier.value = clamped;
    await _player.setVolume(clamped);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('last_volume', clamped);
    } catch (e) {
      debugPrint("Error saving volume: $e");
    }
  }

  Future<void> incrementVolume() async {
    double newVol = volumeNotifier.value + 0.05;
    newVol = newVol.clamp(0.0, 1.0);
    await changeVolume(newVol);
  }

  Future<void> decrementVolume() async {
    double newVol = volumeNotifier.value - 0.05;
    newVol = newVol.clamp(0.0, 1.0);
    await changeVolume(newVol);
  }

  Future<void> incrementSpeed() async {
    double newSpeed = speedNotifier.value + 0.1;
    newSpeed = newSpeed.clamp(0.5, 2.0);
    await setSpeed(newSpeed);
  }

  Future<void> decrementSpeed() async {
    double newSpeed = speedNotifier.value - 0.1;
    newSpeed = newSpeed.clamp(0.5, 2.0);
    await setSpeed(newSpeed);
  }

  Future<({String title, String artist})> _getTrackMetadata(String path) async {
    final isStream = path.startsWith('http://') || path.startsWith('https://');
    if (isStream) {
      final cached = await MetadataCacheService.get(path);
      if (cached != null) {
        return (title: cached.title, artist: cached.artist);
      }
      return (title: 'Streaming Audio', artist: 'YouTube');
    } else {
      try {
        final metadata = await AudioMetadata.extract(File(path));
        return (
          title: metadata?.trackName ?? p.basenameWithoutExtension(path),
          artist: metadata?.firstArtists ?? 'Unknown Artist',
        );
      } catch (_) {
        return (
          title: p.basenameWithoutExtension(path),
          artist: 'Unknown Artist',
        );
      }
    }
  }

  Future<void> next() async {
    final currentItem = mediaItem.value;
    if (currentItem == null) return;

    final playlist = isShuffle ? shuffledList : await _getCleanPlaylist();
    if (playlist.isEmpty) return;

    int index = playlist.indexOf(currentItem.id);
    if (index == -1) {
      index = 0;
    }

    int nextIndex = (index + 1) % playlist.length;
    final nextPath = playlist[nextIndex];

    final wasPlaying = _player.playing;
    if (wasPlaying) {
      await _player.pause();
    }

    final meta = await _getTrackMetadata(nextPath);
    await loadTrack(nextPath, meta.title, meta.artist);
  }

  Future<void> previous() async {
    final currentItem = mediaItem.value;
    if (currentItem == null) return;

    final playlist = isShuffle ? shuffledList : await _getCleanPlaylist();
    if (playlist.isEmpty) return;

    int index = playlist.indexOf(currentItem.id);
    if (index == -1) {
      index = 0;
    }

    int prevIndex = (index - 1) % playlist.length;
    if (prevIndex < 0) prevIndex = playlist.length - 1;
    final prevPath = playlist[prevIndex];

    if (_player.position > Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
      return;
    }

    final wasPlaying = _player.playing;
    if (wasPlaying) {
      await _player.pause();
    }

    final meta = await _getTrackMetadata(prevPath);
    await loadTrack(prevPath, meta.title, meta.artist);
  }

  Future<bool> isPlaying() async => _player.playing;

  Future<void> playPause() async {
    debugPrint('[PlayerHandler] playPause()');
    if (_player.playing) {
      await pause();
    } else {
      await play();
    }
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
  Future<void> playMediaItem(MediaItem mediaItem) async {
    try {
      final isStream = mediaItem.id.startsWith('http://') || mediaItem.id.startsWith('https://');
      Uri uri;
      if (isStream) {
        _updatePlaybackStateToLoading();
        final resolvedUrl = await _resolveStreamUrl(mediaItem.id);
        uri = Uri.parse(resolvedUrl);
      } else {
        final playablePath = await _resolvePlayablePath(mediaItem.id);
        uri = Uri.file(playablePath);
      }
      await _player.setAudioSource(AudioSource.uri(uri));
      this.mediaItem.add(mediaItem);
      await _player.play();
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
  }

  Future<void> toggleShuffle() async {
    isShuffle = !isShuffle;
    if (isShuffle) {
      await shuffleQueue();
    }
  }

  Future<void> shuffleQueue() async {
    final clean = await _getCleanPlaylist();
    shuffledList = List.from(clean);
    shuffledList.shuffle();
  }

  Future<void> toggleMute() async {
    if (volumeNotifier.value == 0) {
      changeVolume(savedVolume);
    } else {
      savedVolume = volumeNotifier.value;
      changeVolume(0);
    }
  }

  Future<List<String>> _getCleanPlaylist() async {
    final content = await FileService().readTextFromFile();
    return content
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
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
      case ProcessingState.loading:
        return AudioProcessingState.loading;
      case ProcessingState.ready:
        return AudioProcessingState.ready;
      case ProcessingState.completed:
        return AudioProcessingState.completed;
      default:
        return AudioProcessingState.idle;
    }
  }
}