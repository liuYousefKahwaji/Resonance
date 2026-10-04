import 'package:flutter/material.dart';
import 'package:resonance/core/storage/file_service.dart';

Future<bool> showPlaylistSortDialog(NavigatorState navigator, int number, {FileService? fileService}) async {
  // MainApp owns MaterialApp, so its own context cannot open a dialog.
  // Resolve the context inside the navigator rather than accepting a root context.
  final service = fileService ?? FileService();
  final saved = await service.playlistSortState(number);
  final context = navigator.overlay?.context;
  if (!navigator.mounted || context == null || !context.mounted) return false;
  var mode = saved.mode;
  var descending = saved.descending;
  var favoritesFirst = saved.favoritesFirst;
  var reroll = false;
  final accepted = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Sort tracks'),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<PlaylistSortMode>(
                initialValue: mode,
                decoration: const InputDecoration(labelText: 'Order'),
                items: const [
                  DropdownMenuItem(value: PlaylistSortMode.dateAdded, child: Text('Date added')),
                  DropdownMenuItem(value: PlaylistSortMode.title, child: Text('Alphanumeric')),
                  DropdownMenuItem(value: PlaylistSortMode.random, child: Text('Random')),
                  DropdownMenuItem(value: PlaylistSortMode.custom, child: Text('Manual order')),
                ],
                onChanged: (value) => setState(() => mode = value!),
              ),
              CheckboxListTile(
                key: const Key('favorites-first-sort'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Favorites first'),
                subtitle: const Text('Keep favorites at the top in either direction.'),
                value: favoritesFirst,
                onChanged: (value) => setState(() => favoritesFirst = value!),
              ),
              if (mode != PlaylistSortMode.custom)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Descending'),
                  subtitle: Text(
                    mode == PlaylistSortMode.dateAdded
                        ? 'Newest first'
                        : mode == PlaylistSortMode.title
                        ? 'Z → A'
                        : 'Reverse random order',
                  ),
                  value: descending,
                  onChanged: (value) => setState(() => descending = value),
                ),
              if (mode == PlaylistSortMode.random) ...[
                const Text('Keeps this order until you change it. Playback shuffle is separate.'),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Generate a new random order'),
                  value: reroll,
                  onChanged: (value) => setState(() => reroll = value!),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Apply')),
        ],
      ),
    ),
  );
  if (accepted != true) return false;
  await service.sortPlaylist(number, mode, descending: descending, reroll: reroll, favoritesFirst: favoritesFirst);
  return true;
}
