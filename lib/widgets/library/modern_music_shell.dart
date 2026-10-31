import 'package:flutter/material.dart';
import 'package:resonance/l10n/app_strings.dart';

/// Presentation only: navigation and playlist ownership stay in MainApp.
class ModernMusicShell extends StatelessWidget {
  const ModernMusicShell({
    super.key,
    required this.selected,
    required this.onSelected,
    required this.content,
    required this.player,
    required this.onSettings,
    required this.onHistory,
    required this.downloads,
    this.playlists = const [],
    this.onCreatePlaylist,
  });
  final int selected;
  final ValueChanged<int> onSelected;
  final Widget content, player, downloads;
  final VoidCallback onSettings, onHistory;
  final List<ModernPlaylistDestination> playlists;
  final VoidCallback? onCreatePlaylist;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 850;
      final colors = Theme.of(context).colorScheme;
      final labels = [context.tr('Discover'), context.tr('Search'), context.tr('Library')];
      const icons = [Icons.explore_outlined, Icons.search_rounded, Icons.library_music_outlined];
      Widget navigation(int index, {bool compact = false}) {
        final active = selected == index;
        return Semantics(
          selected: active,
          button: true,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => onSelected(index),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 16, vertical: compact ? 8 : 12),
              child: compact
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icons[index], size: 22, color: active ? colors.primary : colors.onSurfaceVariant),
                        const SizedBox(height: 3),
                        Text(
                          labels[index],
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                            color: active ? colors.onSurface : colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        Icon(icons[index], size: 21, color: active ? colors.onSurface : colors.onSurfaceVariant),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            labels[index],
                            style: TextStyle(
                              fontSize: 14,
                              color: active ? colors.onSurface : colors.onSurfaceVariant,
                              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        );
      }

      return SafeArea(
        bottom: false,
        child: Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  if (wide)
                    SizedBox(
                      width: 224,
                      child: Padding(
                        padding: const EdgeInsetsDirectional.fromSTEB(12, 18, 12, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsetsDirectional.fromSTEB(13, 0, 8, 24),
                              child: Row(
                                children: [
                                  Image.asset('assets/icon/icon.png', width: 30, height: 30),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      context.tr('Resonance'),
                                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            for (var i = 0; i < labels.length; i++)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 2),
                                child: Material(
                                  color: selected == i ? colors.surfaceContainerHigh : Colors.transparent,
                                  borderRadius: BorderRadius.circular(8),
                                  child: navigation(i),
                                ),
                              ),
                            const SizedBox(height: 24),
                            Row(
                              children: [
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Text(
                                    context.tr('Playlists'),
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: context.tr('Create playlist'),
                                  onPressed: onCreatePlaylist,
                                  icon: const Icon(Icons.add_rounded, size: 19),
                                ),
                              ],
                            ),
                            Expanded(
                              child: ListView.builder(
                                itemCount: playlists.length,
                                itemBuilder: (context, index) {
                                  final entry = playlists[index];
                                  final accent = entry.favorite ? const Color(0xFFFFD740) : colors.onSurface;
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 2),
                                    child: ListTile(
                                      dense: true,
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                      selected: selected == 2 && entry.selected,
                                      selectedTileColor: colors.onSurface.withValues(alpha: .06),
                                      leading: Container(
                                        width: 34,
                                        height: 34,
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: accent.withValues(alpha: .07),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Icon(
                                          entry.favorite ? Icons.star_rounded : Icons.queue_music_rounded,
                                          size: 18,
                                          color: accent,
                                        ),
                                      ),
                                      title: Text(
                                        entry.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: entry.selected ? FontWeight.w600 : FontWeight.w400,
                                          color: accent,
                                        ),
                                      ),
                                      onTap: entry.onSelected,
                                      onLongPress: entry.onActions,
                                    ),
                                  );
                                },
                              ),
                            ),
                            ListTile(
                              dense: true,
                              leading: const Icon(Icons.settings_outlined, size: 20),
                              title: Text(context.tr('Settings'), style: const TextStyle(fontSize: 13)),
                              onTap: onSettings,
                            ),
                          ],
                        ),
                      ),
                    ),
                  Expanded(
                    child: Column(
                      children: [
                        Padding(
                          padding: EdgeInsetsDirectional.fromSTEB(wide ? 24 : 20, wide ? 16 : 8, 12, 10),
                          child: Row(
                            children: [
                              Expanded(
                                child: Semantics(
                                  header: true,
                                  child: Text(
                                    labels[selected],
                                    style: TextStyle(
                                      fontSize: wide ? 26 : 24,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: -.6,
                                    ),
                                  ),
                                ),
                              ),
                              downloads,
                              IconButton(
                                tooltip: context.tr('History'),
                                onPressed: onHistory,
                                icon: const Icon(Icons.history_rounded, size: 21),
                              ),
                              if (!wide)
                                IconButton(
                                  tooltip: context.tr('Settings'),
                                  onPressed: onSettings,
                                  icon: const Icon(Icons.settings_outlined, size: 21),
                                ),
                            ],
                          ),
                        ),
                        Expanded(child: ClipRect(child: content)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            player,
            if (!wide)
              Material(
                color: colors.surface,
                child: SafeArea(
                  top: false,
                  child: Row(
                    children: [for (var i = 0; i < labels.length; i++) Expanded(child: navigation(i, compact: true))],
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

class ModernPlaylistDestination {
  const ModernPlaylistDestination({
    required this.name,
    required this.onSelected,
    this.onActions,
    this.selected = false,
    this.favorite = false,
  });
  final String name;
  final bool selected, favorite;
  final VoidCallback onSelected;
  final VoidCallback? onActions;
}
