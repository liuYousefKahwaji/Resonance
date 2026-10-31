import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/app/route_transitions.dart';
import 'package:resonance/widgets/common/resonance_dialog.dart';

typedef _Node = ({List<int> traversal, List<int> hit});

class _RecordingBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() => _Recorder();
}

class _Recorder extends Fake implements ui.SemanticsUpdateBuilder {
  final _delegate = ui.SemanticsUpdateBuilder();
  static final pending = <int, _Node>{};
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #updateNode) {
      final a = invocation.namedArguments;
      pending[a[#id] as int] = (
        traversal: List<int>.of(a[#childrenInTraversalOrder] as Iterable<int>),
        hit: List<int>.of(a[#childrenInHitTestOrder] as Iterable<int>),
      );
      Function.apply(_delegate.updateNode, invocation.positionalArguments, a);
      return null;
    }
    if (invocation.memberName == #updateCustomAction) {
      Function.apply(_delegate.updateCustomAction, invocation.positionalArguments, invocation.namedArguments);
      return null;
    }
    return super.noSuchMethod(invocation);
  }

  @override
  ui.SemanticsUpdate build() => _delegate.build();
}

void main() {
  _RecordingBinding();
  for (final mode in ['control', 'page', 'dialog']) {
    final safe = mode != 'control';
    testWidgets(
      safe
          ? '$mode entrance keeps slider overlays connected to accessibility parents'
          : 'control: old zero-opacity entrance serializes orphan accessibility nodes',
      (tester) async {
        final semantics = tester.ensureSemantics();
        await tester.pumpWidget(const Placeholder(), phase: EnginePhase.build);
        _Recorder.pending.clear();
        final tree = <int, _Node>{};
        final orphans = <int>[];
        var phase = 'home';
        void commit() {
          if (_Recorder.pending.isEmpty) return;
          tree.addAll(_Recorder.pending);
          Set<int> reachable(bool hit) {
            final seen = <int>{};
            void walk(int id) {
              if (!seen.add(id)) return;
              final n = tree[id];
              if (n != null) {
                for (final c in hit ? n.hit : n.traversal) {
                  walk(c);
                }
              }
            }

            walk(0);
            return seen;
          }

          final seen = reachable(false), hit = reachable(true);
          for (final id in _Recorder.pending.keys) {
            if (!seen.contains(id) || !hit.contains(id)) {
              orphans.add(id);
              if (safe) debugPrint('orphan $id during $phase traversal=${seen.toList()} hit=${hit.toList()}');
            }
          }
          tree.removeWhere((id, _) => !seen.contains(id));
          _Recorder.pending.clear();
        }

        final nav = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.windows),
            navigatorKey: nav,
            builder: safe ? (context, child) => resonanceNavigatorSemantics(context, child!) : null,
            home: Scaffold(body: Slider(value: .5, onChanged: (_) {})),
          ),
        );
        commit();
        if (mode == 'dialog') {
          showResonanceDialog<void>(
            context: nav.currentContext!,
            builder: (_) => ResonanceDialog(
              content: SizedBox(width: 400, child: Slider(value: .3, onChanged: (_) {})),
            ),
          );
        } else {
          nav.currentState!.push(
            PageRouteBuilder<void>(
              pageBuilder: (_, __, ___) => Scaffold(body: Slider(value: .3, onChanged: (_) {})),
              transitionsBuilder: safe
                  ? resonancePageTransition
                  : (_, animation, __, child) => FadeTransition(opacity: animation, child: child),
            ),
          );
        }
        phase = 'push initial';
        await tester.pump();
        commit();
        for (var i = 0; i < 8; i++) {
          phase = 'push $i';
          await tester.pump(const Duration(milliseconds: 40));
          commit();
        }
        nav.currentState!.pop();
        phase = 'pop initial';
        await tester.pump();
        commit();
        for (var i = 0; i < 8; i++) {
          phase = 'pop $i';
          await tester.pump(const Duration(milliseconds: 40));
          commit();
        }
        if (safe) {
          expect(
            orphans,
            isEmpty,
            reason: 'A node without a visible traversal parent can corrupt the native Windows AXTree.',
          );
        } else {
          expect(orphans, isNotEmpty);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        _Recorder.pending.clear();
        semantics.dispose();
      },
    );
  }
}
