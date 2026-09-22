// 诊断工具：dump usage / tool-result source+meta / user source 的完整字段形状。
// 用法：dart run tool\dump_usage_detail.dart <sessionId> [dshBase]
import 'dart:convert';

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
  var usageShown = 0, metaShown = 0, srcShown = 0;
  for (final r in records) {
    final e = Map<String, dynamic>.from(r['event'] as Map? ?? {});
    final type = '${e['type']}';
    final data = Map<String, dynamic>.from(e['data'] as Map? ?? {});
    if (type == 'assistant/message' && usageShown < 2 && data['usage'] != null) {
      usageShown++;
      print('assistant usage: ${jsonEncode(data['usage'])}');
    }
    if (type == 'tool/result' && srcShown < 2) {
      final msg = Map<String, dynamic>.from(data['message'] as Map? ?? {});
      print('tool/result message.source: ${jsonEncode(msg['source'])}');
      srcShown++;
    }
    if (type == 'tool/result' && data['meta'] != null && metaShown < 3) {
      metaShown++;
      print('tool/result meta: ${jsonEncode(data['meta'])}');
    }
    if (type == 'user/message' && data['source'] != null) {
      print('user source: ${jsonEncode(data['source'])}');
      break;
    }
  }
  mux.close();
}
