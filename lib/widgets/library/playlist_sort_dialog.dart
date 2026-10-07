import 'package:resonance/l10n/app_strings.dart';
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
        title: Text(context.tr("Sort tracks")),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<PlaylistSortMode>(
                initialValue: mode,
                decoration: InputDecoration(labelText: context.tr("Order")),
                items: [
                  DropdownMenuItem(value: PlaylistSortMode.dateAdded, child: Text(context.tr("Date added"))),
                  DropdownMenuItem(value: PlaylistSortMode.title, child: Text(context.tr("Alphanumeric"))),
                  DropdownMenuItem(value: PlaylistSortMode.random, child: Text(context.tr("Random"))),
                  DropdownMenuItem(value: PlaylistSortMode.custom, child: Text(context.tr("Manual order"))),
                ],
                onChanged: (value) => setState(() => mode = value!),
              ),
              CheckboxListTile(
                key: const Key('favorites-first-sort'),
                contentPadding: EdgeInsets.zero,
                title: Text(context.tr("Favorites first")),
                subtitle: Text(context.tr("Keep favorites at the top in either direction.")),
                value: favoritesFirst,
                onChanged: (value) => setState(() => favoritesFirst = value!),
              ),
              if (mode != PlaylistSortMode.custom)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.tr("Descending")),
                  subtitle: Text(
                    mode == PlaylistSortMode.dateAdded
                        ? context.tr("Newest first")
                        : mode == PlaylistSortMode.title
                        ? context.tr("Z → A")
                        : context.tr("Reverse random order"),
                  ),
                  value: descending,
                  onChanged: (value) => setState(() => descending = value),
                ),
              if (mode == PlaylistSortMode.random) ...[
                Text(context.tr("Keeps this order until you change it. Playback shuffle is separate.")),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.tr("Generate a new random order")),
                  value: reroll,
                  onChanged: (value) => setState(() => reroll = value!),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.tr("Cancel"))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(context.tr("Apply"))),
        ],
      ),
    ),
  );
  if (accepted != true) return false;
  await service.sortPlaylist(number, mode, descending: descending, reroll: reroll, favoritesFirst: favoritesFirst);
  return true;
}
