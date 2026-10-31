import 'dart:async';
import 'package:flutter/material.dart';
import 'package:resonance/services/track_links.dart';
import 'package:resonance/l10n/app_strings.dart';

const _actions = ['copy-link', 'open-youtube', 'open-ytmusic'];
String _label(BuildContext context, String action, TrackLinks links) => context.tr(switch (action) {
  'copy-link' => 'Copy link',
  'open-ytmusic' => 'Open in YouTube Music',
  _ => links.youtubeId == null ? 'Open in Google Drive' : 'Open in YouTube',
});
IconData _icon(String action) => action == 'copy-link' ? Icons.link_rounded : Icons.open_in_new_rounded;

/// Works for network rows and exact saved sources of downloaded local tracks.
class TrackLinkMenu extends StatefulWidget {
  const TrackLinkMenu({
    super.key,
    required this.trackId,
    this.extraEntries = const [],
    this.onExtraSelected,
    this.enabled = true,
    this.iconColor,
    this.icon = const Icon(Icons.more_horiz_rounded),
    this.tooltip,
  });
  final String trackId;
  final List<PopupMenuEntry<String>> extraEntries;
  final ValueChanged<String>? onExtraSelected;
  final bool enabled;
  final Color? iconColor;
  final Widget icon;
  final String? tooltip;
  @override
  State<TrackLinkMenu> createState() => _TrackLinkMenuState();
}

class _TrackLinkMenuState extends State<TrackLinkMenu> {
  late Future<TrackLinks?> _links;
  @override
  void initState() {
    super.initState();
    _links = TrackLinks.resolve(widget.trackId);
  }

  @override
  void didUpdateWidget(TrackLinkMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trackId != widget.trackId) _links = TrackLinks.resolve(widget.trackId);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<TrackLinks?>(
    future: _links,
    initialData: TrackLinks.direct(widget.trackId),
    builder: (context, snapshot) {
      final links = snapshot.data;
      if (links == null && widget.extraEntries.isEmpty) return const SizedBox.shrink();
      return PopupMenuButton<String>(
        tooltip: widget.tooltip ?? context.tr('More actions'),
        enabled: widget.enabled,
        icon: widget.icon,
        iconColor: widget.iconColor,
        onSelected: (action) {
          if (_actions.contains(action)) {
            if (links != null) unawaited(links.perform(context, action));
          } else {
            widget.onExtraSelected?.call(action);
          }
        },
        itemBuilder: (_) => [
          ...widget.extraEntries,
          if (links != null) ...[
            if (widget.extraEntries.isNotEmpty) const PopupMenuDivider(),
            for (final action in _actions)
              if (action != 'open-ytmusic' || links.youtubeId != null)
                PopupMenuItem(
                  value: action,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_icon(action), size: 18),
                      const SizedBox(width: 10),
                      Flexible(child: Text(_label(context, action, links), maxLines: 2)),
                    ],
                  ),
                ),
          ],
        ],
      );
    },
  );
}

class TrackLinkMenuSection extends StatefulWidget {
  const TrackLinkMenuSection({super.key, required this.trackId});
  final String trackId;
  @override
  State<TrackLinkMenuSection> createState() => _TrackLinkMenuSectionState();
}

class _TrackLinkMenuSectionState extends State<TrackLinkMenuSection> {
  late Future<TrackLinks?> _links;
  @override
  void initState() {
    super.initState();
    _links = TrackLinks.resolve(widget.trackId);
  }

  @override
  void didUpdateWidget(TrackLinkMenuSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trackId != widget.trackId) _links = TrackLinks.resolve(widget.trackId);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<TrackLinks?>(
    future: _links,
    initialData: TrackLinks.direct(widget.trackId),
    builder: (context, snapshot) {
      final links = snapshot.data;
      if (links == null) return const SizedBox.shrink();
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final action in _actions)
            if (action != 'open-ytmusic' || links.youtubeId != null)
              MenuItemButton(
                leadingIcon: Icon(_icon(action), size: 18),
                onPressed: () => unawaited(links.perform(context, action)),
                child: Text(_label(context, action, links)),
              ),
        ],
      );
    },
  );
}
