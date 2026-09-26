import 'package:flutter/material.dart';

import '../dsh/conn_store.dart';
import '../dsh/dsh_client.dart';
import '../dsh/transport.dart';

/// 连接设置页：两种连接模式。
///
///  1. 局域网直连 —— 手机可直达 dsh web（含 adb reverse / 同一 Wi-Fi + trustedHosts）。
///  2. 云端转发 —— 连 relay（dsh-relay-v1），经桌面桥(bridge.mjs)透明隧道访问 dsh web；
///     不依赖局域网，出门在外可用（生产部署 relay 应置于 wss:// 后）。
class ConnectPage extends StatefulWidget {
  /// 连接成功回调（transport 所有权移交给 AppRoot）。
  final Future<void> Function({
    required DshTransport transport,
    required DshClient client,
    required String modeLabel,
  }) onConnected;
  final VoidCallback onOpenDrawer;

  const ConnectPage({super.key, required this.onConnected, required this.onOpenDrawer});

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  int _mode = 0; // 0=局域网直连 1=云端转发
  bool _busy = false;
  String? _error;

  final _urlCtrl = TextEditingController(text: 'http://127.0.0.1:3080');
  final _tokenCtrl = TextEditingController();
  final _relayCtrl = TextEditingController(text: 'ws://127.0.0.1:8787');
  final _codeCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    // 回填上次的连接配置（持久化，免每次手配）。
    ConnStore.loadConfig().then((c) {
      if (c == null || !mounted) return;
      setState(() {
        _mode = c.mode;
        _urlCtrl.text = c.url;
        _relayCtrl.text = c.relay;
        _codeCtrl.text = c.code;
      });
    });
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    _relayCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final DshTransport transport;
      final String modeLabel;
      if (_mode == 0) {
        var raw = _urlCtrl.text.trim().replaceFirst(RegExp(r'/+$'), '');
        if (raw.isEmpty) throw TransportException('input/empty', '请填写服务地址');
        transport = DirectTransport(Uri.parse(raw));
        modeLabel = '直连 · $raw';
      } else {
        final relayRaw = _relayCtrl.text.trim();
        final code = _codeCtrl.text.trim();
        if (relayRaw.isEmpty) throw TransportException('input/empty', '请填写 relay 地址');
        if (code.length < 6) throw TransportException('input/empty', '配对码至少 6 位（需与桌面桥一致）');
        final relay = RelayTransport(Uri.parse(relayRaw), code: code);
        await relay.connect();
        transport = relay;
        modeLabel = '云端转发 · $relayRaw';
      }

      final client = DshClient(transport);
      // token 可选：loopback / 桌面桥场景信任栅栏直接放行；
      // 启用 cookie 校验时填入 dsh web 打印的 launch token 换 cookie。
      final token = _tokenCtrl.text.trim();
      if (token.isNotEmpty) await client.authorize(token);
      await client.sessionList(); // 连通性自检
      // 连接成功即持久化（launch token 不存——短时效）。
      await ConnStore.saveConfig(ConnConfig(
        mode: _mode,
        url: _urlCtrl.text.trim().replaceFirst(RegExp(r'/+$'), ''),
        relay: _relayCtrl.text.trim(),
        code: _codeCtrl.text.trim(),
      ));
      await widget.onConnected(transport: transport, client: client, modeLabel: modeLabel);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.menu), onPressed: widget.onOpenDrawer),
        title: const Text('连接设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, icon: Icon(Icons.lan), label: Text('局域网直连')),
              ButtonSegment(value: 1, icon: Icon(Icons.cloud_outlined), label: Text('云端转发')),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
          const SizedBox(height: 20),
          if (_mode == 0) ...[
            TextField(
              controller: _urlCtrl,
              decoration: const InputDecoration(
                labelText: '服务地址',
                hintText: 'http://127.0.0.1:3080',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            Text('MuMu 模拟器：先 adb reverse tcp:3080 tcp:3080，保持默认地址即可。',
                style: Theme.of(context).textTheme.bodySmall),
          ] else ...[
            TextField(
              controller: _relayCtrl,
              decoration: const InputDecoration(
                labelText: 'relay 地址',
                hintText: 'wss://your-vps:8787',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _codeCtrl,
              decoration: const InputDecoration(
                labelText: '配对码',
                hintText: '与桌面桥 RELAY_CODE 一致',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Text('桌面机运行 node bridge.mjs 并保持在线；relay 只做转发，生产环境务必 wss。',
                style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _tokenCtrl,
            decoration: const InputDecoration(
              labelText: 'launch token（可选）',
              hintText: 'dsh web 启动 URL 里 ?token= 的值',
              border: OutlineInputBorder(),
            ),
            obscureText: true,
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _connect,
            child: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('连接'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
    );
  }
}
