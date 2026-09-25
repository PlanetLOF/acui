import 'package:acui/ui/common/action_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('action sheet scrolls instead of overflowing', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => const ActionSheet(
                    title: 'File actions',
                    children: [
                      ListTile(title: Text('View information')),
                      ListTile(title: Text('Preview')),
                      ListTile(title: Text('Move to…')),
                      ListTile(title: Text('Extract…')),
                      ListTile(title: Text('Rename…')),
                      ListTile(title: Text('Delete…')),
                      ListTile(title: Text('Another action')),
                    ],
                  ),
                ),
                child: const Text('Open actions'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open actions'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsOneWidget);

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
