import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/models/listening_history_entry.dart';
import 'package:resonance/models/track_source_record.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/screens/player/standalone_player_screen.dart';
import 'package:resonance/screens/settings/youtube_access_screen.dart';
import 'package:resonance/services/download/download_queue_controller.dart';
import 'package:resonance/services/listening_history_repository.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'package:resonance/services/youtube/youtube_music_history_service.dart';
import 'package:resonance/services/youtube_stats_service.dart';
import 'package:resonance/widgets/youtube/youtube_failure_dialog.dart';
import 'package:resonance/widgets/common/progressive_network_artwork.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.playlistNumber, required this.playlistName});

  final int playlistNumber;
  final String playlistName;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _search = TextEditingController();
  final _youtubeHistory = const YoutubeMusicHistoryService();
  final _stats = const YoutubeStatsService();
  List<YoutubeTrack> _youtubeTracks = const [];
  Object? _youtubeError;
  bool _loadingYoutube = true;
  bool _searchOpen = false;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this)..addListener(_tabChanged);
    _search.addListener(_refresh);
    ListeningHistoryRepository.instance.addListener(_localHistoryChanged);
    unawaited(_loadYoutube());
  }

  @override
  void dispose() {
    _loadGeneration++;
    _tabs
      ..removeListener(_tabChanged)
      ..dispose();
    _search
      ..removeListener(_refresh)
      ..dispose();
    ListeningHistoryRepository.instance.removeListener(_localHistoryChanged);
    super.dispose();
  }

  void _refresh() => setState(() {});

  void _localHistoryChanged() {
    if (mounted) setState(() {});
  }

  void _tabChanged() {
    if (!_tabs.indexIsChanging) setState(() {});
  }

  Future<void> _loadYoutube({bool refresh = false}) async {
    final generation = ++_loadGeneration;
    setState(() {
      _loadingYoutube = true;
      _youtubeError = null;
    });
    try {
      final tracks = await _youtubeHistory.fetch(limit: 100, forceRefresh: refresh);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _youtubeTracks = tracks;
        _loadingYoutube = false;
      });
      // Populate what is initially visible first, then continue quietly.
      for (final index in [
        ...List.generate(tracks.length.clamp(0, 12), (index) => index),
        ...List.generate(tracks.length > 12 ? tracks.length - 12 : 0, (index) => index + 12),
      ]) {
        if (!mounted || generation != _loadGeneration) return;
        final hydrated = await _stats.hydrate(tracks[index]);
        if (!mounted || generation != _loadGeneration) return;
        if (hydrated.viewCount != null || hydrated.likeCount != null) {
          setState(() => _youtubeTracks = [..._youtubeTracks]..[index] = hydrated);
        }
      }
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _youtubeError = error;
        _loadingYoutube = false;
      });
    }
  }

  List<YoutubeTrack> get _visibleYoutube {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return _youtubeTracks;
    return _youtubeTracks
        .where((track) => track.title.toLowerCase().contains(query) || track.artist.toLowerCase().contains(query))
        .toList(growable: false);
  }

  List<ListeningHistoryEntry> get _visibleLocal {
    final query = _search.text.trim().toLowerCase();
    final entries = ListeningHistoryRepository.instance.entries;
    if (query.isEmpty) return entries;
    return entries
        .where((entry) => entry.title.toLowerCase().contains(query) || entry.artist.toLowerCase().contains(query))
        .toList(growable: false);
  }

  Future<void> _playYoutube(YoutubeTrack selected) async {
    final tracks = _visibleYoutube;
    final playback = context.read<PlayerHandler>().playStandaloneStream(
      url: selected.url,
      title: selected.title,
      artist: selected.artist,
      thumbnailUrl: selected.thumbnailUrl,
      queueItems: [
        for (final track in tracks)
          StandaloneStreamQueueItem(
            url: track.url,
            title: track.title,
            artist: track.artist,
            thumbnailUrl: track.thumbnailUrl,
          ),
      ],
      queueIndex: tracks.indexWhere((track) => track.url == selected.url),
    );
    if (!mounted) {
      await playback;
      return;
    }
    final route = MaterialPageRoute<void>(builder: (_) => const StandalonePlayerScreen());
    final page = Navigator.push<void>(context, route);
    try {
      await playback;
    } catch (error) {
      if (mounted && route.isCurrent) Navigator.pop(context);
      await page;
      if (mounted) {
        await showYoutubeFailure(context, error, sourceUrl: selected.url, actionLabel: 'Could not play stream');
      }
      return;
    }
    await page;
  }

  Future<void> _stream(YoutubeTrack track) async {
    try {
      await MetadataCacheService.set(track.url, track.title, track.artist, artworkUrl: track.thumbnailUrl);
      final id = track.videoId;
      if (id != null) {
        await const TrackSourceRepository().saveSource(
          localPath: track.url,
          youtubeVideoId: id,
          method: TrackSourceMethod.manuallySelected,
          lastVerifiedAt: DateTime.now().toUtc(),
        );
      }
      final added = await FileService().appendTrack(widget.playlistNumber, track.url);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              added ? '${track.title} added to ${widget.playlistName}' : 'Already in ${widget.playlistName}',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) await showYoutubeFailure(context, error, sourceUrl: track.url, actionLabel: 'Could not add stream');
    }
  }

  Future<void> _download(YoutubeTrack track) async {
    final queue = DownloadQueueController.instance;
    if (queue.pendingEntryFor(track.url, widget.playlistNumber) != null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${track.title} queued')));
    unawaited(
      queue.enqueue(track, widget.playlistNumber).catchError((error) async {
        if (mounted) await showYoutubeFailure(context, error, sourceUrl: track.url, actionLabel: 'Download failed');
        return null;
      }),
    );
  }

  Future<void> _playLocal(ListeningHistoryEntry entry) async {
    if (!await File(entry.trackPath).exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('This audio file is unavailable.')));
      }
      return;
    }
    await context.read<PlayerHandler>().loadTrack(entry.trackPath, entry.title, entry.artist);
  }

  Future<void> _clearLocal() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Resonance history?'),
        content: const Text('This removes listening history only. Audio files and playlists are unaffected.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (confirmed == true) await ListeningHistoryRepository.instance.clear();
  }

  @override
  Widget build(BuildContext context) {
    final showSearch = !Platform.isAndroid || _searchOpen;
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          if (Platform.isAndroid)
            IconButton(
              onPressed: () => setState(() => _searchOpen = !_searchOpen),
              tooltip: 'Search history',
              icon: Icon(_searchOpen ? Icons.close_rounded : Icons.search_rounded),
            ),
          if (_tabs.index == 0)
            IconButton(
              onPressed: _loadingYoutube ? null : () => _loadYoutube(refresh: true),
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh_rounded),
            ),
          if (_tabs.index == 1 && ListeningHistoryRepository.instance.entries.isNotEmpty)
            IconButton(
              onPressed: _clearLocal,
              tooltip: 'Clear Resonance history',
              icon: const Icon(Icons.delete_sweep_rounded),
            ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'YouTube Music'),
            Tab(text: 'Resonance'),
          ],
        ),
      ),
      body: ListenableBuilder(
        listenable: ListeningHistoryRepository.instance,
        builder: (context, _) => Column(
          children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              child: showSearch
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: TextField(
                        controller: _search,
                        autofocus: Platform.isAndroid,
                        decoration: InputDecoration(
                          hintText: 'Search title or artist',
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: _search.text.isEmpty
                              ? null
                              : IconButton(onPressed: _search.clear, icon: const Icon(Icons.close_rounded)),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            Expanded(
              child: TabBarView(controller: _tabs, children: [_buildYoutube(), _buildLocal()]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildYoutube() {
    if (_loadingYoutube) return const Center(child: CircularProgressIndicator());
    if (_youtubeError != null) {
      return _HistoryMessage(
        icon: Icons.cloud_off_rounded,
        title: 'Could not load YouTube Music history',
        message: 'Reconnect YouTube access if your session expired.',
        primaryLabel: 'Retry',
        onPrimary: () => _loadYoutube(refresh: true),
        secondaryLabel: 'YouTube access',
        onSecondary: () =>
            Navigator.push<void>(context, MaterialPageRoute(builder: (_) => const YoutubeAccessScreen())),
      );
    }
    final tracks = _visibleYoutube;
    if (tracks.isEmpty) {
      return _HistoryMessage(
        icon: Icons.history_rounded,
        title: _search.text.isEmpty ? 'No YouTube Music history' : 'No matching tracks',
        message: _search.text.isEmpty
            ? 'Tracks you play on YouTube Music will appear here.'
            : 'Try a different title or artist.',
      );
    }
    return RefreshIndicator(
      onRefresh: () => _loadYoutube(refresh: true),
      child: ListView.builder(
        padding: const EdgeInsets.only(top: 4, bottom: 20),
        itemCount: tracks.length,
        itemBuilder: (context, index) {
          final track = tracks[index];
          return _YoutubeHistoryTile(
            track: track,
            onPlay: () => _playYoutube(track),
            onStream: () => _stream(track),
            onDownload: () => _download(track),
          );
        },
      ),
    );
  }

  Widget _buildLocal() {
    final entries = _visibleLocal;
    if (entries.isEmpty) {
      return _HistoryMessage(
        icon: Icons.library_music_rounded,
        title: _search.text.isEmpty ? 'No Resonance history yet' : 'No matching tracks',
        message: _search.text.isEmpty
            ? 'Local tracks will appear after three seconds of playback.'
            : 'Try a different title or artist.',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(top: 4, bottom: 20),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final exists = File(entry.trackPath).existsSync();
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: _HistoryArtwork(url: entry.artworkUri, local: true),
          title: Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${entry.artist} · ${_relativeTime(entry.playedAt)}${exists ? '' : ' · Missing file'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          enabled: exists,
          onTap: () => _playLocal(entry),
          trailing: PopupMenuButton<String>(
            onSelected: (_) => ListeningHistoryRepository.instance.remove(entry.trackPath),
            itemBuilder: (_) => const [PopupMenuItem(value: 'remove', child: Text('Remove from history'))],
          ),
        );
      },
    );
  }

  String _relativeTime(DateTime value) {
    final local = value.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(local.year, local.month, local.day);
    final time = TimeOfDay.fromDateTime(local).format(context);
    if (day == today) return 'Today, $time';
    if (day == today.subtract(const Duration(days: 1))) return 'Yesterday, $time';
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }
}

class _YoutubeHistoryTile extends StatelessWidget {
  const _YoutubeHistoryTile({
    required this.track,
    required this.onPlay,
    required this.onStream,
    required this.onDownload,
  });

  final YoutubeTrack track;
  final VoidCallback onPlay;
  final VoidCallback onStream;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
    leading: _HistoryArtwork(url: track.thumbnailUrl),
    title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 3),
        Text(
          '${track.viewCount == null ? '—' : track.formattedViewCount} views  ·  ${track.likeCount == null ? '—' : track.formattedLikeCount} likes',
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ],
    ),
    onTap: onPlay,
    trailing: PopupMenuButton<String>(
      onSelected: (value) => value == 'stream' ? onStream() : onDownload(),
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'stream', child: Text('Add stream to playlist')),
        PopupMenuItem(value: 'download', child: Text('Download')),
      ],
    ),
  );
}

class _HistoryArtwork extends StatelessWidget {
  const _HistoryArtwork({this.url, this.local = false});
  final String? url;
  final bool local;

  @override
  Widget build(BuildContext context) {
    final value = url?.trim() ?? '';
    final placeholder = Icon(local ? Icons.music_note_rounded : Icons.history_rounded);
    Widget child = placeholder;
    if (value.startsWith('http://') || value.startsWith('https://')) {
      child = ProgressiveNetworkArtwork(
        url: value,
        fit: BoxFit.cover,
        lowCacheSize: 144,
        highCacheSize: 512,
        fallback: placeholder,
      );
    } else if (value.startsWith('file:')) {
      final file = File.fromUri(Uri.parse(value));
      if (file.existsSync()) child = Image.file(file, fit: BoxFit.cover);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 48,
        height: 48,
        child: ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest, child: child),
      ),
    );
  }
}

class _HistoryMessage extends StatelessWidget {
  const _HistoryMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 42, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 14),
          Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text(message, style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
          if (primaryLabel != null) ...[
            const SizedBox(height: 16),
            FilledButton(onPressed: onPrimary, child: Text(primaryLabel!)),
          ],
          if (secondaryLabel != null) TextButton(onPressed: onSecondary, child: Text(secondaryLabel!)),
        ],
      ),
    ),
  );
}
