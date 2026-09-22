import 'dart:convert';
import 'dart:io';

/// 复现手机端 RelayTransport.connect() 的握手路径。
Future<void> main() async {
  try {
    final ws = await WebSocket.connect(
      'ws://127.0.0.1:8787',
      protocols: const ['dsh-relay-v1'],
    );
    print('CONNECTED ok');
    ws.add(jsonEncode({'type': 'hello', 'role': 'client', 'code': 'test-code-123456'}));
    ws.listen(
      (d) {
        print('FRAME: $d');
        exit(0);
      },
      onDone: () {
        print('DONE (closed)');
        exit(1);
      },
      onError: (e) {
        print('ERR: $e');
        exit(1);
      },
    );
    await Future.delayed(const Duration(seconds: 5));
    print('TIMEOUT no welcome');
    exit(1);
  } catch (e, st) {
    print('CONNECT FAILED: $e\n$st');
    exit(1);
  }
}
