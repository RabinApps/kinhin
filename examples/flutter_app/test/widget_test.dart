import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/main.dart';

void main() {
  testWidgets('shows the greeting', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Hello from kinhin'), findsOneWidget);
  });
}
