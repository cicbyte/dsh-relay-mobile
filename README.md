# dsh-mobile

DSH 的 Flutter 移动端客户端（Android 优先），通过 DSH 服务端协议远程查看/操作 DSH 会话。

## 功能

- 抽屉外壳布局（参考 ZCode mobile / Cherry Studio 范式）：侧边栏 = 会话列表直达 + 连接状态行 + 入口行，主区 = 对话视图
- 两种连接模式：
  - **局域网直连**：手机直达 dsh web（adb reverse / 同 Wi-Fi + trustedHosts）
  - **云端转发**：relay（Rust，公网 VPS）→ 桌面桥 → 本机 dsh web，不在局域网也能用（协议与自测见 [`../dsh-relay-service/README.md`](../dsh-relay-service/README.md)）。桌面桥已插件化：[`../dsh-relay-plugin/`](../dsh-relay-plugin) 装进 dsh profile（cordis bundle）随 dsh 启停，配置走设置页「手机通道」或兜底 `$DSH_HOME/mobile-bridge.json`
- 会话列表：`session/list`（标题来自 projections、running 状态、cwd、时间）
- 会话详情：`session/follow` 快照 + 事件渲染（用户/助手消息气泡、工具调用卡片、turn 分隔）、
  `session/prompt` 发消息、`session/cancel` 停止当前轮、`session/page` 历史翻页
- **GFM Markdown 渲染**（`flutter_markdown_plus`）：标题/加粗/行内与围栏代码/列表/任务列表/
  引用/表格/链接/分割线，暗色主题定制；链接点击复制到剪贴板
- **工具调用展示**（扁平排版，无卡片背景）：tool/call 与 tool/result 按 callId 精确配对
  （source.callId 优先，FIFO 兜底），单行 ✓/✗/spinner 状态 + 名称 + 参数摘要 + 用时，
  点击展开缩进看时间/耗时、JSON 美化参数与结果（均可复制）；reasoning 思考折叠行；
  消息行带时间戳、token 用量（↑输入 ↓输出）与复制按钮；step/* 等协议噪声事件静默；
  ignorable 噪声过滤；消息内图片/文件块渲染
- subagent 会话支持：`SessionAddress = {kind:'subagent', parentSessionId, childSessionId, mode}`
  （mode 在 one-shot / continuable 间自动兜底）；「子agent」面板走 `subagents/list` 目录
  进入子会话，continuable 子代理可发消息（`subagents/prompt`）/中断（`subagents/interruptByParent`）
- **附件下载（下载池模型）**：手机只能下载「下载池」内文件——工作区池
  `<会话cwd>/.dsh-download` + 全局池 `$DSH_HOME/.dsh-download`（无 cwd 会话只有全局池）；
  「＋」从磁盘选文件**复制入池**（原文件保留，同名自动加后缀），池内点选生成
  设备绑定链接（默认 30min/上限 7 天）→ 流式下载或复制路径；池内副本可删。
  下载支持**双路 Range 断点续传**：断线重下从本地断点接着写（隧道 meta 帧带
  status 判定 206 追加/200 覆盖/416 已完整/≥400 失败不挂死），大文件不进内存。
  下载完成后可一键**保存到系统下载**（平台通道 `dsh/device`：Android 10+ 走
  MediaStore 免权限 + IS_PENDING 防半成品，旧版本回退公共 Downloads 目录）。
  安全边界在桥端：`dl-create` 对池外路径一律 403，绕过手机 UI 也下不了任意磁盘文件
- **对齐 web 版功能点**：「深度求索中…」运行态指示（秒级计时）；「轨迹」视图
  （全部事件按轮分组时间线 + 搜索 + JSON 展开，含 step/ 审计事件）
- 连接层：`lib/dsh/transport.dart`（直连/转发两种传输可插拔）+ `lib/dsh/dsh_client.dart`
  （token→cookie 鉴权、`client-request` RPC 封套、`/api/remote.mux` 多路复用流、
  单飞自动重连 + 自动重订阅）
- 时区修复：`session/prompt` 的 `clientTimeZone` 只收 IANA 名（Dart 的 timeZoneName
  是 CST 缩写会被 `session/invalid-time-zone` 拒），经平台通道取
  `TimeZone.getDefault().id`（`lib/device_info.dart`）

## 运行 / 调试（MuMu 模拟器）

```powershell
# 1. 连接 MuMu（MuMu 12 默认 adb 端口 16416）
adb connect 127.0.0.1:16416
# 2. 端口转发：手机上的 127.0.0.1:3080 → 宿主机 DSH web
#    （dsh web 拒绝 --host 0.0.0.0，必须走 adb reverse 保证 Host=loopback 过信任栅栏）
adb -s 127.0.0.1:16416 reverse tcp:3080 tcp:3080
# 3. 构建安装
flutter build apk --debug
adb -s 127.0.0.1:16416 install -r build\app\outputs\flutter-apk\app-debug.apk
adb -s 127.0.0.1:16416 shell am start -n com.cicbyte.dsh_mobile/.MainActivity
```

App 内保持默认 `http://127.0.0.1:3080` 直接点「连接」即可。

## 协议要点（调试备忘）

- 一元 RPC：`POST /api/<ns>/<method>`，封套 `{"type":"client-request","rpcId","method","payload":{"args":{...}}}`；
  wire 参数名严格（`session/list` 用 `_request`，其余多用 `request`）
- 流式：`ws://host/api/remote.mux`，帧 `open/cancel`（上行）`item/error/end`（下行）
- **心跳**：服务端每 2s 发 WS Ping，连续 2 次未回 Pong 即 `terminate()`
  （`dsh-api-gateway` `MAX_MISSED_HEARTBEATS=2`）。dart:io 自动回 Pong，
  但主 isolate 被大快照阻塞会延迟应答——`session/follow` 的 `maxMessages` 不宜过大
- 构建环境：Gradle wrapper 已从 9.3.1 切 9.5.0（9.3.1 存在 kotlin-dsl 访问器生成 bug）

## 环境（Profile）与配对（调试备忘）

- **一切皆环境**：局域网直连（url+安全码）与云端转发（relay+房间+配对/令牌）统一为
  `EnvProfile` 卡片流，多环境并存一键切换；列表存 SharedPreferences，**设备令牌存
  flutter_secure_storage**（Keystore/Keychain，键 `dev.token.<profileId>`）。
- **hello v2 纪律**：带 `deviceId+token` 或 `pairingCode` 时**必须省略 `code`**（服务端把
  `code` 哈希当房间主张，混用误报 `room-mismatch`）；`code` 仅旧共享码模式。
- 配对成功 `welcome.device` 回发一次性令牌 → 立即落盘 + 清 profile 里的配对码；
  此后重连走令牌。**鉴权类拒绝（revoked/bad-token/pairing-* 等）停止自动重连**
  （`isAuthReject` + `_authFailed` 制动，治 1/s 风暴），UI 展示人话文案引导重新配对。
- 扫码入网 payload（`qr_payload.dart`）：`dshrelay://host:port/?pair=&room=&name=` /
  `dshlan://ip:port/?code=&name=`；相机（mobile_scanner）+ 相册识别 + 粘贴兜底。
- 局域网发现（`discovery.dart`）：nsd/mDNS `_dsh._tcp`，12s 扫描窗口点选建环境。
