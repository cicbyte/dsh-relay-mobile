# dsh-mobile

DSH 的 Flutter 移动端客户端（Android 优先），通过 DSH 服务端协议远程查看/操作 DSH 会话。

## 功能

- 抽屉外壳布局（参考 ZCode mobile / Cherry Studio 范式）：侧边栏 = 会话列表直达 + 连接状态行 + 入口行，主区 = 对话视图
- 两种连接模式：
  - **局域网直连**：手机直达 dsh web（adb reverse / 同 Wi-Fi + trustedHosts）
  - **云端转发**：relay（Rust，公网 VPS）→ 桌面桥 → 本机 dsh web，不在局域网也能用（见 `relay/README.md`）。桌面桥已插件化：`relay/dsh-plugin-mobile-bridge/` 装进 dsh profile（cordis bundle）随 dsh 启停，配置走 `$DSH_HOME/mobile-bridge.json`
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
