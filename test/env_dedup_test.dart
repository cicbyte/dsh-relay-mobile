import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dsh_mobile/dsh/profiles.dart';

void main() {
  test('dedupKeyOf：转发=relay+房间，局域网=地址，尾斜杠/大小写归一', () {
    final a = EnvProfile(
      id: 'a',
      name: 'x',
      mode: 1,
      relay: 'ws://43.142.164.215:8787',
      roomCode: '7ba756f2',
    );
    final b = EnvProfile(
      id: 'b',
      name: 'y',
      mode: 1,
      relay: 'WS://43.142.164.215:8787/',
      roomCode: '7ba756f2',
    );
    final c = EnvProfile(
      id: 'c',
      name: 'z',
      mode: 1,
      relay: 'ws://43.142.164.215:8787',
      roomCode: 'other-room',
    );
    final lan1 = EnvProfile(
      id: 'd',
      name: 'l1',
      mode: 0,
      url: 'http://192.168.31.5:3080',
    );
    final lan2 = EnvProfile(
      id: 'e',
      name: 'l2',
      mode: 0,
      url: 'HTTP://192.168.31.5:3080/',
    );

    expect(EnvProfile.dedupKeyOf(a), EnvProfile.dedupKeyOf(b)); // 同环境
    expect(EnvProfile.dedupKeyOf(a), isNot(EnvProfile.dedupKeyOf(c))); // 房间不同
    expect(EnvProfile.dedupKeyOf(lan1), EnvProfile.dedupKeyOf(lan2)); // 同局域网
    expect(
      EnvProfile.dedupKeyOf(a),
      isNot(EnvProfile.dedupKeyOf(lan1)),
    ); // 模式不同
  });

  test('dedupe：同键只留一条且优先已配对，并回写清理', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final dup1 = EnvProfile(
      id: 'p1',
      name: 'a',
      mode: 1,
      relay: 'ws://h:1',
      roomCode: 'r',
    );
    final dup2 = EnvProfile(
      id: 'p2',
      name: 'b',
      mode: 1,
      relay: 'ws://h:1',
      roomCode: 'r',
      deviceId: 'dev-1',
    );
    final other = EnvProfile(id: 'q', name: 'c', mode: 0, url: 'http://h:2');
    final result = await ProfileStore.dedupe([dup1, dup2, other]);
    expect(result.length, 2);
    expect(result.firstWhere((e) => e.mode == 1).id, 'p2'); // 保留已配对
    expect(result.any((e) => e.id == 'q'), isTrue);
  });
}
