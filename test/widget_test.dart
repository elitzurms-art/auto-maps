// בדיקת עשן בסיסית לאפליקציית Auto Maps.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:auto_maps/main.dart';

void main() {
  testWidgets('האפליקציה נטענת ומציגה את מסך הבית', (WidgetTester tester) async {
    await tester.pumpWidget(const AutoMapsApp());
    await tester.pump();

    // ה-MaterialApp נבנה בהצלחה עם מסך הבית.
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
