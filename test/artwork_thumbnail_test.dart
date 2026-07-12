import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/widgets/common/artwork_thumbnail.dart';

void main() {
  testWidgets('track artwork keeps a stable square layout', (tester) async {
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: ArtworkThumbnail(bytes: bytes, size: 34)),
        ),
      ),
    );
    await tester.pump();

    expect(tester.getSize(find.byType(ArtworkThumbnail)), const Size.square(34));
    expect(tester.takeException(), isNull);
  });
}
