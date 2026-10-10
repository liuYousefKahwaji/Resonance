import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:metadata_god/metadata_god.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:resonance/app/theme.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/widgets/player/playback_range_dialog.dart';
import 'package:resonance/widgets/player/playback_range_indicator.dart';
import 'package:resonance/models/smart_playlist.dart';
import 'package:resonance/screens/player/standalone_player_screen.dart';
import 'package:resonance/services/library_catalog.dart';
import 'package:resonance/services/listening_statistics.dart';
import 'package:resonance/services/smart_playlist_repository.dart';

class LibraryBrowserScreen extends StatefulWidget {
  const LibraryBrowserScreen({super.key, this.catalog, this.smart});
  final LibraryCatalog? catalog;
  final SmartPlaylistRepository? smart;
  @override
  State<LibraryBrowserScreen> createState() => _LibraryBrowserScreenState();
}

class _LibraryBrowserScreenState extends State<LibraryBrowserScreen> {
  late final catalog = widget.catalog ?? LibraryCatalog();
  late final smart = widget.smart ?? SmartPlaylistRepository();
  bool importing = false;
  @override
  void initState() {
    super.initState();
    if (widget.catalog == null) catalog.start();
    if (widget.smart == null) unawaited(smart.load());
  }

  @override
  void dispose() {
    if (widget.catalog == null) catalog.dispose();
    if (widget.smart == null) smart.dispose();
    super.dispose();
  }

  Future<void> _importFolder() async {
    final directory = await FilePicker.getDirectoryPath();
    if (directory == null || !mounted) return;
    setState(() => importing = true);
    try {
      final files = FileService();
      final number = await files.getActivePlaylistNumber();
      final existing = await files.readPlaylistTracks(number);
      final added = <String>[];
      const extensions = {'.mp3', '.flac', '.wav', '.m4a', '.aac', '.ogg', '.opus', '.webm'};
      await for (final entry in Directory(directory).list(recursive: true, followLinks: false)) {
        if (entry is File &&
            extensions.contains(p.extension(entry.path).toLowerCase()) &&
            !existing.any((path) => files.sameTrackPath(path, entry.path))) {
          added.add(entry.path);
        }
      }
      added.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      await files.replacePlaylistTracks(number, [...existing, ...added]);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.tr('Added {0} tracks', [added.length]))));
      }
    } catch (error) {
      if (mounted) showLibraryError(context, error);
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  Future<void> _edit([SmartPlaylist? current]) async {
    final result = await showDialog<SmartPlaylist>(
      context: context,
      builder: (_) => SmartPlaylistEditor(catalog: catalog, current: current),
    );
    if (result != null) await smart.save(result);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(context.tr('Browse library')),
      actions: [
        if (Platform.isWindows)
          IconButton(
            onPressed: importing ? null : _importFolder,
            tooltip: context.tr('Add folder'),
            icon: importing
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.create_new_folder_outlined),
          ),
        IconButton(onPressed: () => catalog.refresh(), tooltip: context.tr('Refresh'), icon: const Icon(Icons.refresh)),
      ],
    ),
    body: AnimatedBuilder(
      animation: Listenable.merge([catalog, smart, ListeningStatistics.instance]),
      builder: (context, _) {
        final albums = <String, List<LibraryTrack>>{};
        for (final track in catalog.tracks.where((track) => !track.stream)) {
          albums.putIfAbsent(track.albumKey, () => []).add(track);
        }
        final groups = albums.values.toList()
          ..sort((a, b) => _albumName(a.first).toLowerCase().compareTo(_albumName(b.first).toLowerCase()));
        for (final group in groups) {
          group.sort((a, b) {
            final order = (a.trackNumber ?? 9999).compareTo(b.trackNumber ?? 9999);
            return order == 0 ? a.title.compareTo(b.title) : order;
          });
        }
        return CustomScrollView(
          slivers: [
            if (catalog.loading) const SliverToBoxAdapter(child: LinearProgressIndicator()),
            if (catalog.error != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(context.tr('Could not complete this action: {0}', ['${catalog.error}'])),
                ),
              ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 12, 8),
                child: Row(
                  children: [
                    Expanded(child: Text(context.tr('Smart playlists'), style: Theme.of(context).textTheme.titleLarge)),
                    TextButton.icon(onPressed: _edit, icon: const Icon(Icons.add), label: Text(context.tr('Create'))),
                  ],
                ),
              ),
            ),
            if (smart.playlists.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  child: Text(context.tr('Save rules to find songs already in your library.')),
                ),
              ),
            SliverList.builder(
              itemCount: smart.playlists.length,
              itemBuilder: (context, i) {
                final playlist = smart.playlists[i];
                final count = playlist.evaluate(catalog.tracks, ListeningStatistics.instance.aggregate()).length;
                return ListTile(
                  leading: const Icon(Icons.auto_awesome_outlined),
                  title: Text(playlist.name),
                  subtitle: Text(context.tr('{0} tracks · Smart playlist', [count])),
                  onTap: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => LibraryTracksScreen(
                        title: playlist.name,
                        catalog: catalog,
                        smart: smart,
                        smartId: playlist.id,
                      ),
                    ),
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) {
                      if (action == 'edit') {
                        unawaited(_edit(playlist));
                      } else {
                        unawaited(smart.remove(playlist.id));
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(value: 'edit', child: Text(context.tr('Edit rules'))),
                      PopupMenuItem(value: 'delete', child: Text(context.tr('Delete'))),
                    ],
                  ),
                );
              },
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(context.tr('Albums'), style: Theme.of(context).textTheme.titleLarge),
              ),
            ),
            if (groups.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(context.tr('Add local tracks to browse your albums here.')),
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 230,
                  mainAxisExtent: 270,
                  crossAxisSpacing: 18,
                  mainAxisSpacing: 18,
                ),
                itemCount: groups.length,
                itemBuilder: (context, i) {
                  final group = groups[i];
                  return InkWell(
                    borderRadius: resonanceBorderRadius(context, 12),
                    onTap: () => Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => LibraryTracksScreen(
                          title: _albumName(group.first),
                          catalog: catalog,
                          albumKey: group.first.albumKey,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: AspectRatio(aspectRatio: 1, child: LibraryArtwork(track: group.first)),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _albumName(group.first),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        Text(
                          '${group.first.albumArtist.isEmpty ? group.first.artist : group.first.albumArtist} · ${group.length}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 30)),
          ],
        );
      },
    ),
  );
  String _albumName(LibraryTrack track) => track.album.isEmpty ? p.basename(p.dirname(track.path)) : track.album;
}

class LibraryArtwork extends StatefulWidget {
  const LibraryArtwork({super.key, required this.track});
  final LibraryTrack track;
  @override
  State<LibraryArtwork> createState() => _LibraryArtworkState();
}

class _LibraryArtworkState extends State<LibraryArtwork> {
  Future<Uint8List?>? bytes;
  @override
  void initState() {
    super.initState();
    _read();
  }

  @override
  void didUpdateWidget(LibraryArtwork old) {
    super.didUpdateWidget(old);
    if (old.track.path != widget.track.path) _read();
  }

  void _read() {
    bytes = widget.track.stream ? null : _localArtwork();
  }

  Future<Uint8List?> _localArtwork() async {
    try {
      if (!await File(widget.track.path).exists()) return null;
      return (await MetadataGod.readMetadata(file: widget.track.path)).picture?.data;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(child: Icon(Icons.album_outlined, size: 36)),
    );
    return ClipRRect(
      borderRadius: resonanceBorderRadius(context, 12),
      child: widget.track.artwork != null
          ? Image.network(widget.track.artwork!, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback)
          : FutureBuilder<Uint8List?>(
              future: bytes,
              builder: (context, snapshot) => snapshot.data == null
                  ? fallback
                  : Image.memory(snapshot.data!, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback),
            ),
    );
  }
}

class LibraryTracksScreen extends StatefulWidget {
  const LibraryTracksScreen({
    super.key,
    required this.title,
    required this.catalog,
    this.smart,
    this.smartId,
    this.albumKey,
  });
  final String title;
  final LibraryCatalog catalog;
  final SmartPlaylistRepository? smart;
  final String? smartId, albumKey;
  @override
  State<LibraryTracksScreen> createState() => _LibraryTracksScreenState();
}

class _LibraryTracksScreenState extends State<LibraryTracksScreen> {
  int playGeneration = 0;
  SmartPlaylist? get rules => widget.smart?.playlists.where((item) => item.id == widget.smartId).firstOrNull;
  List<LibraryTrack> get tracks =>
      rules?.evaluate(widget.catalog.tracks, ListeningStatistics.instance.aggregate()) ??
      (widget.smartId != null
          ? []
          : (widget.catalog.tracks.where((track) => track.albumKey == widget.albumKey && !track.stream).toList()
              ..sort((a, b) {
                final order = (a.trackNumber ?? 9999).compareTo(b.trackNumber ?? 9999);
                return order == 0 ? a.title.compareTo(b.title) : order;
              })));
  Future<void> _play(List<LibraryTrack> list, int index) async {
    final generation = ++playGeneration;
    final track = list[index];
    final navigator = Navigator.of(context);
    try {
      final playback = context.read<PlayerHandler>().playStandaloneStream(
        url: track.path,
        title: track.title,
        artist: track.artist,
        thumbnailUrl: track.artwork,
        relatedQueue: false,
        queueIndex: index,
        queueItems: list
            .map(
              (item) => StandaloneStreamQueueItem(
                url: item.path,
                title: item.title,
                artist: item.artist,
                thumbnailUrl: item.artwork,
              ),
            )
            .toList(),
      );
      unawaited(navigator.push<void>(MaterialPageRoute(builder: (_) => const StandalonePlayerScreen())));
      await playback;
    } catch (error) {
      if (mounted && generation == playGeneration) showLibraryError(context, error);
    }
  }

  Future<void> _snapshot() async {
    try {
      final result = await FileService().createImportedPlaylist(
        widget.title,
        tracks.map((track) => track.path).toList(),
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.tr('Saved {0} as a regular playlist', [result.displayName]))));
      }
    } catch (error) {
      if (mounted) showLibraryError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.catalog,
      if (widget.smart != null) widget.smart!,
      ListeningStatistics.instance,
    ]),
    builder: (context, _) {
      final list = tracks;
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          actions: [
            if (widget.smartId != null)
              PopupMenuButton<String>(
                onSelected: (action) async {
                  if (action == 'snapshot') {
                    await _snapshot();
                  }
                  if (action == 'edit' && rules != null && mounted) {
                    final edited = await showDialog<SmartPlaylist>(
                      context: context,
                      builder: (_) => SmartPlaylistEditor(catalog: widget.catalog, current: rules),
                    );
                    if (edited != null) await widget.smart!.save(edited);
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(value: 'edit', child: Text(context.tr('Edit rules'))),
                  PopupMenuItem(value: 'snapshot', child: Text(context.tr('Save as regular playlist'))),
                ],
              ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.tr(widget.smartId == null ? '{0} tracks' : '{0} tracks · Smart playlist', [list.length]),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: context.tr('Play'),
                    onPressed: list.isEmpty ? null : () => _play(list, 0),
                    icon: const Icon(Icons.play_arrow_rounded),
                  ),
                  IconButton(
                    tooltip: context.tr('Shuffle'),
                    onPressed: list.isEmpty
                        ? null
                        : () {
                            final shuffled = [...list]..shuffle(Random());
                            _play(shuffled, 0);
                          },
                    icon: const Icon(Icons.shuffle),
                  ),
                ],
              ),
            ),
            if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(context.tr('No tracks match yet. Edit the rules or add tracks to your library.')),
              ),
            Expanded(
              child: ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, index) {
                  final track = list[index];
                  return ListTile(
                    leading: SizedBox(width: 46, height: 46, child: LibraryArtwork(track: track)),
                    title: Row(
                      children: [
                        Expanded(child: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                        if (!track.path.startsWith('http'))
                          PlaybackRangeIndicator(
                            handler: context.read<PlayerHandler>(),
                            path: track.path,
                            title: track.title,
                          ),
                      ],
                    ),
                    subtitle: Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => _play(list, index),
                    trailing: PopupMenuButton<String>(
                      onSelected: (action) async {
                        if (action == 'trim') {
                          await showPlaybackRangeDialog(
                            context,
                            context.read<PlayerHandler>(),
                            track.path,
                            track.title,
                          );
                        }
                        if (action == 'favorite') {
                          await FileService().setTracksFavorite([track.path], !track.favorite);
                        }
                        if (action == 'exclude' && rules != null) {
                          final json = rules!.toJson()..['exclusions'] = {...rules!.exclusions, track.id}.toList();
                          await widget.smart!.save(SmartPlaylist.fromJson(json));
                        }
                      },
                      itemBuilder: (context) => [
                        if (!track.path.startsWith('http'))
                          PopupMenuItem(value: 'trim', child: Text(context.tr('Trim playback'))),
                        PopupMenuItem(
                          value: 'favorite',
                          child: Text(context.tr(track.favorite ? 'Unfavorite' : 'Favorite')),
                        ),
                        if (widget.smartId != null)
                          PopupMenuItem(value: 'exclude', child: Text(context.tr('Exclude from this smart playlist'))),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      );
    },
  );
}

class SmartPlaylistEditor extends StatefulWidget {
  const SmartPlaylistEditor({super.key, required this.catalog, this.current});
  final LibraryCatalog catalog;
  final SmartPlaylist? current;
  @override
  State<SmartPlaylistEditor> createState() => _SmartPlaylistEditorState();
}

class _SmartPlaylistEditorState extends State<SmartPlaylistEditor> {
  late final TextEditingController name;
  late final TextEditingController limit;
  late List<SmartRule> rules;
  bool any = false, descending = false, includeNever = false;
  String sort = 'title';
  Map<int, String> playlists = {};
  static const labels = {
    SmartField.title: 'Title contains',
    SmartField.artist: 'Artist contains',
    SmartField.favorite: 'Favorited',
    SmartField.offline: 'Available offline',
    SmartField.stream: 'Stream',
    SmartField.addedDays: 'Added in the past days',
    SmartField.durationSeconds: 'Duration at least (seconds)',
    SmartField.lastPlayedDays: 'Not played in the past days',
    SmartField.playCount: 'At least this many plays',
    SmartField.playlist: 'In playlist',
  };
  @override
  void initState() {
    super.initState();
    final current = widget.current;
    name = TextEditingController(text: current?.name ?? '');
    limit = TextEditingController(text: current?.limit?.toString() ?? '');
    rules = [...?current?.rules];
    if (rules.isEmpty) rules = [const SmartRule(SmartField.favorite, '')];
    any = current?.matchAny ?? false;
    descending = current?.descending ?? false;
    sort = current?.sort ?? 'title';
    includeNever = current?.includeNeverPlayed ?? false;
    widget.catalog.files.getPlaylistNames().then((value) {
      if (mounted) setState(() => playlists = value);
    });
  }

  @override
  void dispose() {
    name.dispose();
    limit.dispose();
    super.dispose();
  }

  SmartPlaylist _value() => SmartPlaylist(
    id: widget.current?.id ?? '${DateTime.now().microsecondsSinceEpoch}',
    name: name.text.trim(),
    rules: rules,
    matchAny: any,
    descending: descending,
    sort: sort,
    limit: int.tryParse(limit.text),
    includeNeverPlayed: includeNever,
    exclusions: widget.current?.exclusions ?? {},
  );
  void _preset(String value) {
    setState(() {
      name.text = context.tr(value);
      any = false;
      includeNever = false;
      descending = false;
      sort = 'title';
      limit.clear();
      rules = switch (value) {
        'Recent additions' => [const SmartRule(SmartField.addedDays, '30')],
        'Offline favorites' => [const SmartRule(SmartField.favorite, ''), const SmartRule(SmartField.offline, '')],
        'Rediscover' => [const SmartRule(SmartField.lastPlayedDays, '30')],
        'Artist collection' => [const SmartRule(SmartField.artist, '')],
        'Long listens' => [const SmartRule(SmartField.durationSeconds, '1200')],
        _ => [const SmartRule(SmartField.playCount, '1')],
      };
      if (value == 'Recent additions') {
        sort = 'added';
        descending = true;
      }
      if (value == 'Most played') {
        sort = 'plays';
        descending = true;
        limit.text = '50';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final stats = ListeningStatistics.instance;
    final hasStats = stats.aggregate().isNotEmpty;
    final fields = SmartField.values
        .where(
          (field) =>
              hasStats || widget.current != null || field != SmartField.playCount && field != SmartField.lastPlayedDays,
        )
        .toList();
    final preview = _value().evaluate(widget.catalog.tracks, stats.aggregate());
    return AlertDialog(
      title: Text(context.tr('Smart playlist')),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String>(
                isExpanded: true,
                decoration: InputDecoration(labelText: context.tr('Start with a preset')),
                items: [
                  for (final label in [
                    'Recent additions',
                    'Offline favorites',
                    'Artist collection',
                    'Long listens',
                    if (hasStats) ...['Rediscover', 'Most played'],
                  ])
                    DropdownMenuItem(value: label, child: Text(context.tr(label))),
                ],
                onChanged: (value) {
                  if (value != null) _preset(value);
                },
              ),
              TextField(
                controller: name,
                maxLength: 25,
                decoration: InputDecoration(labelText: context.tr('Name')),
                onChanged: (_) => setState(() {}),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(context.tr(any ? 'Match any rule' : 'Match all rules')),
                value: any,
                onChanged: (value) => setState(() => any = value),
              ),
              for (var index = 0; index < rules.length; index++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<SmartField>(
                              initialValue: rules[index].field,
                              isExpanded: true,
                              items: fields
                                  .map(
                                    (field) => DropdownMenuItem(value: field, child: Text(context.tr(labels[field]!))),
                                  )
                                  .toList(),
                              onChanged: (field) =>
                                  setState(() => rules[index] = SmartRule(field!, '', negate: rules[index].negate)),
                            ),
                          ),
                          IconButton(
                            tooltip: context.tr('Remove rule'),
                            onPressed: rules.length == 1 ? null : () => setState(() => rules.removeAt(index)),
                            icon: const Icon(Icons.remove_circle_outline),
                          ),
                        ],
                      ),
                      if (rules[index].field == SmartField.playlist)
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          initialValue: playlists.containsKey(int.tryParse(rules[index].value))
                              ? rules[index].value
                              : null,
                          items: playlists.entries
                              .map(
                                (entry) => DropdownMenuItem(
                                  value: '${entry.key}',
                                  child: Text(entry.key == 0 ? context.tr('Favorites') : entry.value),
                                ),
                              )
                              .toList(),
                          onChanged: (value) => setState(
                            () => rules[index] = SmartRule(rules[index].field, value!, negate: rules[index].negate),
                          ),
                        )
                      else if (![
                        SmartField.favorite,
                        SmartField.offline,
                        SmartField.stream,
                      ].contains(rules[index].field))
                        TextFormField(
                          key: ValueKey('$index:${rules[index].field}:${name.text}'),
                          initialValue: rules[index].value,
                          decoration: InputDecoration(labelText: context.tr('Value')),
                          keyboardType: [SmartField.title, SmartField.artist].contains(rules[index].field)
                              ? TextInputType.text
                              : TextInputType.number,
                          onChanged: (value) => setState(
                            () => rules[index] = SmartRule(rules[index].field, value, negate: rules[index].negate),
                          ),
                        ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(context.tr('Exclude matches')),
                        value: rules[index].negate,
                        onChanged: (value) => setState(
                          () => rules[index] = SmartRule(rules[index].field, rules[index].value, negate: value!),
                        ),
                      ),
                    ],
                  ),
                ),
              TextButton.icon(
                onPressed: () => setState(() => rules.add(const SmartRule(SmartField.title, ''))),
                icon: const Icon(Icons.add),
                label: Text(context.tr('Add rule')),
              ),
              if (rules.any((rule) => rule.field == SmartField.lastPlayedDays))
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.tr('Include never-played tracks')),
                  value: includeNever,
                  onChanged: (value) => setState(() => includeNever = value!),
                ),
              DropdownButtonFormField<String>(
                initialValue: sort,
                isExpanded: true,
                decoration: InputDecoration(labelText: context.tr('Sort tracks')),
                items: [
                  for (final entry in {
                    'title': 'Title',
                    'artist': 'Artist',
                    'added': 'Date added',
                    if (hasStats || sort == 'plays') 'plays': 'Play count',
                  }.entries)
                    DropdownMenuItem(value: entry.key, child: Text(context.tr(entry.value))),
                ],
                onChanged: (value) => setState(() => sort = value!),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(context.tr('Descending')),
                value: descending,
                onChanged: (value) => setState(() => descending = value!),
              ),
              TextField(
                controller: limit,
                decoration: InputDecoration(labelText: context.tr('Track limit (optional)')),
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              Text(context.tr('{0} matching tracks', [preview.length]), style: Theme.of(context).textTheme.titleSmall),
              for (final track in preview.take(3)) Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (widget.current?.exclusions.isNotEmpty == true)
                TextButton(
                  onPressed: () {
                    Navigator.pop(context, SmartPlaylist.fromJson(_value().toJson()..['exclusions'] = []));
                  },
                  child: Text(context.tr('Save and reset exclusions')),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Cancel'))),
        FilledButton(
          onPressed:
              name.text.trim().isEmpty ||
                  rules.any(
                    (rule) =>
                        ![SmartField.favorite, SmartField.offline, SmartField.stream].contains(rule.field) &&
                        (rule.value.trim().isEmpty ||
                            ![SmartField.title, SmartField.artist].contains(rule.field) &&
                                (int.tryParse(rule.value) == null || int.parse(rule.value) < 0)),
                  ) ||
                  limit.text.isNotEmpty && (int.tryParse(limit.text) == null || int.parse(limit.text) < 1)
              ? null
              : () => Navigator.pop(context, _value()),
          child: Text(context.tr('Save')),
        ),
      ],
    );
  }
}

void showLibraryError(BuildContext context, Object error) => ScaffoldMessenger.of(
  context,
).showSnackBar(SnackBar(content: Text(context.tr('Could not complete this action: {0}', ['$error']))));
