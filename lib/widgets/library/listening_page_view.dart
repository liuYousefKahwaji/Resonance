import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

/// The scroll position drives the transition, so pages follow the finger rather
/// than being replaced when a horizontal gesture ends. Visited pages stay alive.
class ListeningPageView extends StatefulWidget {
  const ListeningPageView({super.key, required this.selected, required this.onSelected, required this.builder});
  final int selected;
  final ValueChanged<int> onSelected;
  final IndexedWidgetBuilder builder;

  @override
  State<ListeningPageView> createState() => _ListeningPageViewState();
}

class _ListeningPageViewState extends State<ListeningPageView> {
  late final PageController _controller = PageController(initialPage: widget.selected);
  late int _visible = widget.selected;
  int? _navigationTarget;

  @override
  void didUpdateWidget(ListeningPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected == widget.selected || (_visible == widget.selected && _navigationTarget == null)) return;
    final target = widget.selected;
    _navigationTarget = target;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.jumpToPage(target);
      _navigationTarget = null;
    } else {
      _controller
          .animateToPage(target, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic)
          .whenComplete(() {
            if (_navigationTarget == target) _navigationTarget = null;
          });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => NotificationListener<UserScrollNotification>(
    onNotification: (notification) {
      if (notification.depth == 0 && notification.direction != ScrollDirection.idle) _navigationTarget = null;
      return false;
    },
    child: PageView.builder(
      key: const Key('listening-pages'),
      controller: _controller,
      // Discover owns its horizontal shelves. Tab taps can still animate away
      // from it, but a shelf gesture must never start a page swipe.
      physics: _visible == 0 ? const NeverScrollableScrollPhysics() : const ClampingScrollPhysics(),
      itemCount: 3,
      onPageChanged: (index) {
        setState(() => _visible = index);
        if ((_navigationTarget == null || _navigationTarget == index) && index != widget.selected) {
          widget.onSelected(index);
        }
      },
      itemBuilder: (context, index) =>
          _ListeningPage(key: ValueKey(index), active: index == _visible, child: widget.builder(context, index)),
    ),
  );
}

class _ListeningPage extends StatefulWidget {
  const _ListeningPage({super.key, required this.active, required this.child});
  final bool active;
  final Widget child;
  @override
  State<_ListeningPage> createState() => _ListeningPageState();
}

class _ListeningPageState extends State<_ListeningPage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return TickerMode(
      enabled: widget.active,
      child: ExcludeFocus(excluding: !widget.active, child: widget.child),
    );
  }
}
