import 'dart:async';

import 'package:flutter/material.dart';

import '../dsh/dsh_client.dart';
import '../dsh/discovery.dart';
import '../dsh/profiles.dart';
import '../dsh/qr_payload.dart';
import '../dsh/transport.dart';
import 'scan_page.dart';

/// 连接设置页：环境（Profile）卡片流 + 双模式四入网方式。
///
///  - 局域网直连：自动发现（mDNS）/ 手输 ip:port / 安全码 / 扫码（dshlan://）
///  - 云端转发：扫码自动配对（dshrelay://）/ 手输 ip:端口+令牌或配对码
///
/// 设备令牌（转发模式长效凭证）存 flutter_secure_storage，按环境隔离；
/// 同一台手机可同时持有「家里」「公司」等多个环境，一键切换。
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
  List<EnvProfile> _profiles = [];
  String? _activeId;
  bool _busy = false;
  String? _error;

  /// launch token 不持久化（短时效）：连接前按需临时填
  final _launchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _launchCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final list = await ProfileStore.load();
    final active = await ProfileStore.activeId();
    if (!mounted) return;
    setState(() {
      _profiles = list;
      _activeId = active ?? (list.isNotEmpty ? list.first.id : null);
    });
  }

  Future<void> _saveAll() async {
    await ProfileStore.save(_profiles);
    await _reload();
  }

  // ---------------- 连接 ----------------
  Future<void> _connect(EnvProfile p) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final DshTransport transport;
      final String modeLabel;
      if (!p.isRelay) {
        var raw = p.url.trim().replaceFirst(RegExp(r'/+$'), '');
        if (raw.isEmpty) throw TransportException('input/empty', '请填写服务地址');
        transport = DirectTransport(Uri.parse(raw));
        modeLabel = '直连 · ${p.name}';
      } else {
        if (p.relay.trim().isEmpty) throw TransportException('input/empty', '请填写 relay 地址');
        final savedToken = await ProfileStore.tokenOf(p.id) ?? '';
        final relay = RelayTransport(
          Uri.parse(p.relay.trim()),
          code: p.roomCode.trim(),
          deviceId: p.deviceId,
          token: savedToken,
          pairingCode: p.pairingCode.trim(),
          name: p.name,
          onPaired: (id, tok) async {
            // 首配成功：设备身份落安全存储（下次令牌重连）
            p.deviceId = id;
            p.pairingCode = '';
            await ProfileStore.saveToken(p.id, tok);
          },
        );
        await relay.connect();
        transport = relay;
        modeLabel = '云端转发 · ${p.name}';
      }

      final client = DshClient(transport);
      final launch = _launchCtrl.text.trim();
      if (launch.isNotEmpty) await client.authorize(launch);
      await client.sessionList(); // 连通性自检

      p.lastConnectedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      p.lastError = '';
      await ProfileStore.save(_profiles);
      await ProfileStore.setActive(p.id);
      await widget.onConnected(transport: transport, client: client, modeLabel: modeLabel);
    } catch (e) {
      final msg = e is TransportException ? _friendlyError(e) : '$e';
      p.lastError = msg;
      await ProfileStore.save(_profiles);
      setState(() => _error = msg);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 传输错误 → 人话（配对成功但桥不在线等非鉴权场景不算「失败」）
  String _friendlyError(TransportException e) {
    switch (e.code) {
      case 'peer-offline':
        return '已连上中继，但桌面端不在线（手机通道/桥未运行）：请打开桌面 dsh 后重试';
      case 'relay/closed':
      case 'relay/not-connected':
        return '与中继的连接已断开：请重新连接';
      default:
        return e.message.isNotEmpty ? e.message : '$e';
    }
  }

  // ---------------- 扫码 ----------------
  Future<void> _scan() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ScanPage()),
    );
    if (raw == null) return;
    await _applyPayload(raw);
  }

  /// 扫码/粘贴共用：解析入网码 → 建环境 → 立即连接（配对码 10 分钟有效，即扫即销）
  Future<void> _applyPayload(String raw) async {
    final t = parseQrPayload(raw);
    if (t == null) {
      setState(() => _error = '无法识别的二维码（需 dshrelay:// 或 dshlan:// 入网码）');
      return;
    }
    final p = EnvProfile(
      id: 'env-${DateTime.now().millisecondsSinceEpoch}',
      name: t.name.isNotEmpty ? t.name : (t.relay ? '云端环境' : '局域网设备'),
      mode: t.relay ? 1 : 0,
      relay: t.relay ? t.addr : 'ws://127.0.0.1:8787',
      roomCode: t.room,
      pairingCode: t.pairCode,
      url: t.relay ? 'http://127.0.0.1:3080' : t.addr,
      lanCode: t.lanCode,
    );
    _profiles.add(p);
    await _saveAll();
    setState(() => _activeId = p.id);
    await _connect(p);
  }

  // ---------------- 局域网发现 ----------------
  Future<void> _discover() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => const _DiscoverSheet(),
    );
    await _reload();
  }

  // ---------------- 编辑 ----------------
  Future<void> _edit([EnvProfile? p]) async {
    final created = await showModalBottomSheet<EnvProfile>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _EditSheet(initial: p),
    );
    if (created == null) return;
    if (p == null) {
      _profiles.add(created);
    } else {
      final i = _profiles.indexWhere((e) => e.id == p.id);
      if (i >= 0) _profiles[i] = created;
    }
    await _saveAll();
    if (p == null && mounted) setState(() => _activeId = created.id);
  }

  Future<void> _delete(EnvProfile p) async {
    _profiles.removeWhere((e) => e.id == p.id);
    await ProfileStore.clearToken(p.id);
    await _saveAll();
  }

  Future<void> _repair(EnvProfile p) async {
    // 重新配对：清设备身份与令牌，等价于回到「未配对」态
    p.deviceId = '';
    p.pairingCode = '';
    await ProfileStore.clearToken(p.id);
    await _saveAll();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已清除设备身份，请扫码或填新配对码重新配对')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.menu), onPressed: widget.onOpenDrawer),
        title: const Text('连接设置'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _scan,
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: '扫码入网',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _scan,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('扫码入网'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _discover,
                  icon: const Icon(Icons.radar),
                  label: const Text('局域网发现'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _launchCtrl,
            decoration: const InputDecoration(
              labelText: 'launch token（可选）',
              hintText: 'dsh web 启动 URL 里 ?token= 的值',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            obscureText: true,
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('环境', style: Theme.of(context).textTheme.titleMedium),
              TextButton.icon(
                onPressed: _busy ? null : () => _edit(),
                icon: const Icon(Icons.add),
                label: const Text('新建'),
              ),
            ],
          ),
          if (_profiles.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  '暂无环境。点「扫码入网」扫桌面生成的二维码，\n或「新建」手动填写。',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
          for (final p in _profiles) _profileCard(p, scheme),
          const SizedBox(height: 12),
          TextField(
            decoration: const InputDecoration(
              labelText: '粘贴 payload 入网（扫码不可用时）',
              hintText: 'dshrelay://... 或 dshlan://...',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: _busy ? null : (raw) => _applyPayload(raw),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: scheme.error)),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _profileCard(EnvProfile p, ColorScheme scheme) {
    final active = p.id == _activeId;
    return Card(
      elevation: active ? 2 : 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: active ? scheme.primary : scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(p.isRelay ? Icons.cloud_outlined : Icons.lan, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(p.name, style: Theme.of(context).textTheme.titleSmall),
                ),
                if (p.isRelay)
                  Chip(
                    label: Text(p.paired ? '已配对' : '未配对', style: const TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    labelPadding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              p.isRelay
                  ? '${p.relay}${p.roomCode.isNotEmpty ? ' · 房间 ${p.roomCode}' : ''}'
                  : '${p.url}${p.lanCode.isNotEmpty ? ' · 有安全码' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (p.lastError.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(p.lastError, style: TextStyle(fontSize: 12, color: scheme.error)),
              ),
            Row(
              children: [
                TextButton(
                  onPressed: _busy ? null : () => _connect(p),
                  child: const Text('连接'),
                ),
                TextButton(onPressed: _busy ? null : () => _edit(p), child: const Text('编辑')),
                if (p.isRelay && p.paired)
                  TextButton(onPressed: _busy ? null : () => _repair(p), child: const Text('重新配对')),
                const Spacer(),
                IconButton(
                  onPressed: _busy ? null : () => _delete(p),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  tooltip: '删除环境',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 环境编辑表单（新建/编辑统一）
class _EditSheet extends StatefulWidget {
  final EnvProfile? initial;
  const _EditSheet({this.initial});

  @override
  State<_EditSheet> createState() => _EditSheetState();
}

class _EditSheetState extends State<_EditSheet> {
  late int _mode;
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _lanCode;
  late final TextEditingController _relay;
  late final TextEditingController _roomCode;
  late final TextEditingController _pair;
  late final TextEditingController _deviceId;
  late final TextEditingController _token;

  @override
  void initState() {
    super.initState();
    final p = widget.initial;
    _mode = p?.mode ?? 1;
    _name = TextEditingController(text: p?.name ?? '');
    _url = TextEditingController(text: p?.url ?? 'http://127.0.0.1:3080');
    _lanCode = TextEditingController(text: p?.lanCode ?? '');
    _relay = TextEditingController(text: p?.relay ?? 'ws://127.0.0.1:8787');
    _roomCode = TextEditingController(text: p?.roomCode ?? '');
    _pair = TextEditingController(text: p?.pairingCode ?? '');
    _deviceId = TextEditingController(text: p?.deviceId ?? '');
    _token = TextEditingController();
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _lanCode.dispose();
    _relay.dispose();
    _roomCode.dispose();
    _pair.dispose();
    _deviceId.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final p = widget.initial ??
        EnvProfile(id: 'env-${DateTime.now().millisecondsSinceEpoch}', name: '');
    p.name = _name.text.trim().isEmpty ? (p.name.isEmpty ? '新环境' : p.name) : _name.text.trim();
    p.mode = _mode;
    p.url = _url.text.trim();
    p.lanCode = _lanCode.text.trim();
    p.relay = _relay.text.trim();
    p.roomCode = _roomCode.text.trim();
    p.pairingCode = _pair.text.trim();
    // 手填设备身份：令牌只进安全存储；身份变更/清空即视为重新配对
    final devId = _deviceId.text.trim();
    if (devId != p.deviceId) {
      if (devId.isEmpty) {
        await ProfileStore.clearToken(p.id);
      }
      p.deviceId = devId;
    }
    final tok = _token.text.trim();
    if (tok.isNotEmpty) {
      await ProfileStore.saveToken(p.id, tok);
    }
    if (mounted) Navigator.of(context).pop(p);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 8,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.initial == null ? '新建环境' : '编辑环境',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: '环境名',
                hintText: '家里 / 公司 …',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, icon: Icon(Icons.lan), label: Text('局域网')),
                ButtonSegment(value: 1, icon: Icon(Icons.cloud_outlined), label: Text('转发')),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            const SizedBox(height: 12),
            if (_mode == 0) ...[
              TextField(
                controller: _url,
                decoration: const InputDecoration(
                  labelText: '服务地址',
                  hintText: 'http://192.168.1.10:3080',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _lanCode,
                decoration: const InputDecoration(
                  labelText: '安全码（可选，按桌面 dsh 配置）',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ] else ...[
              TextField(
                controller: _relay,
                decoration: const InputDecoration(
                  labelText: 'relay 地址',
                  hintText: 'wss://your-vps:8787',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _roomCode,
                decoration: const InputDecoration(
                  labelText: '房间码（寻址，可选）',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _pair,
                decoration: const InputDecoration(
                  labelText: '配对码（首次配对，XXXX-XXXX）',
                  hintText: '管理台/桌面生成的一次性码',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _deviceId,
                decoration: const InputDecoration(
                  labelText: '设备 ID（可选，已有配对时手填）',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _token,
                decoration: const InputDecoration(
                  labelText: '设备令牌（可选，手填即入安全存储）',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                obscureText: true,
              ),
              const SizedBox(height: 8),
              Text(
                '已配对环境留空配对码即可（走设备令牌重连）；'
                '被吊销/换机时填新配对码重新配对。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: _submit, child: const Text('保存')),
            ),
          ],
        ),
      ),
    );
  }
}

/// 局域网发现弹层：mDNS 扫描 `_dsh._tcp`，点选生成局域网环境。
class _DiscoverSheet extends StatefulWidget {
  const _DiscoverSheet();

  @override
  State<_DiscoverSheet> createState() => _DiscoverSheetState();
}

class _DiscoverSheetState extends State<_DiscoverSheet> {
  StreamSubscription<LanService>? _sub;
  final _found = <LanService>[];
  String? _err;

  @override
  void initState() {
    super.initState();
    _sub = discoverLanServices().listen(
      (s) {
        if (!mounted) return;
        setState(() => _found.add(s));
      },
      onError: (Object e) {
        if (mounted) setState(() => _err = '$e');
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _pick(LanService s) async {
    final store = await ProfileStore.load();
    store.add(EnvProfile(
      id: 'env-${DateTime.now().millisecondsSinceEpoch}',
      name: s.name,
      mode: 0,
      url: s.url,
    ));
    await ProfileStore.save(store);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('局域网发现中…', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('_dsh._tcp 服务广播（桌面 dsh 在同一 Wi-Fi 下）',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          if (_err != null) Text('发现失败：$_err', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (_found.isEmpty && _err == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          for (final s in _found)
            ListTile(
              leading: const Icon(Icons.computer),
              title: Text(s.name),
              subtitle: Text('${s.host}:${s.port}'),
              trailing: const Icon(Icons.add),
              onTap: () => _pick(s),
            ),
        ],
      ),
    );
  }
}
