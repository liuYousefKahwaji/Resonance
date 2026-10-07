import 'package:resonance/l10n/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:resonance/services/favorites_repository.dart';

class FavoriteTracksButton extends StatelessWidget {
  final List<String> tracks;
  final ValueChanged<bool> onPressed;

  const FavoriteTracksButton({super.key, required this.tracks, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final favorites = context.watch<FavoritesRepository?>();
    if (favorites == null) return const SizedBox.shrink();
    final remove = favorites.mostlyFavorite(tracks);
    return IconButton(
      onPressed: tracks.isEmpty ? null : () => onPressed(!remove),
      icon: Icon(remove ? Icons.star_rounded : Icons.star_outline_rounded, color: FavoritesRepository.gold),
      tooltip: remove ? context.tr("Remove selected from favorites") : context.tr("Add selected to favorites"),
    );
  }
}
