// 诊断工具：dump 指定会话 follow 快照里 tool/call、tool/result、assistant tool-call 的
// callId 形状，供工具卡配对逻辑验证。
// 用法：dart run tool\dump_tool_callids.dart <sessionId> [dshBase]
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
  print('records=${records.length}');
  for (final r in records) {
    final e = Map<String, dynamic>.from(r['event'] as Map? ?? {});
    final type = '${e['type']}';
    final data = Map<String, dynamic>.from(e['data'] as Map? ?? {});
    if (type == 'tool/call') {
      print('tool/call   seq=${e['seq']} callId=[${data['callId']}] name=${data['name']}');
    } else if (type == 'tool/result') {
      final msg = Map<String, dynamic>.from(data['message'] as Map? ?? {});
      for (final b in msg['content'] as List? ?? []) {
        if (b is Map && b['type'] == 'tool-result') {
          print('tool/result seq=${e['seq']} dataCallId=[${data['callId']}] blkCallId=[${b['callId']}] isError=${b['isError']}');
        }
      }
    } else if (type == 'assistant/message') {
      final msg = Map<String, dynamic>.from(data['message'] as Map? ?? {});
      for (final b in msg['content'] as List? ?? []) {
        if (b is Map && b['type'] == 'tool-call') {
          print('asst/tool-call seq=${e['seq']} blkCallId=[${b['callId']}] name=${b['name']}');
        }
      }
    }
  }
  mux.close();
}
