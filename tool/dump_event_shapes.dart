// 诊断工具：dump 会话记录里所有事件类型 + data 字段名组合（找 usage/时间等信息载体）。
// 用法：dart run tool\dump_event_shapes.dart <sessionId> [dshBase]
import 'package:dsh_mobile/dsh/dsh_client.dart';
import 'package:dsh_mobile/dsh/transport.dart';

Future<void> main(List<String> args) async {
  final sid = args.isNotEmpty ? args.first : '';
  final base = args.length > 1 ? args[1] : 'http://127.0.0.1:3080';
  final client = DshClient(DirectTransport(Uri.parse(base)));
  final mux = DshMux(client);
  await mux.connect();
  final snap = await mux.open('session/follow', {
    'request': {
      'address': sessionAddress(sessionId: sid),
      'maxMessages': 200,
    },
  }).first;
  final records = (snap['records'] as List? ?? []);
  print('records=${records.length}');
  final shapes = <String, int>{};
  final samples = <String, String>{};
  for (final r in records) {
    final e = Map<String, dynamic>.from(r['event'] as Map? ?? {});
    final type = '${e['type']}';
    final data = Map<String, dynamic>.from(e['data'] as Map? ?? {});
    final key = '$type | ${data.keys.join(',')}';
    shapes[key] = (shapes[key] ?? 0) + 1;
    samples.putIfAbsent(key, () {
      // 简短样本值（截断），排查 usage/stats 等字段
      final parts = data.entries.map((en) {
        var v = '${en.value}';
        if (v.length > 60) v = '${v.substring(0, 60)}…';
        return '${en.key}=$v';
      }).join(' ; ');
      return 'seq=${e['seq']} time=${e['time']} ignorable=${e['ignorable']} || $parts';
    });
  }
  for (final k in shapes.keys.toList()..sort()) {
    print('--- [${shapes[k]}x] $k');
    print('    ${samples[k]}');
  }
  // snapshot 其他顶层字段（cursor 等）
  print('snapshot keys: ${snap.keys.join(',')}');
  mux.close();
}
