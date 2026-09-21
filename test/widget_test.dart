// Smoke tests for the redesigned app shell: the provider-tab entry renders
// its chrome and each tab switches to its connection form — all without
// touching the engine (no FFI layer is loaded on render).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:acui/main.dart';

void main() {
  testWidgets('provider tabs render and switch forms', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: AcuiApp()));
    await tester.pumpAndSettle();

    // Shell chrome: tab switcher + provider heading.
    expect(find.bySubtype<SegmentedButton>(), findsOneWidget);
    expect(find.text('PROVIDER'), findsOneWidget);

    // Default tab is FTP/FTPS.
    expect(find.text('FTP / FTPS SERVER'), findsOneWidget);
    expect(find.text('CONNECT'), findsOneWidget);

    // Switch to SFTP/SSH.
    await tester.tap(find.text('SFTP/SSH'));
    await tester.pumpAndSettle();
    expect(find.text('SFTP / SSH CONNECTION'), findsOneWidget);

    // Switch to CREATE.
    await tester.tap(find.text('CREATE'));
    await tester.pumpAndSettle();
    expect(find.text('CREATE NEW LOCAL VAULT (.AC)'), findsOneWidget);
    expect(find.text('KEY DERIVATION PARAMETERS'), findsOneWidget);

    // Switch to OPEN.
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();
    expect(find.text('OPEN LOCAL VAULT (.AC)'), findsOneWidget);
    expect(find.text('OPEN VAULT'), findsOneWidget);
  });
}
