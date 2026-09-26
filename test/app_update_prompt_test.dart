import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/app_update_service.dart';
import 'package:resonance/widgets/app_update_prompt.dart';

void main() {
  testWidgets('update notes render headings, emphasis, and lists as Markdown', (tester) async {
    final update = AvailableUpdate(
      version: const AppVersion(3, 4, 2),
      notes: '# Changes\n\n- **Faster** updates\n- Better controls',
      asset: UpdateAsset(
        url: Uri.parse('https://github.com/example/release.zip'),
        name: 'release.zip',
        sha256: 'a' * 64,
        size: 100,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => unawaited(showAppUpdatePrompt(context, update)),
              child: const Text('Check'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Check'));
    await tester.pumpAndSettle();

    expect(find.byType(MarkdownBody), findsOneWidget);
    final rendered = [
      ...tester.widgetList<RichText>(find.byType(RichText)).map((widget) => widget.text.toPlainText()),
      ...tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .map((widget) => widget.textSpan?.toPlainText() ?? widget.data ?? ''),
    ].join(' ');
    expect(rendered, contains('Changes'));
    expect(rendered, contains('Faster updates'));
    expect(rendered, isNot(contains('**Faster**')));
    expect(rendered, isNot(contains('# Changes')));
  });
}
