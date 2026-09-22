import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile/main.dart';

void main() {
  testWidgets('app builds and shows empty session view', (WidgetTester tester) async {
    await tester.pumpWidget(const DshMobileApp());
    // 首帧 = 空会话视图（未连接）：标题 + 引导文案 + 去连接按钮
    expect(find.text('DSH Mobile'), findsOneWidget);
    expect(find.text('先在「连接设置」中连接 DSH'), findsOneWidget);
    expect(find.text('去连接'), findsOneWidget);
  });
}
