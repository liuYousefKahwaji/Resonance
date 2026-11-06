import 'package:resonance/widgets/player/player_surface.dart';
import 'package:flutter/material.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/app/resonance_motion.dart';
import 'listening_page_view.dart';

/// Presentation only: navigation and playlist ownership stay in MainApp.
class ModernMusicShell extends StatefulWidget {
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
    this.sidebarCollapsed = false,
    this.onSidebarCollapsed,
    this.enableMobileSwipes = false,
    this.pageBuilder,
  });
  final int selected;
  final ValueChanged<int> onSelected;
  final Widget content, player, downloads;
  final VoidCallback onSettings, onHistory;
  final List<ModernPlaylistDestination> playlists;
  final VoidCallback? onCreatePlaylist;
  final bool sidebarCollapsed, enableMobileSwipes;
  final ValueChanged<bool>? onSidebarCollapsed;
  final IndexedWidgetBuilder? pageBuilder;
  @override
  State<ModernMusicShell> createState() => _ModernMusicShellState();
}

class _ModernMusicShellState extends State<ModernMusicShell> {
  late bool _collapsed = widget.sidebarCollapsed;
  @override
  void didUpdateWidget(ModernMusicShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sidebarCollapsed != widget.sidebarCollapsed) _collapsed = widget.sidebarCollapsed;
  }

  void _toggleSidebar() {
    setState(() => _collapsed = !_collapsed);
    widget.onSidebarCollapsed?.call(_collapsed);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 850;
      final colors = Theme.of(context).colorScheme;
      final labels = [context.tr('Discover'), context.tr('Search'), context.tr('Library')];
      const icons = [Icons.explore_outlined, Icons.search_rounded, Icons.library_music_outlined];
      Widget navigation(int index, {bool compact = false}) {
        final active = widget.selected == index;
        final icon = Icon(
          compact && active
              ? [Icons.explore_rounded, Icons.search_rounded, Icons.library_music_rounded][index]
              : icons[index],
          size: compact ? 25 : 21,
          color: active ? (compact ? colors.onSurface : colors.primary) : colors.onSurfaceVariant,
        );
        return Semantics(
          selected: active,
          button: true,
          label: wide && _collapsed ? labels[index] : null,
          child: Tooltip(
            message: labels[index],
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => widget.onSelected(index),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: wide && _collapsed
                      ? 0
                      : compact
                      ? 12
                      : 16,
                  vertical: 12,
                ),
                child: compact
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          icon,
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
                    : _collapsed
                    ? Center(child: icon)
                    : Row(
                        children: [
                          icon,
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
          ),
        );
      }

      Widget sidebar() {
        final width = _collapsed ? 76.0 : 224.0;
        return AnimatedContainer(
          key: const Key('modern-sidebar'),
          width: width,
          duration: resonanceDuration(context, const Duration(milliseconds: 260)),
          curve: Curves.easeInOutCubic,
          child: ClipRect(
            child: OverflowBox(
              alignment: AlignmentDirectional.centerStart,
              minWidth: width,
              maxWidth: width,
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(12, 12, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: 62,
                      child: _collapsed
                          ? Center(
                              child: IconButton(
                                key: const Key('sidebar-toggle'),
                                tooltip: context.tr('Expand sidebar'),
                                onPressed: _toggleSidebar,
                                icon: const Icon(Icons.chevron_right_rounded),
                              ),
                            )
                          : Row(
                              children: [
                                Image.asset('assets/icon/icon.png', width: 28, height: 28),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    context.tr('Resonance'),
                                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                                  ),
                                ),
                                IconButton(
                                  key: const Key('sidebar-toggle'),
                                  constraints: const BoxConstraints.tightFor(width: 30, height: 36),
                                  padding: EdgeInsets.zero,
                                  tooltip: context.tr('Collapse sidebar'),
                                  onPressed: _toggleSidebar,
                                  icon: const Icon(Icons.chevron_left_rounded, size: 21),
                                ),
                              ],
                            ),
                    ),
                    for (var i = 0; i < labels.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Material(
                          color: widget.selected == i ? colors.surfaceContainerHigh : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          child: navigation(i),
                        ),
                      ),
                    const SizedBox(height: 20),
                    SizedBox(
                      height: 40,
                      child: _collapsed
                          ? IconButton(
                              tooltip: context.tr('Create playlist'),
                              onPressed: widget.onCreatePlaylist,
                              icon: const Icon(Icons.add_rounded, size: 20),
                            )
                          : Row(
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
                                  onPressed: widget.onCreatePlaylist,
                                  icon: const Icon(Icons.add_rounded, size: 19),
                                ),
                              ],
                            ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: widget.playlists.length,
                        itemBuilder: (context, index) {
                          final entry = widget.playlists[index];
                          final accent = entry.favorite ? const Color(0xFFFFD740) : colors.onSurface;
                          final artwork = SizedBox(
                            width: 34,
                            height: 34,
                            child:
                                entry.artwork ??
                                DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: accent.withValues(alpha: .07),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Icon(
                                    entry.favorite ? Icons.star_rounded : Icons.music_note_rounded,
                                    size: 18,
                                    color: accent,
                                  ),
                                ),
                          );
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Tooltip(
                              message: entry.name,
                              child: Material(
                                color: widget.selected == 2 && entry.selected
                                    ? colors.onSurface.withValues(alpha: .06)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: entry.onSelected,
                                  onLongPress: entry.onActions,
                                  child: Padding(
                                    padding: EdgeInsets.symmetric(horizontal: _collapsed ? 9 : 14, vertical: 8),
                                    child: Semantics(
                                      label: _collapsed ? entry.name : null,
                                      selected: entry.selected,
                                      child: Row(
                                        children: [
                                          artwork,
                                          if (!_collapsed) ...[
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Text(
                                                entry.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: entry.selected ? FontWeight.w600 : FontWeight.w400,
                                                  color: accent,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    Tooltip(
                      message: context.tr('Settings'),
                      child: InkWell(
                        onTap: widget.onSettings,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: EdgeInsets.symmetric(horizontal: _collapsed ? 0 : 14, vertical: 14),
                          child: _collapsed
                              ? const Center(child: Icon(Icons.settings_outlined, size: 20))
                              : Row(
                                  children: [
                                    const Icon(Icons.settings_outlined, size: 20),
                                    const SizedBox(width: 16),
                                    Text(context.tr('Settings'), style: const TextStyle(fontSize: 13)),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }

      final content = widget.enableMobileSwipes && widget.pageBuilder != null
          ? ListeningPageView(selected: widget.selected, onSelected: widget.onSelected, builder: widget.pageBuilder!)
          : widget.content;
      return SafeArea(
        bottom: false,
        child: Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  if (wide) sidebar(),
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
                                    labels[widget.selected],
                                    style: TextStyle(
                                      fontSize: wide ? 26 : 24,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: -.6,
                                    ),
                                  ),
                                ),
                              ),
                              widget.downloads,
                              IconButton(
                                tooltip: context.tr('History'),
                                onPressed: widget.onHistory,
                                icon: const Icon(Icons.history_rounded, size: 21),
                              ),
                              if (!wide)
                                IconButton(
                                  tooltip: context.tr('Settings'),
                                  onPressed: widget.onSettings,
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
            widget.player,
            if (!wide)
              Material(
                key: const Key('modern-mobile-footer'),
                color: playerSurfaceColor(context),
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
    this.artwork,
  });
  final String name;
  final bool selected, favorite;
  final Widget? artwork;
  final VoidCallback onSelected;
  final VoidCallback? onActions;
}
