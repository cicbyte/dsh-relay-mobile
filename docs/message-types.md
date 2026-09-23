# 消息类型覆盖矩阵（手机端 vs dsh session 事件词表）

词表来源：`@deepseek-ai/dsh-session` 的 `KNOWN_SESSION_EVENT_TYPES`
（56 种，含插件 declaration-merge 扩展；生成物，随 dsh 构建更新）。
手机端：`lib/pages/session_page.dart` 的 `_buildItems`（对话）与
`trajectory_page.dart`（轨迹）。

## 已正确处理（对话流内有专属渲染）

| 事件 | 手机渲染 | 备注 |
|---|---|---|
| `user/message`（source.kind=user） | 「你」气泡 | Markdown + 复制 |
| `user/message`（source.kind≠user） | 「注入 · kind」灰行 | 合成注入（文件变动/skill/cron/续轮）不再冒充「你」；notice 用 summary |
| `assistant/message` | 助手气泡 | text=Markdown、reasoning=折叠、image=图、tool-call 块跳过（与事件双重表示）、interrupted/usage |
| `tool/call` + `tool/result` | 工具卡片 | callId 配对（缺配 FIFO 兜底），错误高亮 |
| `turn/start` | 轮分隔 | 「— 第 N 轮 · HH:MM:SS —」 |
| `system/message` | 斜体灰字 | |
| `todo/write` | **任务清单卡** | ✓/◐/○ 三态 + 完成划线（计划/执行进度） |
| `approval/asked` | **授权询问行** | 工具名 + reason（等待授权） |
| `approval/decided` | **授权结果行** | 允许一次/拒绝/取消/不可用，按结果着色 |
| `plan/mode` | 计划模式行 | 开启/关闭 |
| `subagent/descriptor` | 子agent 行 | 一次性/可续聊 + provider |
| `tool-workflow/run-start` | **后台任务行** | name + runId |
| `tool-workflow/agent-start/end` | 后台成员行 | #seq · label/phase · outcome |
| `tool-workflow/run-end` | 后台任务结束 | stopReason |
| `command/run` | 命令行 | /name args |
| `command/done` | 仅错误渲染 | 成功不打扰 |
| `compaction/start/summary` | 上下文压缩行 | summary 带压缩 token 数 |
| `compaction/end` | 仅错误渲染 | |
| `goal/change` | 目标行 | objective / clear |
| `deliverables/presented` | 交付物行 | 文件数 + 路径 |
| `session/title` | **实时更新标题** | 无气泡（不占对话流） |
| `model/selection` / `agent-preset/selected` / `sandbox/mode` | 状态小行 | |
| 未知且 `ignorable` | 过滤 | 服务端噪声标记 |

## 明确不渲染（协议内部噪声，无用户可见语义）

`step/*`、`turn/end`、`request/*`、`assistant/attempt`、`llm/retry*`、
`hook/*`、`feedback/*`、`session/end-seed`、`session/title-llm-request`、
`session-log-deepseek/*`、`subagent/catalog`、`subagent/model-selection-policy`、
`approval/policy`、`permission/preset`、`schedule/change`、`team/*`、`web/*`、
`tool/ptc-dispatch*`。

## 展示 ✓ / 交互 ✓（#782 已实现手机作答）

| 能力 | 展示 | 手机上操作 | 说明 |
|---|---|---|---|
| 授权询问（approval） | ✓ 询问+结果行 | ✓ | 待答时作答区**替代输入框**：允许一次/拒绝；或「留给网页端」 |
| ask_user 提问 | ✓ 问题卡（选项瓷砖/自由填/回答药丸） | ✓ | 作答区替代输入框：选项点选（多选）、自由填、逐题跳过、批量提交 |
| todo 清单 | ✓ 清单卡 | ✗ | `todo/write` 为只读快照（写侧是 agent 的 todo 工具） |
| 子agent | ✓ 节点行 + 目录/进入/中断/发消息 | ✓ | 已有（subagents/list、prompt、interrupt） |

### 交互协议（`$events` Remote 事件流）

host Cordis waterfall（`user-questions/request` / `approval/request`）经
`dsh-api-gateway` 派发到所有客户端；手机侧 `lib/dsh/interactions.dart`：

- 下行流端点 `$events`（args 必须为空对象）：首帧 `{type:'ready', clientId}`，
  随后 `{type:'waterfall', event, eventId, agentId, request}` /
  `{type:'cancel', eventId}`；连接时服务端补投 pending，断线无需对账。
- 上行一元 RPC `$events/result`，args=`{clientId, eventId, outcome}`：
  `{kind:'result', value}` 应答 / `{kind:'next'}` 转交下一监听者（网页端）/
  `{kind:'rejected', error}` 拒绝。
- 询问应答批次 `{answers:[{id, selected[], custom?}]}`：跳过=`{id,selected:[]}`；
  单选+自由填时 selected 清空。授权应答值 = `'allowed-once'` / `'rejected'`。
- 注意字段双拼：工具参数侧 `multi_select`，waterfall 请求侧 `multiSelect`。

## 词表更新机制

dsh 升级后跑一次对照：`KNOWN_SESSION_EVENT_TYPES`
（`node_modules/@deepseek-ai/dsh-session/lib/types/known-event-types.js`）
对手机端 `session_page.dart` 的 switch 逐项核对；未知且非 ignorable 的
事件会出现在轨迹页（轨迹页对未知类型保留原始 type 文本）。
