import 'dart:async';
import 'package:resonance/core/audio/media_source_readiness.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:resonance/models/youtube_video_source.dart';
import 'package:resonance/services/youtube/youtube_video_service.dart';

class StandaloneVideoFrame {
  const StandaloneVideoFrame({
    required this.trackId,
    required this.generation,
    required this.position,
    required this.playing,
    required this.rate,
    required this.seekRevision,
    this.loading = false,
  });
  final String trackId;
  final int generation, seekRevision;
  final Duration position;
  final bool playing, loading;
  final double rate;
}

/// PlayerHandler remains the sole audio/queue/notification authority. This
/// decoder has no audio track or output device; it only supplies video frames.
class StandaloneVideoSession extends ChangeNotifier {
  StandaloneVideoSession({
    required this.frame,
    required this.activateAudio,
    required this.restoreAudio,
    this.versionsLoader,
    this.streamLoader,
    mk.Player Function()? createPlayer,
    VideoController? Function(mk.Player)? createController,
  }) : _createPlayer = createPlayer ?? (() => mk.Player()),
       _createController = createController ?? ((player) => VideoController(player));
  final StandaloneVideoFrame? Function() frame;
  final Future<Duration?> Function(
    ResolvedYoutubeVideo source,
    YoutubeMediaVersions versions,
    StandaloneVideoFrame frame,
    bool Function() current,
  )
  activateAudio;
  final Future<void> Function(StandaloneVideoFrame frame, YoutubeMediaVersions? versions, bool Function() current)
  restoreAudio;
  final Future<YoutubeMediaVersions> Function(String)? versionsLoader;
  final Future<ResolvedYoutubeVideo> Function(String)? streamLoader;
  final mk.Player Function() _createPlayer;
  final VideoController? Function(mk.Player) _createController;
  mk.Player? _player;
  VideoController? controller;
  Timer? _timer;
  StreamSubscription<String>? _errors;
  bool enabled = false, preparing = false, wantsVideo = false, unavailable = false;
  String? error;
  int _epoch = 0;
  bool _disposed = false, _syncing = false, _wasBuffering = false;
  StandaloneVideoFrame? _owner;
  YoutubeMediaVersions? _versions;
  int? _seekRevision;
  DateTime _lastVideoSeek = DateTime.fromMillisecondsSinceEpoch(0);

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  bool _current(int epoch, StandaloneVideoFrame owner) {
    final now = frame();
    return !_disposed &&
        wantsVideo &&
        epoch == _epoch &&
        now?.trackId == owner.trackId &&
        now?.generation == owner.generation;
  }

  Future<void> showVideo() async {
    final owner = frame();
    if (owner == null || _disposed) return;
    if (owner.loading) {
      wantsVideo = true;
      preparing = true;
      _publish();
      return;
    }
    final epoch = ++_epoch;
    wantsVideo = true;
    preparing = true;
    enabled = false;
    error = null;
    unavailable = false;
    _owner = owner;
    _timer?.cancel();
    await _releaseDecoder();
    if (!_current(epoch, owner)) return;
    _publish();
    try {
      final id = Uri.parse(owner.trackId).queryParameters['v'] ?? Uri.parse(owner.trackId).pathSegments.last;
      final versions = await (versionsLoader?.call(id) ?? const YoutubeVideoService().versions(id)).timeout(
        const Duration(seconds: 20),
      );
      if (!_current(epoch, owner)) return;
      _versions = versions;
      if (versions.videoId == null) {
        unavailable = true;
        throw StateError('No video version is available for this song.');
      }
      final source =
          await (streamLoader?.call(versions.videoId!) ??
                  const YoutubeVideoService().resolve(versions.videoId!, isCurrent: () => _current(epoch, owner)))
              .timeout(const Duration(seconds: 25));
      if (!_current(epoch, owner)) return;
      final player = _player = _createPlayer();
      controller = _createController(player);
      _errors = player.stream.error.listen((message) {
        if (message.trim().isNotEmpty && enabled) {
          error = 'Video playback failed. Song playback is still available.';
          unawaited(showSong());
        }
      });
      await player.setVolume(0);
      if (player.platform case final mk.NativePlayer native) {
        await native.setProperty('aid', 'no');
        await native.setProperty('ao', 'null');
      }
      _publish();
      if (!_current(epoch, owner)) return;
      await player
          .open(mk.Media(source.videoUri.toString(), httpHeaders: source.videoHeaders), play: false)
          .timeout(const Duration(seconds: 12));
      if (!_current(epoch, owner)) return;
      if (!await waitForMediaSourceReady(player, () => _current(epoch, owner))) return;
      final position = await activateAudio(source, versions, owner, () => _current(epoch, owner));
      if (position == null || !_current(epoch, owner)) return;
      final fresh = frame()!;
      await player.seek(fresh.position);
      _lastVideoSeek = DateTime.now();
      if (!_current(epoch, owner)) return;
      await player.setRate(fresh.rate);
      _seekRevision = fresh.seekRevision;
      _wasBuffering = false;
      enabled = true;
      preparing = false;
      _publish();
      await _sync(epoch);
      _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => unawaited(_sync(epoch)));
    } catch (_) {
      if (!_current(epoch, owner)) return;
      error = unavailable
          ? 'No video version is available for this song.'
          : 'Could not load video. You can keep listening in Song mode.';
      await showSong();
    }
  }

  Future<void> _sync(int epoch) async {
    final owner = _owner, player = _player;
    if (_syncing || !enabled || owner == null || player == null || !_current(epoch, owner)) return;
    _syncing = true;
    try {
      final current = frame()!;
      if (player.state.rate != current.rate) await player.setRate(current.rate);
      if (!_current(epoch, owner)) return;
      final recovered = _wasBuffering && !player.state.buffering;
      _wasBuffering = player.state.buffering;
      // No periodic clock-drift seeks. Reposition only on explicit transport
      // commands or once after the visual decoder recovers from buffering.
      // A seek can itself trigger buffering. Never turn that recovery into
      // another seek loop; ordinary decoder latency needs no correction.
      final needsRecoveryAlignment =
          recovered &&
          DateTime.now().difference(_lastVideoSeek) >= const Duration(seconds: 3) &&
          (player.state.position - current.position).abs() > const Duration(milliseconds: 750);
      if (_seekRevision != current.seekRevision || needsRecoveryAlignment) {
        await player.seek(current.position);
        _lastVideoSeek = DateTime.now();
        _seekRevision = current.seekRevision;
      }
      if (!_current(epoch, owner)) return;
      final playing = current.playing && !current.loading;
      if (player.state.playing != playing) {
        if (playing) {
          await player.play();
        } else {
          await player.pause();
        }
      }
    } catch (_) {
      if (_current(epoch, owner)) {
        error = 'Video playback failed. Song playback is still available.';
        unawaited(showSong());
      }
    } finally {
      _syncing = false;
    }
  }

  Future<void> showSong() async {
    final epoch = ++_epoch;
    wantsVideo = false;
    enabled = false;
    preparing = false;
    _timer?.cancel();
    final owner = _owner;
    _publish();
    await _releaseDecoder();
    if (owner != null) {
      try {
        await restoreAudio(owner, _versions, () => !_disposed && epoch == _epoch && !wantsVideo);
      } catch (_) {
        if (!_disposed) {
          error = 'Could not switch to Song. Try playing this track again.';
          _publish();
        }
      }
    }
  }

  Future<void> _releaseDecoder() async {
    final player = _player;
    _player = null;
    controller = null;
    final errors = _errors;
    _errors = null;
    await errors?.cancel();
    await player?.dispose();
  }

  /// Invalidate old frames and requests immediately when the handler selects a
  /// different source. A visible Video selection can continue on the new song.
  void sourceChanged() {
    ++_epoch;
    _timer?.cancel();
    enabled = false;
    preparing = wantsVideo;
    error = null;
    unavailable = false;
    _owner = null;
    _versions = null;
    unawaited(_releaseDecoder());
    _publish();
  }

  void sourceReady() {
    if (wantsVideo && !_disposed) unawaited(showVideo());
  }

  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    wantsVideo = false;
    ++_epoch;
    _timer?.cancel();
    await _releaseDecoder();
    super.dispose();
  }
}
