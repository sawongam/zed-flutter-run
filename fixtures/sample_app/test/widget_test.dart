import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sample_app/main.dart';

void main() {
  test('bump increments', () => expect(bump(1), 2));

  testWidgets('counter increments', (tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.text('Count: 0'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    expect(find.text('Count: 1'), findsOneWidget);
  });
}
