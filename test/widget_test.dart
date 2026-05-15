import 'package:easyterm/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app builds', (WidgetTester tester) async {
    await tester.pumpWidget(const EasyTermApp());
    await tester.pump();
  });
}
