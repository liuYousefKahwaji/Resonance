import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/services/discord_presence_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:audio_metadata_extractor/audio_metadata_extractor.dart';

// 1. The Handler: Connects just_audio to audio_service
class PlayerHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final _player = AudioPlayer();
  double savedVolume = 1.0;
  final ValueNotifier<double> volumeNotifier = ValueNotifier<double>(1.0);
  LoopMode currentLoopMode = LoopMode.all;
  bool isShuffle = false;
  List<String> shuffledList = [];

  PlayerHandler() {
    // Listen to ALL player events, not just playbackEventStream
    _player.playbackEventStream.listen((event) {
      _updatePlaybackState();
    });

    _player.volumeStream.listen((volume) {
      volumeNotifier.value = volume;
    });

    // Also listen to playing state directly
    _player.playingStream.listen((isPlaying) {
      _updatePlaybackState();
    });

    _player.durationStream.listen((duration) {
      // When duration changes (metadata loads), update the media item
      final currentItem = mediaItem.value;
      if (currentItem != null && duration != null) {
        mediaItem.add(currentItem.copyWith(duration: duration));
      }
      _updatePlaybackState();
    });

    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        if (currentLoopMode == LoopMode.one) {
          _player.seek(Duration.zero);
          _player.play();
          _player.pause();
          _player.play();
        } else if (currentLoopMode == LoopMode.all) {
          next(); // go to next track in queue
        } else {
          // stop or do nothing
        }
      }
    });

    // Listen to playback state to update Discord presence
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

  // =======================================================================
  // DIAGNOSTICS
  //
  // skipToNext/skipToPrevious below print nothing even when the hardware
  // Next/Previous media keys successfully change the track. That means
  // audio_service_win is calling some OTHER AudioHandler method for these
  // buttons. The overrides below log every plausible candidate so we can
  // see, in the console, exactly which one fires on a real key press.
  //
  // Once we know which method it is, we can remove the unused overrides
  // and fix the real one (e.g. make it call _player.pause() once before
  // next()/previous() so the "press play/pause once first" requirement
  // goes away).
  // =======================================================================

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

  // =======================================================================
  // Unicode path workaround.
  //
  // just_audio_windows (Media Foundation backend) can fail to load files
  // whose path contains non-ASCII characters (e.g. Chinese/Japanese/
  // Korean filenames) - either silently failing to find the file, or
  // throwing PlatformException(sourceNotSupported).
  //
  // If the path has non-ASCII characters, we copy the file to a temp
  // file with a sanitized ASCII-only name and play THAT instead. The
  // original path is still used everywhere else (playlist matching,
  // MediaItem id, metadata, saved state) - only the actual audio source
  // handed to just_audio is swapped.
  //
  // NOTE: this requires the temp directory path itself to be ASCII
  // (normally true on Windows: C:\Users\<name>\AppData\Local\Temp).
  // =======================================================================
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

  void _updatePlaybackState() {
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          _player.playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        // Tells OS-level media transport controls (Windows SMTC, lock
        // screen, etc.) which actions should be enabled.
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
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: _player.currentIndex,
      ),
    );
  }

  Future<void> _initSavedState() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Load saved volume (fallback to 0.5)
      final savedVolume = prefs.getDouble('last_volume') ?? 0.5;
      await changeVolume(savedVolume);

      // Load last track details
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
      final playablePath = await _resolvePlayablePath(filePath);
      final uri = Uri.file(playablePath);
      await _player.setAudioSource(AudioSource.uri(uri));
      final duration = _player.duration;
      MediaItem item = MediaItem(id: filePath, title: title, artist: artist, duration: duration);
      mediaItem.add(item);
      _updatePlaybackState();
    } catch (e) {
      debugPrint("Error preloading track: $e");
      // The saved track is unplayable. Clear it so this doesn't repeat
      // on every future launch.
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

  @override
  Future<void> play() async {
    debugPrint('[PlayerHandler] play()');
    await _player.play();
  }

  @override
  Future<void> pause() async {
    debugPrint('[PlayerHandler] pause()');
    await _player.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    debugPrint('[PlayerHandler] seek($position)');
    await _player.seek(position);
  }

  @override
  Future<void> skipToNext() async {
    debugPrint('[PlayerHandler] skipToNext()');
    await _player.pause();
    await next();
  }

  @override
  Future<void> skipToPrevious() async {
    debugPrint('[PlayerHandler] skipToPrevious()');
    await _player.pause();
    await previous();
  }

  Future<void> loadTrack(String filePath, String title, String artist) async {
    try {
      final playablePath = await _resolvePlayablePath(filePath);
      final uri = Uri.file(playablePath);
      await _player.setAudioSource(AudioSource.uri(uri));

      final duration = _player.duration;
      MediaItem item = MediaItem(id: filePath, title: title, artist: artist, duration: duration);
      mediaItem.add(item);
      pause();
      play();
      _updatePlaybackState();
      await _saveTrack(filePath, title, artist);
      await DiscordPresenceService().updatePresence(title, artist);
    } catch (e, st) {
      debugPrint('Error loading track "$filePath": $e\n$st');
    }
  }

  Future<void> changeVolume(double volume) async {
    final clamped = volume.clamp(0.0, 1.0);
    await _player.setVolume(clamped);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('last_volume', clamped);
    } catch (e) {
      debugPrint("Error saving volume: $e");
    }
  }

  Future<void> incrementVolume() async {
    double newVol = _player.volume + 0.05;
    newVol = newVol.clamp(0.0, 1.0);
    await changeVolume(newVol);
  }

  Future<void> decrementVolume() async {
    double newVol = _player.volume - 0.05;
    newVol = newVol.clamp(0.0, 1.0);
    await changeVolume(newVol);
  }

  Future<void> next() async {
    final currentItem = mediaItem.value;
    if (currentItem == null) return;

    final playlist = isShuffle ? shuffledList : await _getCleanPlaylist();
    if (playlist.isEmpty) return;

    int index = playlist.indexOf(currentItem.id);
    if (index == -1) {
      // Current track not found – just play first track
      index = 0;
    }

    int nextIndex = (index + 1) % playlist.length; // wraps around
    final nextPath = playlist[nextIndex];
    final metadata = await AudioMetadata.extract(File(nextPath));
    await loadTrack(
      nextPath,
      metadata?.trackName ?? p.basenameWithoutExtension(nextPath),
      metadata?.firstArtists ?? 'Unknown Artist',
    );
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
    final metadata = await AudioMetadata.extract(File(prevPath));
    if (_player.position > Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
    } else {
      await loadTrack(
        prevPath,
        metadata?.trackName ?? p.basenameWithoutExtension(prevPath),
        metadata?.firstArtists ?? 'Unknown Artist',
      );
    }
  }

  Future<bool> isPlaying() async {
    return _player.playing;
  }

  Future<void> playPause() async {
    debugPrint('[PlayerHandler] playPause()');
    if (_player.playing) {
      _player.pause();
    } else {
      _player.play();
    }
  }

  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;

  // Add a list of tracks to the queue
  Future<void> setQueue(List<MediaItem> tracks) async {
    await updateQueue(tracks);
    if (tracks.isNotEmpty && mediaItem.value == null) {
      await playMediaItem(tracks[0]);
    }
  }

  @override
  Future<void> playMediaItem(MediaItem mediaItem) async {
    try {
      final playablePath = await _resolvePlayablePath(mediaItem.id);
      await _player.setAudioSource(AudioSource.uri(Uri.file(playablePath)));
      this.mediaItem.add(mediaItem);
      play();

      await _saveTrack(mediaItem.id, mediaItem.title, mediaItem.artist ?? 'Unknown Artist');
    } catch (e, st) {
      debugPrint('Error playing media item "${mediaItem.id}": $e\n$st');
    }
  }

  Future<void> toggleLoopMode() async {
    if (currentLoopMode == LoopMode.off) {
      currentLoopMode = LoopMode.one;
      return;
    }
    if (currentLoopMode == LoopMode.one) {
      currentLoopMode = LoopMode.all;
      return;
    }
    if (currentLoopMode == LoopMode.all) {
      currentLoopMode = LoopMode.off;
      return;
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
