import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile/main.dart';

void main() {
  testWidgets('app builds and shows connect page', (WidgetTester tester) async {
    await tester.pumpWidget(const DshMobileApp());
    expect(find.text('连接 DSH'), findsOneWidget);
    expect(find.text('连接'), findsOneWidget);
  });
}
