import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/widgets/android_update_status.dart';

void main() {
  testWidgets('Android background progress advances to explicit install approval and retry', (tester) async {
    var status = <String, dynamic>{'version': '3.4.6', 'state': 'downloading', 'received': 1048576, 'total': 4194304};
    var reads = 0;
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AndroidUpdateStatus(
            statusLoader: () async {
              reads++;
              return status;
            },
            retry: () async => retries++,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Updating to 3.4.6'), findsOneWidget);
    expect(find.text('25%'), findsOneWidget);
    status = {...status, 'received': 2097152};
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('50%'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final before = reads;
    await tester.pump(const Duration(seconds: 5));
    expect(reads, before);
    status = {...status, 'state': 'awaiting_approval'};
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('Ready to install. Android needs your approval.'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.tap(find.text('Continue installation'));
    await tester.pump();
    expect(retries, 1);
    await tester.pumpWidget(const SizedBox());
  });
}
