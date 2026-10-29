# Crux Agent SDK

从 [marsup-space/crux](https://github.com/marsup-space/crux) 提取的可嵌入 Dart Agent 核心。当前版本 `0.1.0`，纯 Dart IO package，无 Flutter、鸿蒙、HDC、SQLite 或终端 UI 依赖。

## 已提取

- 模型 Provider 配置、统一流式通信、UTF-8/SSE 解析及错误分类。
- `AgentRunner` 单 Agent 循环：完整收集工具参数、调用宿主注入的工具、把结果交回模型继续回答。
- `initialHistory` 支持宿主传入稳定的多轮消息前缀；`onChunk` 输出增量，`onHistory` 提供中间历史，`onDone` 返回终态与最终文本。
- 显式取消、超时、轮数上限，以及从 Crux 保留的上下文压缩与蒸馏代码。
- `ToolDef` / `ToolContext` / `ToolResult` 工具契约；Provider 和凭据由宿主注入。

SDK 不读应用配置、不保存用户会话、不自带文件或手机工具，也不包含 Crux 桌面 UI、完整 subagent 调度器与长期记忆系统。上下文压缩代码已保留，但此版本没有宣称完成长会话质量或服务器缓存命中验收。普通轮次的请求前缀稳定性由本地 HTTP fixture 验证。

## 接入

```yaml
dependencies:
  crux_agent_sdk:
    path: third_party/crux_agent_sdk
```

入口为 `package:crux_agent_sdk/crux_agent_sdk.dart`。可运行的普通对话例子见 [example/chat.dart](example/chat.dart)。环境变量 `DEEPSEEK_API_KEY` 由调用者自行配置；示例不保存凭据。

```sh
dart pub get
dart analyze
dart run test/sdk_test.dart
dart run example/chat.dart '你好'
```

多轮对话由宿主保存消息列表，下一轮以 `system + 已完成历史 + 新 user 消息` 传入 `initialHistory`。宿主在 `onDone('completed', text)` 后追加最终 assistant 消息，避免与 `onChunk` 逐字消息重复。取消和失败的部分输出应保留展示并注明状态，不作为已完成的 assistant 答复重放。

工具通过继承 `ToolDef` 提供 JSON schema 和 `execute`。宿主负责工具权限、工作区边界、持久化与崩溃恢复；SDK 不会因模型提出工具名而扩大可调用工具集合。`beforeExecute` / `afterExecute` 可用于持久化 intent/result。

## 验证范围

`test/sdk_test.dart` 不访问外网，覆盖真实 HTTP/SSE 解析、中文帧分片、write → read → 回答、稳定请求前缀、无效参数不执行、HTTP 错误、取消及未知工具拒绝。HarmonyAI 中另有持久化普通聊天与真机验证；这些平台适配不属于本仓库。

当前运行时需要 Dart VM 的 `dart:io`，不支持直接编译为浏览器应用。代码中保留的多 Provider 分支不代表每个 Provider 都已用真实账号验证。

## 来源与许可

上游固定版本：`3028f1b0da01ad11207f13e70bae68360acdecce`。保留原始 [MIT LICENSE](LICENSE)，逐文件上游及本地摘要记录于 [UPSTREAM.json](UPSTREAM.json)。本地适配包括移除桌面依赖、引入宿主接口、流式取消/UTF-8 修正、通用提示词以及已有会话前缀注入。

本仓库为独立提取版本，不是上游 Crux 的官方 SDK。
