# Embedded provider support

The SDK already contained DeepSeek balance and Kimi/GLM coding-plan polling
implementations. `AgentRunner` does not start them. `ProviderAccountClient`
is the public, stateless interface for hosts that need an explicit refresh:

```dart
final snapshot = await const ProviderAccountClient().fetch(
  provider: config, apiKey: keyFromHostSecureStorage,
);
// CreditBalance: cash amounts by currency.
// CodingPlanUsage: check hasIntervalWindow / hasWeeklyWindow before displaying.
```

The client reuses the provider response parsers, uses the configured origin,
rejects credential-bearing URLs, disables redirects, caps response size, and
has a total timeout. It returns sanitized `AccountQueryError` codes, never raw
response bodies. Hosts must authorize the endpoint and key combination; do not
send proxy credentials to a separate official host. No keys or snapshots are
persisted. Missing quota windows are unavailable, not depleted or duplicated.

Supported account queries: DeepSeek `/user/balance` (Bearer), Kimi
`<base>/usages` (Bearer), GLM `/api/monitor/usage/quota/limit` (raw key).
The Kimi/GLM endpoints reuse Crux's existing integrations and are not promised
as stable public billing contracts. Handle unavailable/auth/schema failures.
OpenAI API billing is unsupported here; request token counts and ChatGPT/Codex
subscription limits are different metrics.

`openai` is an explicit official API provider, separate from `codex` and the
existing third-party `openai_compatible` provider. It omits `thinking` and
`user_id`; GPT-5/o-series omit sampling parameters. `off` selects provider
default for these reasoning models, since disabling reasoning is not universal.
The host should offer only supported efforts for its selected model.

`deepseek_chat` uses Chat Completions, including `max_tokens`, `thinking`,
and current low/high/max effort. Existing `deepseek` retains Responses API
behavior to preserve compatibility. `AgentRunner` accepts `temperature`, `topP`
and `maxTokens`, including on its round-cap reporting request.

Kimi preserves the official `k3-256k` ID, retains legacy `k3-1m` mapping,
forwards the output cap, and sends an honest SDK User-Agent. K3.1 Pro rejects
thinking-off locally. Fixed Kimi sampling follows the existing Crux adapter.
No provider account or membership entitlements are assumed.

Official references checked 2026-11-05:

- https://api-docs.deepseek.com/api/create-chat-completion/
- https://api-docs.deepseek.com/api/get-user-balance/
- https://www.kimi.com/code/docs/kimi-code/models
- https://www.kimi.com/code/docs/en/
- https://docs.bigmodel.cn/cn/coding-plan/latest-model
- https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create

Validation: `dart analyze`, `dart run test/sdk_test.dart`, and
`dart run test/provider_accounts_test.dart`. Tests use local fixtures and
synthetic keys; live provider accounts are not exercised.
