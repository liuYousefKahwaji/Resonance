import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/widgets/library/playlist_sort_dialog.dart';

void main() {
  testWidgets('menu owned above MaterialApp opens sorting and applies selected order', (tester) async {
    final service = _SortService();
    await tester.pumpWidget(_RootMenu(service: service));
    await tester.tap(find.byTooltip('Playlist menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sort tracks'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byType(DropdownButtonFormField<PlaylistSortMode>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alphanumeric').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(service.appliedMode, PlaylistSortMode.title);
    expect(service.appliedNumber, 4);
    expect(service.descending, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('random reroll is explicit and cancellation does not sort', (tester) async {
    final service = _SortService(mode: PlaylistSortMode.random);
    await tester.pumpWidget(_RootMenu(service: service));
    await tester.tap(find.byTooltip('Playlist menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sort tracks'));
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(service.appliedMode, isNull);

    await tester.tap(find.byTooltip('Playlist menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sort tracks'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(service.appliedMode, PlaylistSortMode.random);
    expect(service.reroll, isTrue);
    expect(tester.takeException(), isNull);
  });
}

// Like MainApp, this widget owns MaterialApp and its callbacks therefore have
// a context above the app's Navigator and MaterialLocalizations.
class _RootMenu extends StatefulWidget {
  final FileService service;
  const _RootMenu({required this.service});

  @override
  State<_RootMenu> createState() => _RootMenuState();
}

class _RootMenuState extends State<_RootMenu> {
  final navigatorKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: navigatorKey,
    home: Scaffold(
      body: PopupMenuButton<String>(
        tooltip: 'Playlist menu',
        onSelected: (_) => showPlaylistSortDialog(navigatorKey.currentState!, 4, fileService: widget.service),
        itemBuilder: (_) => [const PopupMenuItem(value: 'sort', child: Text('Sort tracks'))],
      ),
    ),
  );
}

class _SortService extends Fake implements FileService {
  final PlaylistSortMode mode;
  PlaylistSortMode? appliedMode;
  int? appliedNumber;
  bool? descending;
  bool? reroll;
  _SortService({this.mode = PlaylistSortMode.dateAdded});

  @override
  Future<PlaylistSortState> playlistSortState(int number) async => PlaylistSortState(mode: mode);

  @override
  Future<void> sortPlaylist(int number, PlaylistSortMode mode, {bool descending = false, bool reroll = false}) async {
    appliedNumber = number;
    appliedMode = mode;
    this.descending = descending;
    this.reroll = reroll;
  }
}
