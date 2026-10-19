# Local Only Startup Network Gate

## Problem

用户要求 App 启动至真正进入 Timeline 前零网络请求，包括并发请求。仅取消 await 或推迟 Cognito 的一处调用不够：当前身份查询会刷新 token/JWKS，恢复可能自动获取 catalog、snapshot、E2EE key，attachment、前台事件和资源 demand 也能触发网络。现有 feed-loaded 回调不证明 Timeline 已出现。

基准为 main 49520f0da203033152f69b071eba11ffa89f131b。工作分支 codex/local-only-startup-20261019 位于本任务独立克隆，不使用 N 状态工作区。

## Proposal

启动默认进入 Local_only 阶段。只读取本地账号绑定、绑定账号及 origin 对应的 catalog、mirror、overlay/outbox、所需本地密钥和本地首批 feed。保留绑定格式、账号、origin、graph 身份、密钥、ownership 和数据库校验，禁止把过期 token 当作在线凭据。

状态所有者为 Sync pure reducer：分别表达本地访问与在线认证。只有经过合法本地绑定和当前 graph scope 的成功 attachment 才授予本地访问；authenticated 继续只表示成功的在线身份结果。网络门槛默认关闭，foreground、认证通知、队列重试和 asset demand 均不能自行打开。

复用 LUI 已有原生 appearance 事件，在实际 Timeline 根视图出现时回传带 account/graph/presentation generation 的 ticket。首批 feed 完成、构造视图、提交 patch 均不能自行代替此事件。空但有效的 Journal 也通过实际 Timeline 根视图出现确认，不依赖存在内容行。

接受当前有效 appearance 后才允许身份/token 刷新。身份成功后可靠启动远端 catalog、WebSocket、initial sync 和资源需求；刷新失败保留已授权的本地 Timeline，通过现有同步/账号状态显示离线或需重新登录。不同账号或 graph、取消、退出以及重复 appearance 的陈旧结果不得解除新启动门槛。

首次启动没有可恢复数据时必须停止 loading，不制造空白 graph：

| 本地结果 | 明确界面状态 | 后续操作 |
| --- | --- | --- |
| 无合法账号绑定、格式损坏或 origin 不符 | 需要登录/账号不可用 | 复用现有登录入口；用户明确操作后才进入单独在线流程 |
| 无可用本地 catalog 或选中项 | 本地 graph 信息不可用/需要获取 graph 列表 | 有缓存目录则展示现有 graph picker；获取远端目录须现有刷新入口的明确操作 |
| mirror 不存在 | 此 graph 未下载 | 复用现有恢复入口，明确标为下载；点击后才允许正常认证和 snapshot 流程 |
| 所需本地密钥缺失或验证失败 | 本地密钥不可用，需要联网恢复 | 复用现有恢复入口；不得启动时自动取远端 key |
| DB、outbox、ownership 或本地 IO 失败 | 本地恢复失败，保留具体脱敏原因 | 复用重试/选择 graph；不删除或替换真实 graph |

本方案不新增独立交互，不自动打开浏览器或下载。显式登录/刷新/下载属于用户主动的在线流程，使用同一网络门槛的独立授权原因，不能把自动启动路径伪装成用户请求。

用户已明确授权修改的受保护接口限定为 logseq_sync/spec/pure_reducer/core.mli：

- startup_facts（当前第 27-38 行）：增加本地访问结果/不可恢复原因，使 UI 不必把 authenticated 设为 true 才能展示本地内容。
- event（当前第 517-534 行）：将无 scope 的 Timeline_presented 改为具有当前账号/graph/presentation 身份的呈现事件，并表达显式在线流程许可，使陈旧事件不能打开网络。
- 相应 .ml 实现按正常产品授权修改；不修改其他 spec 文件和任何 dune 文件。如再发现需要其他受保护接口，先报告具体位置。

其他已知修改范围为 app/journal_startup(.ml/.mli)、app/application.ml、app/journal_platform(.ml/.mli)、LUI service 的普通 .ml/.mli、Swift 原生平台/账号/呈现桥及现有测试文件。使用现有 appearance 能力，不新增布局/滚动协调或修改 LUI 仓库。

## Alternatives considered

### 仅延后 currentUserID

不能阻止远端 catalog、WebSocket、asset、snapshot/key 的并行网络请求，不满足零请求。

### 将 authenticated 在本地恢复时直接设为 true

会混淆本地访问和在线认证，可能提前发送过期 token 或掩盖账号变化，不采用。

### 无本地数据时自动在线补齐

违反最新要求。本方案显示准确不可用状态，后续在线行为只由明确用户动作发起。

## Acceptance criteria

- 按 TDD 先写全部必要的失败测试，确认因现有行为而失败，再实现和复跑。
- 在 public pure reducer 边界验证阶段、合法 scope、本地不足时退出 loading、无网络指令、首屏后的同步恢复以及陈旧结果无效。
- 仅在 pure 边界不能覆盖的原生/transport 边界加入记录型或拒绝型 fake，实际计数 Cognito token/JWKS、catalog、snapshot/key、WebSocket、asset 网络调用；首屏出现前所有计数严格为零。
- 覆盖有效、临近过期和过期 token；成功刷新、离线/失败；首 feed 完成但视图尚未出现；空 Journal；首次启动/缓存缺失；账号/graph 切换、取消和重复回调。
- 首屏出现后刷新失败不会清除合法本地首屏；成功后同步可可靠启动。显式登录/下载仍要求正常认证。
- 不修改网络地址/超时配置，完成实际 Simulator 验收及独立审查后提 PR，不 merge；只在已协调的 Simulator 安装独立 bundle，不修改真实 graph。

## Risks

- 当前受保护接口没有表达本地访问与 scoped 呈现的能力；已获明确接口授权，仍不得通过旁路状态或伪造认证绕过。
- 本地不可恢复的冷启动行为从自动联网改为明确停留；上表已获用户批准。
- 使用既有只读 prepared switch、独立外部 build-dir 与 -j1，不更改共享依赖。原生产物与最终代码对应，Simulator 构建的 ABI 限制见验证记录。

## Decision

用户已在主对话明确批准此前展示的本地启动方案及具体 .mli diff，并要求实施后按真实 UI 可达流程进行 Simulator 实测、独立 review、提 PR、不 merge。批准由主任务以 transcript_evidence 传递。

## Validation plan

先完成 RED 测试，再实现 GREEN。Simulator 使用已由 N 状态 owner 释放的 1446A493-492B-4F2D-974D-3AED9DA5C97B；保留其既有 bundle/容器，以独立 bundle 和全新可重建合成目录验收。A135 和真机均不操作。

真实 UI 验收矩阵：有本地 graph 的关闭重启；正常空 Timeline；现有会话令牌正常到期后的刷新；离线本地使用；无本地账号的登录入口；缓存目录中未下载 graph 的下载入口；正常后台/前台及选择 graph。记录实际原生 appearance 和各 transport 网络调用的有序计数，首屏前必须为零。单元回归覆盖边界，不能代替上述实测。

## Additional interface decision approved

Independent review found that existing `Cancel_effects` also zeroizes graph keys. Using it to cancel only online startup would destroy a retained local key while leaving its Core handle available. Existing graph retirement must retain this behavior.

The smallest proposed additional protected interface change is in `logseq_sync/spec/pure_reducer/core.mli`, in `runner_effect`:

```diff
   | Cancel_effects of effect_scope
+  | Cancel_network_effects of effect_scope
```

Its interpreter would cancel only network operations matching the scope, and retire matching sockets, without clearing graph key bytes or local DB/crypto/file operations. Scope retirement continues to use `Cancel_effects`. The user explicitly approved this exact extension with “允许”, as relayed by the parent task with transcript evidence on 2026-10-19. No other protected file or Dune change is proposed. Implementation keeps the local graph scope, key handles and local completion chain; cancels only actual network work, network retry timers and sockets; and fences native authentication transport tasks separately from stored account identity. Independent review also required a network guard on deferred catalog reconciliation, explicit internal tracking of delegated snapshot activation, and classification of staged asset publication and wrapped-key unlock as local work.

## Implementation

Sync Core owns local access, scoped native appearance permission and explicit online permission. Local attachment no longer requires online authentication. Missing local account/catalog/mirror/key and failed attachment terminate local startup with finite outcomes. Worker inspect-mirror, attach and inspect-sync failures now deliver scoped Graph_attachment_failed rather than only publishing a Diagnostic.

The runner cancels network tasks, retry timers and sockets using Cancel_network_effects while preserving local key bytes, wrapped-key/private-key unlock, delegated snapshot activation and local staged asset publication. Deferred catalog reconciliation obeys the same gate. Native Cognito transport cancellation uses a network generation and cancels owned refresh/sign-in/JWKS tasks without replacing persisted account identity.

The actual Timeline root appearance carries account, graph and presentation generations. Both App and native owners immediately revoke cancelled scopes and reject late permissions. App retains critical startup commands under bounded-worker backpressure; a newer authentication identity supersedes queued older identities whether its new dispatch is Accepted or Full. Service reconciliation reasserts its latest observed SDK identity so latest-value deduplication cannot leave Core unauthenticated after local reset.

The protected changes are confined to the explicitly approved Sync core.mli. No Dune or other spec file was changed. PR96 remains separate; only its offered synthetic RSA test issuer fixture is reused, with an additional local cancellation regression. Its final 900326be3009b39103cd6fb8ed5d8f5396d0a765 reporting hunks were compared during independent review.

## Validation

All changes followed RED/GREEN at the state owner or narrowest actual boundary. Complete dune runtest passes with the prepared read-only switch and external build directory. Targeted Sync 294, Worker Core 19, Worker runner 25, App 123, native platform wire 12 and native event 5 cases pass; service regression, source-boundary validation, native authentication/services and Cognito 8 groups pass. Transport cases use real synthetic localhost TCP/TLS/HTTP/WebSocket peers. Cognito uses a temporary generated RSA issuer and injected transport; production signature verification remains exercised.

Final independent journal-code-review reports no new definite defects and confirms the PR96 overlap boundaries. git diff --check passes. spec-dev-tool --help was attempted but the executable is unavailable in this environment; no tool was installed and no automated decision-schema validation is claimed.

The final production OCaml object and current Swift sources were built with the maintained journal-build entry point and installed only as org.logseq.journal.local-startup-probe on the explicitly loaned 1446 Simulator. Complete main-compatible synthetic DB/WAL/SHM packages were created using public Storage APIs while the connection was quiescent and copied to new directories. The N branch's custom-status fixture was not used as evidence of main behavior: main correctly rejected its unsupported custom status. Neither existing app/container nor any real graph or session store was modified.

Observed through real production JournalHost UI and ordered test-adapter counters:

- Encrypted local Journal renders while authentication is false. Initial Timeline appearance precedes every identity/token call; first postappearance failure still leaves readable local rows and a visible account error.
- Graph picker switches to a second retained local graph; normal Home/foreground and process close/relaunch preserve its local content.
- Valid empty Journal shows No journal entries and emits the same actual root appearance without requiring a content row.
- Missing local key shows a finite recovery page with no identity/token/sign-in calls; choosing another locally keyed graph renders its Journal before authentication.
- Missing mirror shows Download graph, with all authentication counters zero before the click. Download explicitly opens the online path; injected offline token failure returns a finite Retry result.
- Missing catalog shows the existing empty graph picker and explicit Refresh graphs; authentication begins only after Refresh and failure is visible.
- Missing local account shows the actual native sign-in sheet with zero SDK calls. Continue to sign in produces a visible injected offline error; Close then Sign in again and a second Continue produces a second sign-in request, confirming retry permission is acknowledged.

Evidence includes final producer/import manifests, console logs, per-case ordered JSONL counters and screenshots in the task's external local-startup evidence directory. The inherited acceptance host's static status caption is not the verdict: after switching from missing-key graph 1 to valid graph 2 its old caption says FAIL because the optional test-control acknowledgement was not pressed; actual production UI, scope events and counters establish the successful graph switch.

Simulator uses experimental host-restamp, with target-native C/Swift and strict signing checks; its manifest explicitly retains cross_abi_validated=false. This validates the scoped synthetic UI path, not a production iOS cross-compiled binary or device release. No actual remote Cognito login, successful real server synchronization, OS-wide network outage, real account token expiry, phone acceptance or managed-sync server E2E is claimed. Reducer/native/transport regressions cover those deterministic phase and expiry boundaries without using real credentials.

## Consequences

Startup local access and remote authentication now have distinct authority. Valid local data can be read before network access; absent local data requires an explicit user online action. Network cancellation retains local state and keys, while account/graph retirement keeps full cancellation and key zeroization.

PR96 error visibility changes must retain this branch's scoped typed restore failure completions and startup mapping when integrated. No automatic local-copy deletion or retry policy is introduced.

## Questions

None in the authorized implementation scope. Additional production iOS ABI/device and real-server success acceptance remain separate validation limits, not evidence supplied by the synthetic host.
