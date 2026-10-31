import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/widgets/library/modern_music_shell.dart';
import 'package:resonance/widgets/library/current_track_surface.dart';
import 'package:resonance/widgets/library/listening_page_view.dart';
import 'package:resonance/widgets/library/track_list.dart';
import 'package:resonance/widgets/player/upcoming_queue.dart';
import 'package:resonance/models/playback_queue_snapshot.dart';
import 'package:audio_service/audio_service.dart';

Widget shell({
  required int selected,
  required ValueChanged<int> onSelected,
  bool swipes = true,
  Widget? content,
  ValueChanged<bool>? collapse,
  Widget? artwork,
  IndexedWidgetBuilder? pageBuilder,
}) => ModernMusicShell(
  selected: selected,
  onSelected: onSelected,
  enableMobileSwipes: swipes,
  pageBuilder: pageBuilder,
  onSidebarCollapsed: collapse,
  content: content ?? const SizedBox.expand(),
  player: const SizedBox(height: 70),
  downloads: const SizedBox(width: 30),
  onSettings: () {},
  onHistory: () {},
  playlists: [ModernPlaylistDestination(name: 'Playlist cover', onSelected: () {}, artwork: artwork)],
  onCreatePlaylist: () {},
);
void main() {
  testWidgets('pages follow the finger, cancel smoothly, and retain visited page state', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var selected = 2;
    final starts = <int, int>{};
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: shell(
              selected: selected,
              onSelected: (i) => setState(() => selected = i),
              pageBuilder: (context, index) => SizedBox.expand(
                key: ValueKey('page-$index'),
                child: _Probe(onStart: () => starts.update(index, (n) => n + 1, ifAbsent: () => 1)),
              ),
            ),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('page-2'))));
    await gesture.moveBy(const Offset(90, 0), timeStamp: const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 16));
    final duringDrag = tester.getTopLeft(find.byKey(const ValueKey('page-2'))).dx;
    expect(duringDrag, greaterThan(30));
    expect(duringDrag, lessThan(120));
    expect(selected, 2, reason: 'The page moves before committing a new destination.');
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(const ValueKey('page-2'))).dx, closeTo(0, .1));
    await tester.drag(find.byKey(const ValueKey('page-2')), const Offset(250, 0));
    await tester.pumpAndSettle();
    expect(selected, 1);
    await tester.drag(find.byKey(const ValueKey('page-1')), const Offset(-250, 0));
    await tester.pumpAndSettle();
    expect(selected, 2);
    expect(starts[1], 1);
    expect(starts[2], 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('tab navigation animates past intermediate pages without selecting them', (tester) async {
    var selected = 2;
    final changes = <int>[];
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return ListeningPageView(
              selected: selected,
              onSelected: (i) {
                changes.add(i);
                setState(() => selected = i);
              },
              builder: (context, index) => Center(child: Text('Page $index')),
            );
          },
        ),
      ),
    );
    update(() => selected = 0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 75));
    final page = tester.widget<PageView>(find.byType(PageView)).controller!.page!;
    expect(page, greaterThan(0));
    expect(page, lessThan(2));
    await tester.pumpAndSettle();
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 0);
    expect(selected, 0);
    expect(changes, isEmpty);
    update(() => selected = 2);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    update(() => selected = 0);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(
      tester.widget<PageView>(find.byType(PageView)).controller!.page,
      0,
      reason: 'A second tap can reverse an in-progress transition back to its starting page.',
    );
    expect(changes, isEmpty);
  });
  testWidgets('sidebar collapses smoothly to icons without rebuilding the page or artwork', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var pageStarts = 0, artStarts = 0;
    bool? persisted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: shell(
            selected: 2,
            onSelected: (_) {},
            content: _Probe(onStart: () => pageStarts++),
            artwork: _Probe(onStart: () => artStarts++),
            collapse: (v) => persisted = v,
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byKey(const Key('modern-sidebar'))).width, 224);
    await tester.tap(find.byKey(const Key('sidebar-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final width = tester.getSize(find.byKey(const Key('modern-sidebar'))).width;
    expect(width, greaterThan(76));
    expect(width, lessThan(224));
    expect(persisted, isTrue);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const Key('modern-sidebar'))).width, 76);
    expect(find.text('Playlist cover'), findsNothing);
    expect(find.byTooltip('Playlist cover'), findsOneWidget);
    expect(pageStarts, 1);
    expect(artStarts, 1);
    await tester.tap(find.byKey(const Key('sidebar-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Playlist cover'), findsOneWidget);
    expect(persisted, isFalse);
    expect(pageStarts, 1);
    expect(artStarts, 1);
    expect(tester.takeException(), isNull);
  });
  for (final rtl in [false, true]) {
    testWidgets('Android swipes navigate from Library/Search but leave Discover shelves alone rtl=$rtl', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(390, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var selected = 2;
      final shelf = ScrollController();
      addTearDown(shelf.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) => Directionality(
              textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
              child: Scaffold(
                body: shell(
                  selected: selected,
                  onSelected: (i) => setState(() => selected = i),
                  pageBuilder: (context, index) => index == 0
                      ? ListView(
                          key: const Key('shelf'),
                          controller: shelf,
                          scrollDirection: Axis.horizontal,
                          children: List.generate(10, (i) => SizedBox(width: 180, child: Text('Collection $i'))),
                        )
                      : ListView(
                          key: ValueKey('tracks-$index'),
                          children: List.generate(30, (i) => SizedBox(height: 60, child: Text('Track $i'))),
                        ),
                ),
              ),
            ),
          ),
        ),
      );
      final right = Offset(rtl ? -230 : 230, 0), left = -right;
      await tester.drag(find.byKey(const ValueKey('tracks-2')), right);
      await tester.pumpAndSettle();
      expect(selected, 1);
      await tester.drag(find.byKey(const ValueKey('tracks-1')), left);
      await tester.pumpAndSettle();
      expect(selected, 2);
      await tester.drag(find.byKey(const ValueKey('tracks-2')), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(selected, 2);
      await tester.drag(find.byKey(const ValueKey('tracks-2')), right);
      await tester.pumpAndSettle();
      expect(selected, 1);
      await tester.drag(find.byKey(const ValueKey('tracks-1')), right);
      await tester.pumpAndSettle();
      expect(selected, 0);
      await tester.drag(find.byKey(const Key('shelf')), left);
      await tester.pumpAndSettle();
      expect(selected, 0);
      expect(shelf.offset, greaterThan(0));
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('active row pulse is faint, stops when inactive and respects reduced motion', (tester) async {
    Widget frame(bool enabled, {bool reduced = false}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Scaffold(
          body: CurrentTrackSurface(
            enabled: enabled,
            duration: Duration.zero,
            curve: Curves.linear,
            decoration: const BoxDecoration(color: Colors.black),
            child: const SizedBox(width: 300, height: 60, child: Text('Current song')),
          ),
        ),
      ),
    );
    double alpha() =>
        tester.widget<DecoratedBox>(find.byKey(const Key('current-track-pulse'))).decoration is BoxDecoration
        ? (tester.widget<DecoratedBox>(find.byKey(const Key('current-track-pulse'))).decoration as BoxDecoration)
              .color!
              .a
        : 0;
    await tester.pumpWidget(frame(true));
    await tester.pump(const Duration(milliseconds: 800));
    expect(alpha(), greaterThan(0));
    expect(alpha(), lessThan(.05));
    await tester.pumpWidget(frame(false));
    expect(alpha(), 0);
    await tester.pumpWidget(frame(true, reduced: true));
    await tester.pump(const Duration(seconds: 2));
    expect(alpha(), 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('blur is visible during fast scrolling and disabled for reduced motion', (tester) async {
    Widget frame(bool reduced) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: const TrackListMotionBlurSurface(enabled: true, strength: 1, child: SizedBox(width: 300, height: 500)),
      ),
    );
    await tester.pumpWidget(frame(false));
    expect(tester.widget<ImageFiltered>(find.byType(ImageFiltered)).enabled, isTrue);
    expect(tester.widget<ImageFiltered>(find.byType(ImageFiltered)).imageFilter.toString(), contains('2.1'));
    await tester.pumpWidget(frame(true));
    await tester.pumpAndSettle();
    expect(tester.widget<ImageFiltered>(find.byType(ImageFiltered)).enabled, isFalse);
  });
  testWidgets('queue sheet opens from a root-owned callback and allows selecting a song', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    final revision = ValueNotifier<int>(0);
    addTearDown(revision.dispose);
    PlaybackQueueEntry? played;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        home: Scaffold(
          body: TextButton(
            child: const Text('Queue'),
            onPressed: () => showUpcomingQueueSheet(
              nav.currentState!,
              panel: (close) => UpcomingQueuePanel(
                compact: true,
                initialMediaItem: const MediaItem(id: 'now', title: 'Now'),
                mediaItemStream: const Stream.empty(),
                revision: revision,
                loadSnapshot: () async => const PlaybackQueueSnapshot(
                  current: PlaybackQueueEntry(id: 'now', title: 'Now', artist: 'Artist'),
                  upcoming: [PlaybackQueueEntry(id: 'next', title: 'Next song', artist: 'Artist')],
                  loopBehavior: QueueLoopBehavior.all,
                  shuffled: false,
                ),
                onPlay: (entry) async => played = entry,
                onClose: close,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Queue'));
    await tester.pumpAndSettle();
    expect(find.text('Next song'), findsOneWidget);
    await tester.tap(find.text('Next song'));
    await tester.pumpAndSettle();
    expect(played?.id, 'next');
    expect(tester.takeException(), isNull);
  });
}

class _Probe extends StatefulWidget {
  const _Probe({required this.onStart});
  final VoidCallback onStart;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    widget.onStart();
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.teal);
}
