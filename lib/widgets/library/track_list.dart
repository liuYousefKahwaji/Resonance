// lib/widgets/library/track_list.dart
// Scroll smoothness improvements:
//  1. Platform-tuned cache extent — desktop prebuilds farther ahead while
//     Android avoids starting too many metadata/artwork reads at once.
//  2. addRepaintBoundaries: true (default, but explicit) — each item gets
//     its own layer so playing-state updates don't repaint the whole list.
//  3. addAutomaticKeepAlives: false — we don't need tiles to keep state
//     when off-screen; metadata is cached in MetadataCacheService and reloads
//     from the in-memory map instantly, so re-init is effectively free.

import 'dart:io';
import 'dart:async';
import 'package:audio_metadata_extractor/audio_metadata_extractor.dart';
import 'package:path/path.dart' as p;
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:resonance/app/resonance_motion.dart';
import 'package:resonance/app/theme.dart';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:resonance/widgets/library/track_tile.dart';
import 'package:resonance/services/scroll_effects_preferences.dart';

class TrackList extends StatefulWidget {
  static const double itemExtent = 70;
  static const double topPadding = 4;

  final List<String> tracks;
  final int playlistNumber;
  final Function(int index, String path) onTrackDeleted;
  final Function(String path) onTrackDeletedEverywhere;
  final Function(int oldIndex, int newIndex) onReorder;
  final ScrollController controller;
  final int? pulsingTrackIndex;
  final int pulse;
  final int searchRequest;
  final int artworkRevision;
  final GlobalKey Function(int playlistNumber, int index) itemKeyForIndex;
  final Set<int> selectedIndices;
  final ValueChanged<int>? onSelectionToggle;

  const TrackList({
    super.key,
    required this.tracks,
    required this.playlistNumber,
    required this.onTrackDeleted,
    required this.onTrackDeletedEverywhere,
    required this.onReorder,
    required this.controller,
    required this.pulsingTrackIndex,
    required this.pulse,
    required this.artworkRevision,
    required this.itemKeyForIndex,
    this.searchRequest = 0,
    this.selectedIndices = const <int>{},
    this.onSelectionToggle,
  });

  @override
  State<TrackList> createState() => _TrackListState();
}

class _TrackListState extends State<TrackList> {
  bool _isScrolling = false;
  final _search = TextEditingController();
  final _focus = FocusNode();
  final Map<String, CachedTrackMetadata> _metadata = {};
  bool _searchOpen = false;
  int _generation = 0;
  bool _indexing = false;

  @override
  void dispose() {
    _generation++;
    _search.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TrackList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchRequest != widget.searchRequest) {
      _searchOpen = true;
      _focus.requestFocus();
    }
    if (oldWidget.pulse != widget.pulse) {
      _search.clear();
      _focus.unfocus();
    }
    if (oldWidget.tracks != widget.tracks || oldWidget.artworkRevision != widget.artworkRevision) {
      if (oldWidget.artworkRevision != widget.artworkRevision) _metadata.clear();
      if (_search.text.isNotEmpty) unawaited(_indexMetadata());
    }
  }

  Future<void> _indexMetadata() async {
    final generation = ++_generation;
    _indexing = true;
    for (final path in List<String>.of(widget.tracks)) {
      if (!mounted || generation != _generation) return;
      if (_metadata.containsKey(path)) continue;
      CachedTrackMetadata? metadata;
      try {
        metadata = await MetadataCacheService.get(path);
        if (metadata == null && !path.startsWith('http')) {
          final tags = await AudioMetadata.extract(File(path));
          metadata = CachedTrackMetadata(
            title: tags?.trackName?.trim().isNotEmpty == true ? tags!.trackName! : p.basenameWithoutExtension(path),
            artist: tags?.firstArtists ?? 'Unknown Artist',
          );
          await MetadataCacheService.set(path, metadata.title, metadata.artist);
        }
      } catch (_) {}
      if (!mounted || generation != _generation) return;
      _metadata[path] = metadata ?? CachedTrackMetadata(title: p.basenameWithoutExtension(path), artist: '');
    }
    if (mounted && generation == _generation) setState(() => _indexing = false);
  }

  Widget _searchBar(int count) {
    final expanded = !Platform.isAndroid || _searchOpen;
    return AnimatedSize(
      duration: resonanceDuration(context, const Duration(milliseconds: 220)),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: !expanded
          ? const SizedBox.shrink()
          : Padding(
              padding: EdgeInsets.fromLTRB(12, Platform.isWindows ? 14 : 4, 12, 8),
              child: SizedBox(
                height: Platform.isWindows ? 48 : 44,
                child: TextField(
                  controller: _search,
                  focusNode: _focus,
                  onChanged: (_) {
                    setState(() {});
                    unawaited(_indexMetadata());
                  },
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _focus.unfocus(),
                  textAlignVertical: TextAlignVertical.center,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Search this playlist',
                    prefixIcon: const Icon(Icons.search_rounded, size: 18),
                    prefixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 36),
                    suffixIconConstraints: const BoxConstraints(minHeight: 36),
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(useWindowsNativeControls(context) ? 4 : 12),
                      borderSide: BorderSide.none,
                    ),
                    suffixIcon: Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_search.text.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6),
                              child: Text(_indexing ? '…' : '$count', style: Theme.of(context).textTheme.labelSmall),
                            ),
                          if (_search.text.isNotEmpty || Platform.isAndroid)
                            IconButton(
                              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
                              padding: EdgeInsets.zero,
                              tooltip: Platform.isAndroid ? 'Close playlist search' : 'Clear search',
                              icon: const Icon(Icons.close_rounded, size: 18),
                              onPressed: () => setState(() {
                                _search.clear();
                                if (Platform.isAndroid) {
                                  _searchOpen = false;
                                  _focus.unfocus();
                                }
                              }),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  bool _handleScroll(ScrollNotification notification) {
    final scrolling = notification is ScrollStartNotification || notification is ScrollUpdateNotification;
    final stopped = notification is ScrollEndNotification;
    if (scrolling && !_isScrolling) {
      setState(() => _isScrolling = true);
    } else if (stopped && _isScrolling) {
      setState(() => _isScrolling = false);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tracks.isEmpty) {
      return const _EmptyState();
    }

    final query = _search.text.trim();
    final indices = <int>[for (var i = 0; i < widget.tracks.length; i++) i];
    if (query.isNotEmpty) {
      int rank(int i) {
        final path = widget.tracks[i];
        final metadata = _metadata[path];
        return trackSearchRank(query, metadata?.title ?? p.basenameWithoutExtension(path), metadata?.artist ?? '');
      }

      indices.removeWhere((i) => rank(i) < 0);
      indices.sort((a, b) {
        final comparison = rank(a).compareTo(rank(b));
        return comparison == 0 ? a.compareTo(b) : comparison;
      });
    }
    final list = ReorderableListView.builder(
      scrollController: widget.controller,
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.only(top: TrackList.topPadding, bottom: 8),
      // Prebuilding too many artwork-heavy rows causes a burst of file and
      // image work on lower-end phones. Desktop keeps the larger cache.
      cacheExtent: Platform.isAndroid ? 160 : 400,
      itemExtent: TrackList.itemExtent,
      itemCount: indices.length,
      itemBuilder: (context, visibleIndex) {
        final index = indices[visibleIndex];
        final trackPath = widget.tracks[index];
        return TrackTile(
          key: widget.itemKeyForIndex(widget.playlistNumber, index),
          trackPath: trackPath,
          playlistNumber: widget.playlistNumber,
          index: index,
          allowReorder: query.isEmpty,
          onDelete: () => widget.onTrackDeleted(index, trackPath),
          onDeleteEverywhere: () => widget.onTrackDeletedEverywhere(trackPath),
          pulse: widget.pulsingTrackIndex == index ? widget.pulse : 0,
          artworkRevision: widget.artworkRevision,
          selected: widget.selectedIndices.contains(index),
          selectionMode: widget.selectedIndices.isNotEmpty,
          onSelectionToggle: widget.onSelectionToggle == null ? null : () => widget.onSelectionToggle!(index),
        );
      },
      onReorder: query.isEmpty ? widget.onReorder : (_, __) {},
      proxyDecorator: (child, index, animation) {
        return AnimatedBuilder(
          animation: animation,
          builder: (context, child) {
            final primary = Theme.of(context).colorScheme.primary;
            final elevation = (animation.value * 12).clamp(0.0, 12.0);
            return Material(
              elevation: elevation,
              borderRadius: BorderRadius.circular(12),
              color: Colors.transparent,
              shadowColor: primary.withValues(alpha: 0.25),
              child: child,
            );
          },
          child: child,
        );
      },
    );
    return Column(
      children: [
        _searchBar(indices.length),
        Expanded(
          child: indices.isEmpty
              ? Center(
                  child: Text(
                    _indexing ? 'Searching tracks…' : 'No matching tracks',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                )
              : NotificationListener<ScrollNotification>(
                  onNotification: _handleScroll,
                  child: ValueListenableBuilder<bool>(
                    valueListenable: ScrollEffectsPreferences.instance.motionBlurEnabled,
                    child: list,
                    builder: (context, motionBlurEnabled, child) =>
                        TrackListMotionBlurSurface(enabled: motionBlurEnabled && _isScrolling, child: child!),
                  ),
                ),
        ),
      ],
    );
  }
}

/// Keeps the list under a stable render-object wrapper while blur is toggled.
/// Replacing the list with a newly wrapped subtree at scroll end can detach its
/// Scrollable state and make the controller jump back to the top.
@visibleForTesting
class TrackListMotionBlurSurface extends StatelessWidget {
  final bool enabled;
  final Widget child;

  const TrackListMotionBlurSurface({super.key, required this.enabled, required this.child});

  @override
  Widget build(BuildContext context) => ImageFiltered(
    enabled: enabled,
    // This full-list filter is intentionally opt-in. It is disabled by
    // default because low-end Android GPUs often pay more for the blur than
    // the visual effect is worth.
    imageFilter: ui.ImageFilter.blur(sigmaX: 0.22, sigmaY: 0.36),
    child: child,
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: isDark ? primary.withValues(alpha: 0.08) : primary.withValues(alpha: 0.06),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.library_music_rounded, size: 32, color: primary.withValues(alpha: 0.5)),
          ),
          const SizedBox(height: 16),
          Text(
            'Your library is empty',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Import tracks or search YouTube',
            style: TextStyle(fontSize: 12, color: isDark ? const Color(0xFF475569) : const Color(0xFF94A3B8)),
          ),
        ],
      ),
    );
  }
}

/// Lower scores rank first; title matches take priority over artist matches.
int trackSearchRank(String query, String title, String artist) {
  String normalize(String text) => text.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
  final needle = normalize(query);
  final name = normalize(title);
  final author = normalize(artist);
  if (needle.isEmpty || name == needle) return 0;
  if (name.startsWith(needle)) return 1;
  if (name.contains(needle)) return 2;
  if (author.contains(needle)) return 3;
  if (needle.split(' ').every((word) => '$name $author'.contains(word))) return 4;
  return -1;
}
