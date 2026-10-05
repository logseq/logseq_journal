# Journal UI Supported Boundaries（支持范围决策与实施）

## Problem

Journal 已完成 LUI、局部媒体订阅与 typed native NavigationStack 迁移，但适配层仍保留无人构造的 UI 能力、旧媒体协议、同一事实的重复状态，以及 Undo 全历史协调。成本不只是行数，还包括 OCaml/Swift/Flutter 合同维护、重复发布与隐式 owner 路由。

本文件的一个主决策是：**以实际产品消费者为 UI 支持边界，分阶段收窄适配与状态来源；合同取舍、正确性修复和机械删除分别验收。** C1–C11 对应原 review S1–S11，C12 补足子报告中的输入翻译重复；A0 单列 Timeline action 正确性先决项。使用 architecture 类，因为环境 wire/static 接口含支持范围取舍，不能把所有项都当行为保持的 simplification。小清理纳入用户要求的完整 inventory，不为每个小项另造 decision。

用户已于 2026-10-04（Asia/Shanghai）回答 Questions：**“1B, 2A, 3A”**，随后明确要求“等上面附件相关问题fix完之后，开始执行这个doc”。附件 final clean c0e14e11 与独立复审通过后，已按 proposed 开始分阶段本地实施/验证/本地提交；原初不授权 push/PR/merge 或手机安装；2026-10-04 用户随后要求“journal的所有事情完成后提个pr”，已授权完成此批验证后统一推送并向 main 提一个 draft PR、跟踪 CI，不授权 merge 或手机安装。原探索和答案记录保留为基线证据，后续实施记录与 Git 外验证报告分离。

### 固定版本、消费者与来源

日期为 Asia/Shanghai **2026-10-04**。在独立 `clone --no-hardlinks` 副本安全 fetch `origin main`，固定基线 [Journal main / PR44 merge](https://github.com/logseq/logseq_journal/commit/953f71b5852b5ffd094bf75a040e46656ab8a1c9)：`953f71b5852b5ffd094bf75a040e46656ab8a1c9`，tree `ac3d58e48ee8a555284150f6082a287b435b296f`。原 review head `6d63f869dd5b8dffb4f310e66664304d334dae9b` 与此同树。所有下列源码链接固定 merge SHA，不使用会变动的 main。独立 branch 为 `docs/ui-boundary-exploration-2026-10-04`，未复制/编辑原 repo 的未跟踪文档。

原始证据：[完整 UI review](/Users/rcmerci/Documents/Codex/2026-10-03/task-8/journal-ui-review.md)、[wrapper](/Users/rcmerci/Documents/Codex/2026-10-03/task-8/view-review.md)、[list](/Users/rcmerci/Documents/Codex/2026-10-03/task-8/list-review.md)、[media](/Users/rcmerci/Documents/Codex/2026-10-03/task-8/media-review.md)、[native](/Users/rcmerci/Documents/Codex/2026-10-03/task-8/native-review.md)、[媒体闪烁诊断](/Users/rcmerci/Documents/Codex/2026-10-03/task-8/media-flicker-diagnosis.md)。这些是本机 Git 外报告，不是已提交附件；其它机器需取得原证据。本文件重核源码树、消费者和规范，复用原诊断并标明限制，探索阶段没有重新运行原实验或声称新 UI PASS；后续新版本验收独立记录。

原 review/native 的 LUI 基线为 `67ea3e8a9787cd80b1106a11a2504a6735f96d30`；当时看到的 main `1db993d4e2eaa2ec844620e374c736829798a2d0` 不是其 native 输入。探索阶段没有 fetch/升级 LUI；实施阶段已隔离解析 main（见实施记录）。实施按 [composer integration](../../../development/composer-integration.md) 解析一致的 OCaml/LUI/Apple package，记录完整 SHA/ABI，不混用新 backend 和旧实验。

生产入口 [native_embed](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/native_embed.ml#L1) → `Application.native_hooks` → Application/LUI/C → Apple；固定审查基线的 Flutter 也使用同一 Journal 协议，Q1=B 已决定其后续退役。检索包括 app/test/review、registration/schema/fingerprint、wire 字符串与 kind 映射。测试/static fixture 是实际消费者，不能按“非生产”便删除。[app library](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/dune#L1) 无 `public_name`，Journal_view 不是公开安装 widget 包，但 `.mli`、host wire、测试仍是成套合同。未找到受支持的外部 Journal_view/journal-media mount；这是仓库证据边界，不证明所有外部源码不存在。实施发现真实受支持消费者须补证据、暂停相应删除，不私加 fallback。

排除 worker/storage/sync 内部算法、认证/加密、generated/vendor、`spec/` OCaml、bonsai_flutter OCaml 编辑。Dune 原为保护边界；2026-10-04 用户另行明确“允许”仅删除 `test/dune` 的 11 项退休 Flutter 依赖，其他 Dune 不改。iOS 主产品、macOS 基本测试支持已由 [UX guidelines](../../../ux-guidelines.md) 明确，不重复问；Q1=B 已确定退役 Flutter iOS/Android/macOS hosts，后续支持集合仅 Apple iOS 主产品与 macOS 基础支持。Flutter 源码链接保留为固定基线的退休证据，不代表继续支持。

### 规范、已有决策与独立媒体修复

遵循 [AGENTS](../../../../AGENTS.md) 和 `spec-dev-tool --help` / `guide find-simplifications` / lifecycle workflow。仓库无 `docs/agent_doc_format.md`，customization 是空模板；active schema baseline 与 proposed testing 文档不拥有本 UI 范围。已读取相关 `.agents/skills` 的 simulator/testing 约束，未来原生 Release 验收先协调独立 Simulator/GUI owner，不安装手机。

- [LUI migration](../../implemented/architecture/2026-09-23-replace-bonsai-ui-with-lui.md) 与 [supported UI cutover](../../implemented/architecture/2026-09-18-replace-supported-ui-with-bonsai-ui.md)：单 renderer、原子切换，无旧 transport/fallback。历史 decision 保留历史身份。
- [bottom capsules](../../implemented/feature/2026-09-28-bottom-lui-capsules.md)：底部已移到 shared buttons/native inset。
- [UI update boundaries](../../implemented/architecture/2026-10-03-journal-ui-update-boundaries.md)、[targeted media](../../implemented/architecture/2026-10-03-journal-targeted-media-subscriptions.md)、[native navigation](../../implemented/architecture/2026-10-03-journal-native-navigation-stack.md)：局部订阅、prepared List snapshot、root/entry 保留有测量依据；snapshot 明确为 static/test 保留，C7 必须先改消费者。
- composer integration 与 [rapid input 既有修复](../../rejected/bugfix/2026-09-05-accept-rapid-controlled-text-input-edits.md)：collapse 保留 draft/picker，Discard 使 request generation 失效；session/revision/IME 防护保留。
- [session Undo/Redo deferred](../../rejected/feature/2026-09-17-session-delete-history-contract.md)：C11 只优化现有 timed Delete cancellation，不新增永久 history/Redo/database inverse。

**探索阶段媒体闪烁在另一任务独立修复；本文件未覆盖或假定其结果。实施阶段现已消费该任务的 clean c0e14e11 与独立复审（见实施记录）。** 旧基线诊断确认 route 变化清空可见 media roots，managed PNG/PDF 公共 Runtime 经 File→Hidden→Waiting→Opening→File。原生 PNG 使用 programmatic UIKit pop，List 身份/offset 保留但自然 Back 无新 demand/acquire、持续 Waiting；显式 appearance 因果控制才恢复，不是自然 Back PASS。PDF 无同版完整 native Back，截图采样不是 FPS。旧 journal-media 无 mount，C5 不是当前 flicker 根因或修复。

媒体相关 C7/C8 实施前须读取独立修复 final SHA/diff/owner 说明，重核 covered/active/disposed 行为，不能从旧基线覆盖修复；未完成时可推进 C1–C6 独立清理，不借旧实验宣布新版本通过。

## Decision

按已答 Q1=B、Q2=A、Q3=A 落地 C1–C12，并先完成 A0 共享 mounted action 正确性边界；保留 Apple iOS 主产品与 macOS 基础支持，退役全部 Flutter hosts，static fixtures 原子改为独立 seeded Store，Apple/OCaml 环境最终收窄为四个消费字段。消费独立媒体修复 clean c0e14e11，保留其 retained/preview/pressure/late completion owner 机制。产品最终冻结 e5803bd，Release 聚合与九项独立 Simulator 验收通过，具体输入及限制见实施记录。

实施不增加旧协议 fallback，不改变 protected spec，Dune 仅使用明确获准的 11 项退休依赖删除。后续单 Draft PR 按用户新增授权发布并跟踪 CI；不合并、不安装手机。历史 Proposal 与估计作为决策追溯保留，实际净 diff、验收证据及已知限制以下方实施记录为准。

## Proposal（历史范围与分阶段计划）

### 已确认的支持决定（2026-10-04）

用户原话为 **“1B, 2A, 3A”**，已核对原 Questions 的准确选项：

- **Q1=B：退役全部 Flutter hosts。** 保留 Apple iOS 主产品与 macOS 基础支持，不再要求 Flutter iOS/Android/macOS 可运行或跟随新协议。未来实施应盘点并移除仅服务退休 hosts 的入口、registry/profile、编码器、host 依赖/配置及测试/CI 义务；共享 OCaml/C/worker/platform 能力和 Apple 消费者必须保留。不能按目录整删，不能以退休名义删除仍验证保留产品行为的测试。Flutter 专属测试/CI 的去留须在后续实施清单逐项列明，仍有共同语义覆盖时先在保留 owner 边界保住覆盖。
- **Q2=A：允许 static/review/testing 媒体 source API 原子调整。** fixtures 改为 seed 独立 Store，保留其功能/隔离性，production 与 fixtures 使用同一个 presentation 来源；移除 root model 的 live media_views 镜像和旧 optional live fallback，不保留旧 snapshot 调用形状的兼容承诺。
- **Q3=A：环境 wire 收窄为四项。** 最终 OCaml/Apple 环境 payload 仅保留 platform、brightness、high_contrast、accessible_navigation 对应字段，移除其它旧 snapshot 字段及其专用探针/编解码；原生键盘、安全区、Dynamic Type 与辅助功能行为继续保留。删 probe 前核对诊断与布局消费者，此技术证明仍是验收前置，不是未答的用户选择。

保留 Apple hosts 与 OCaml 的合同原子切换；Flutter 完成退役后不再更新其新四字段编码器或新 fingerprint，不新增旧 17-field、旧媒体 2105、旧 static API 的 fallback/alias/migration。临时四项 projection 可以是过渡步骤，但不能当作 C9 最终完成；若 probe 还承担原生布局职责，保留该职责，暂停受影响删除并报告证据，不能自动改回未选的完整 snapshot 支持方案。

这些是已答且已授权分阶段本地实施的产品范围。未来盘点若发现 Flutter 退役涉及 Dune/protected spec，仍须按现有 AGENTS 的保护边界停止相关编辑并报告所需明确授权，实施仅使用用户另行授权的 `test/dune` 11 项依赖删除；其它 Dune 与 protected spec 未改。

### 分类、估计与依赖

数字均为**净删除估计，非已实现 diff、交付承诺或验收指标**；移入 helper/迁出 Decoder 不算净删。C1–C4 合计约 360–450 ml + 130–185 mli（约 490–635 行），C5 430–480，C6 25–45。其它项以减少状态来源/协调义务为价值，不累计成总配额。C5 的 430–480 是原三端旧扩展审查估计；探索时 Flutter 全 host 退役尚无实施 diff，额外范围未估算，其中旧 media renderer 的 311 行只能计一次，不与 C5 重复累加。

| 项目 | 处置 / 阶段 | 估计 | 前置条件 |
| --- | --- | --- | --- |
| C1 Button 第二份 menu mount | local / P1 | 20–25 ml | 无读取 |
| C2 Toolbar bottom/group/raw | behavior-preserving / P1 | 85–115 ml + 25–35 mli | top toolbar/capsules 保持 |
| C3 Menu/Picker 泛化 | behavior-preserving / P1 | 110–140 ml + 35–50 mli | flat Account/Inline status 保持 |
| C4 未使用控件家族 | behavior-preserving / P1 | 146 ml + 70–100 mli | actual editor/list 合同保留 |
| C5 旧 journal-media / Flutter host 退休闭环 | Apple behavior-preserving + 已决定的平台退休 / P2 | 旧扩展 430–480；host 额外范围未估 | Decoder、Apple/OCaml 原子 fingerprint、Q1=B |
| C6 offset/count | owner-local simplification / P1 | 25–45 | 全 mutation invariant |
| C7 media 双镜像 | 已选择 architecture refinement / P3 | 40–90 | Q2=A 独立 Store seed、媒体修复边界 |
| C8 内部 text/JSON action | architecture refinement / P4 | 40–100 | A0、媒体修复边界 |
| C9 环境 wire/probe | 已选择 architecture cutover / P5 | 原整退役估计 140–220 | Q1=B / Q3=A、诊断/布局证明 |
| C10 startup/旧 diagnostics | local / P1 或 P2 | 5–10 + 8–15 | producer/fixture 核对 |
| C11 Undo 全历史协调 | owner-local design / P3 | 10–25，可能持平 | C6、timed cancellation 语义 |
| C12 active input 去重复 | local / P1 | 12–20 | 每 mount revision 独立 |
| A0 Timeline row_event 断链 | correctness prerequisite / P0 | 不计收益 | public event 复现后独立 bugfix |

### C1：普通 Button 不再构造第二份 menu mount

- **现状/消费者：** [内部字段/element](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_view.ml#L22-L41)、[button 构造](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_view.ml#L793-L836) 仅声明/写入 `menu_item_mount`，全库无读取，abstract `.mli` 不暴露。真实 [Account Menu](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_header.ml#L153-L192) 走 Menu.action→buttons_menu_action，List 使用自己的 action records/JSON。
- **成本/范围：** 每 Button 额外保存 role/disabled/label/icon/press 的 menu closure。删字段、element 可选参数和第二份构造，保留真正 mount，约 20–25 ml。
- **护栏/替代：** 保留 label_content、toolbar icon-only accessibility、真实 Menu/List actions。保留字段能支持未来泛化，但目前没有消费者，持续双表示无收益。
- **影响/风险/依赖：** P1 首项，低风险，无 wire 变化；normal/destructive/disabled/cancel 行为保持。
- **验收/退出：** 全 app/test/review 编译，现有 Button 事件/patch、Account menu/top toolbar 测试保持；无读取内部字段无需新镜像实现测试。出现真实读取/不等价 mount 即暂停删除。

### C2：Toolbar 仅保留实际 top items

- **现状/消费者：** [实现](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_view.ml#L1235-L1500)、[接口](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_view.mli#L554-L586) 支持 Bottom_bar/group/spacer/raw_item/child；真实 [Toolbar.item](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/application.ml#L1456) 调用只用 Cancellation/Principal/Primary/Secondary。当前 [header page/bottom-controls](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_header.ml#L331-L383) 与 detail chrome 已走 capsules/inset。
- **成本/范围：** 去 spacing/is_group/raw flags、未用 constructors、bottom/raw mounts 与 partition/append；保留 key/placement/content/top mount。约 85–115 ml + 25–35 mli，不将整个 266 行模块算作删除。
- **护栏/替代：** 保留 top 40pt/icon-only labels、Graph picker/Unlock/Diagnostics/Close、NavigationStack/title/pop。泛化 API 方便未来扩展，但底部方案已被既有决策替代，不值得继续双轨。
- **影响/风险/依赖：** P1，低至中风险，`.ml/.mli` 成套收窄；不重新设计底部外观、不回退 native inset。
- **验收/退出：** 全消费者编译；principal/cancel/event 及 Journals/Favorites、Capture open/closed、Account/Error 组合；iOS/macOS 顶栏 smoke、native safe area 保持。发现 capsule 实际依赖旧通道则暂停，而非强删。

### C3：flat Account Menu 与 Inline status Picker

- **现状/消费者：** [Picker/Menu](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_view.ml#L2273-L2488)、[接口](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_view.mli#L871-L935) 维持 Choice/Divider/Section/Submenu、standalone trigger、Segmented raw radios。真实 [status sheet](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/application.ml#L1482-L1520) 固定 Inline；Account 只有 flat Action/shared buttons trigger，无退休 constructors 调用。
- **成本/范围：** 删递归词汇/trigger/generic forwarding、Segmented 分支，保留 keyed flat actions 与 radio_group；先不改现用 Picker 名称，避免额外 churn。约 110–140 ml + 35–50 mli。
- **护栏/替代：** 七个 status choices、selection/disabled/destructive/accessibility/stable keys、条件显示 Delete local graph copy 保留。完整通用 Menu/Picker 利于未来需求，但当前无层级/segmented 要求；不能把真实 menu 换成不合适的普通按钮。
- **影响/风险/依赖：** P1 在 C1/C2 后，低至中风险的 private exports/types 改动。
- **验收/退出：** 每 Account command、每 status option 选择/显示/禁用保持，现有 mount/semantics 通过；新真实层级需求或旧 constructor consumer 出现则重新定范围。

### C4：未调用控件/editor/layout/context 附着家族

- **现状/消费者：** [toggle/text_editor](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_view.ml#L838-L928)、[Body.Horizontal/Viewport.Horizontal/Scroll](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_view.ml#L1531-L1586)、[Context_menu.attach](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_view.ml#L1647-L1669) 无 production/test/review 调用；[input exports](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_view.mli#L409-L444)、[layout exports](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_view.mli#L612-L663)、[attach export](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_view.mli#L714) 是匹配合同。实际 composer/secure_field/Native_list context 是另外路径。
- **成本/范围：** 删除上述 definitions + exports，约 146 ml + 70–100 mli；shared enums/helpers 等最后消费者消失才删，horizontal alignment 不等于 horizontal viewport。
- **护栏/替代：** Text_editing.Range/Value、每 mount revision/session/IME/rejected completion/update_mode 和 List action records 保留。无调用 text_editor 不证明 active 输入 guard 无用。保留 migration parity 最保守，但没有当前产品消费者。
- **影响/风险/依赖：** P1 低风险；A0 独立处理 List event 链，删除 attach 不能冒充修复。
- **验收/退出：** 全消费者编译、现有 composer/password mount 与 public editor reducer tests；不能删除现有测试制造无消费者，发现 retained helper 仍使用就保留。

### C5：退役旧 journal-media 与 Flutter host 合同，保留 Apple 导入 Decoder

- **现状/消费者：** [OCaml identifier/schema/mount](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_lui_native.ml#L6-L141)、[接口](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_lui_native.mli#L13-L45)、[2105 mapping](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_view.ml#L2546)、[Apple registry](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/swift/JournalExtensions.swift#L83-L178)、[Flutter registry](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/flutter/lib/journal_extension_registry.dart#L75-L91) 仅注册/声明/旧 renderer，无生产 mount。现用 [L.file_image/文件卡](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_media_view.ml#L208-L296)、[file_preview](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_media_view.ml#L433-L443)。**[JournalAssetImport](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/swift/JournalAssetImport.swift#L24-L98) 真正使用 JournalMedia.imageTypes/JournalMediaDecoder.shared.load。**
- **成本/范围：** 删 [Swift Item/Properties/MediaItem/View](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/swift/JournalMedia.swift#L32-L130) 约 99 行、[Flutter renderer](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/flutter/lib/journal_media.dart#L1-L311) 与旧 schema/registry/child whitelist/fingerprint/kind/event mapping。按 Q1=B 将 Flutter registry/renderer 归入整个 host 退休清单，不为它适配新协议；同时清理 OCaml 中 Flutter 专属 profiles/注册义务，保留 Apple 所需组件。Decoder/type 判断迁成 Apple composer thumbnail helper，迁出代码不算净删。430–480 仅原旧扩展估计，host 退休额外范围另核且不重算，不能整删 JournalMedia.swift 或当前 OCaml media view。
- **护栏/替代：** pending thumbnail/cache/cancel/security-scoped URL、导入照片/文件移除、LUI image/file/gallery/preview/Retry/Next 保持。LUI loader 是 internal，不为合并 20 行另造桥。保留死 renderer 的最强历史理由是外部 host 支持；仓库未见此承诺，Q1=B 已选择退休 Flutter，旧 Flutter replace/reuse 漂移不再作为需维持的行为。共享业务与 Apple 使用的 import 测试继续保留。
- **影响/风险/依赖：** P2，Q1=B 已确定只保留 Apple iOS/macOS；Apple 与 OCaml fingerprint 同批原子切换，无旧 2105 fallback，也不要求旧 Flutter host 消费新协议。退休的入口/依赖/profile/CI 若残留会形成错误支持宣告；Apple 部分 rollout 或真实外部消费者仍有 registry 拒绝风险。此项与独立 flicker fix 不相互替代。
- **验收/退出：** Apple/OCaml compile/fingerprint/registry tests；photo/file pending decode/cancel/remove；Timeline/Detail 当前 image/file preview。逐项核对 Flutter 专属入口、profiles/registrations、依赖及测试/CI 不再要求运行退休 hosts，共享 owner/Apple coverage 保持；不以 Flutter test/analyze 通过作新支持目标。发现保留产品的真实外部 mount 就暂停相应协议删除、写清合同，不恢复 Flutter 支持或删 import 测试规避问题。

### C6：恒零 retained offset，count 从 slots 派生

- **现状/消费者：** [state/初始化](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_timeline_state.ml#L39-L76)、[demand 算术](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_timeline_state.ml#L471-L475)、[hydrate/reset](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_timeline_state.ml#L553-L567)、[getters](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_timeline_state.ml#L1201-L1202)、[接口](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_timeline_state.mli#L67-L68)、[Application visible range](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/application.ml#L4731-L4765)。offset 所有写入为 0，无 prefix eviction；[10k invariant](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/test/journal_timeline_state_test.ml#L434-L442) 验 retained==total/first==0。count 是 slots 数，含 headings/continuations，不只是 blocks。
- **成本/范围：** 去 offset state/算术与内部 getter 消费者；total_count 改为 `Rrbvec.length slots` 派生，保留实际 count getter。重核 append/delete/undo/hydrate/normalize 全 mutation invariant，不只凭一条测试。约 25–45 行。
- **护栏/替代：** generation/cursor/visible demand/prefetch/bounded reads、child-only/empty continuation、recovery/hidden days/scroll tokens 保留。为未来 eviction 留字段最保守，但未来需要独立产品/性能决策，本次不重启 eviction、不留恒零兼容 getter。
- **影响/风险/依赖：** P1 独立，低至中风险在 row-only native index→slot mapping，count 派生不能改变 day/block 语义。
- **验收/退出：** 10k/empty/child-only/stale retry/hydration/prepend/delete/undo/Back anchor exact reducer tests；若真实路径 count 与 slots 不同且有独立语义，暂停字段删除，不能改断言掩盖差异。

### C7：Store 单 presentation 来源，去根 model 双镜像

- **现状/消费者：** [state.media_views](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/application.ml#L220-L254)、[flush_media](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/application.ml#L3306-L3334) 同时更新 Store + immutable map。生产 [root](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/application.ml#L5686-L5690)/[Detail](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/application.ml#L5858) 总传 Store；[optional/static 分支](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_media_view.ml#L500-L670)、[For_testing](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/application.ml#L6325-L6383) 仍读 snapshot。targeted decision 明确保留它，不能称 mirror 无消费者。
- **成本/范围：** static/review fixture 创建 seed 独立 Store，必要 snapshot getter 从 Store 派生；删 root map/copy/equality/publication 与 optional live fallback，约 40–90。Runtime 仍拥有 demand/lease，Store 只是 projection/index，两者不是重复状态机。
- **护栏/替代：** scheduler/effect ordering、epoch/reset、per-root/item channel、shared asset rebinding、listener/Signal dispose、graph/stale lease guard 保留，不回退 global model/per-row scans。维持旧 static API 是已评估但未选的替代；Q2=A 允许原子改 source API，fixture 功能继续保留，采用独立 Store seed，最终不保留 root live mirror/optional fallback，不造第二个 live map。
- **影响/风险/依赖：** P3 的 Q2=A 已确认，仍等独立媒体修复 final owner review；中风险在 fixture seed/dispatch 后读取、covered/disposed。不得夹带新的 visibility/lease policy。
- **验收/退出：** existing mounted/review/static/For_testing 全部迁移到独立 Store seed，dispatch 后观察与 fixture 隔离性保持；旧 root live mirror 与 optional fallback 无消费者。same-root no-op、one-item Ready 只实际 channels、shared roots/gallery/file/topology token rebind、old graph/reset/dispose/remount/covered Back。若还需 model-wide publish 才刷新 image，迁移未完成不能去 mirror；修复冲突则冻结此阶段。

### C8：外部 wire 一次解码，内部 typed business action

- **现状/消费者：** [bind_action](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/application.ml#L1372)、[prefix/scoped media payload](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/application.ml#L1605-L1673)、[Detail scope](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/application.ml#L2430) 拼 prefix/offset/JSON；[scope decode](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/application.ml#L4578-L4623)、[dispatcher](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/application.ml#L4789-L5296) 再解析。约 500 行 handler 多数为必要业务，不能整体计删。
- **成本/范围：** Swift/C external wire 在已有边界一次严格 decode；内部 callbacks 捕获 typed action + graph/session/entry/request/asset identity，逐 family 迁移后删字符串拼接/parse，约 40–100。不能加 variant 后长期保留完整旧 router。
- **护栏/替代：** enabled/row path/generation、same-block multi-entry draft、retired native pop、covered-source media、discard/collapse、malformed event 拒绝保持。typed capability 执行时仍需 owner fence。集中 string helper 更保守，可小步迁移但仍有往返，不是最终双轨。
- **影响/风险/依赖：** P4 等 A0/shared owner、媒体 final boundary/必要 C7；中至高风险。internal type 化不自动改变外部 wire，若要改另列原子 cutover。
- **验收/退出：** 各 action 原效果序列、多 entry/stale graph/session/native pop/covered media/picker discard-collapse/Status-Delete/malformed external；任一 fence 丢失或需要长期双 router 即暂停缩小批次。

### C9：已选择四字段环境 wire，保留原生布局与辅助功能

- **现状/消费者：** [snapshot](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_environment.mli#L19-L37)、[codecs](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_environment.ml#L108-L204)、[Swift observer/probe](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/swift/JournalEnvironment.swift#L10-L269)、[Flutter snapshot](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/flutter/lib/main.dart#L390-L430)。核对为 **17 个顶层字段**（safeArea/keyboardInsets 各四分量），原 review“19 字段”计数不准确，不将此技术纠正变成用户问题。业务只读 [platform](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/application.ml#L5499)、[brightness/high_contrast](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/application.ml#L5880-L5881)、[accessible_navigation](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/application.ml#L5276)；其余仍由 codec/equality/fixture 消费，host 原生环境另有 owner。
- **成本/范围：** Q3=A 已选择最终四字段合同，Q1=B 限定新 wire 切换为 Apple/OCaml；删除仅报告旧 snapshot 的 geometry/keyboard/device/accessibility-extra probe/codecs/fixtures，Flutter 旧 encoder 随 host 退休，不更新为新四字段。约 140–220 为原整退役估计，须按 Apple 保留职责与 Flutter 重叠范围重核。仅四项 projection/通知可作过渡，但不是完成条件，无卡顿收益实测。
- **护栏/替代：** native keyboard avoidance/safeAreaInset/composer/Dynamic Type/VoiceOver/Reduce Motion 保留。先区分 probe 只报告还是影响 layout，零 OCaml read 不能证明功能不需要；不能新造 per-row geometry state。完整 snapshot 是已评估但未选的替代；Q3=A 不再承诺其旧字段，诊断消费者须在删除前核对并同步调整其合同，不用旧完整 payload fallback 保兼容。若 probe 同时负责原生布局，只删报告职责、保留布局 owner。
- **影响/风险/依赖：** P5 的 Q1=B/Q3=A 已确认，仍需 native composer policy/诊断消费者技术核对；中至高风险在 Apple/OCaml 混版本 decode 或诊断失效。四字段新合同原子发布，不承诺与旧 17-field 混版本兼容；不删整个 LJP2 平台通道。
- **验收/退出：** Apple/OCaml 四字段 encode/decode/equality、initial/reconnect、dark/highcontrast/VoiceOver/platform；canonical wire 不再 emit/require 其余旧字段，旧格式不保留 alias/fallback。native keyboard show/hide/interactive dismissal、safe area/rotation/Dynamic Type/Reduce Motion 保持，诊断 consumer 已核对并同步切换。仍有旧字段真实消费者/原生要求不满足时暂停受影响退休并报告技术证据，不自行恢复完整 snapshot 支持或自制 geometry 协调。

### C10：恒 true startup marker 与旧 diagnostic labels

- **现状/消费者：** [startup ref](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/application.ml#L3049-L3050)、[branch](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/application.ml#L4074)、[decode](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/application.ml#L6177-L6178) 从无 false 写。旧 [Phase/Startup presentation adapter](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/application.ml#L2142-L2155)、[diagnostic_rows](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/application.ml#L2261) 仍过滤旧 labels；current service 不再输出，tests 注入旧格式。
- **成本/范围：** 去 ref/恒分支 5–10 行；核对所有 current producers 后去旧 label adapter/旧格式专用 fixture 8–15 行，保留 diagnostic data/UI 合同，不重开 redesign、不加 legacy alias。
- **护栏/替代：** managed_sync_origin 比较隔离 account binding，Admission_refresh generation/inflight/pending/close-reopen、error ledger/notice/VoiceOver timers 保留。旧 label 过滤只有支持 mixed service 才值得留，仓库无此已知承诺，不重复询问一般 obsolete 清理授权。
- **影响/风险/依赖：** marker P1 低风险，diagnostics P2 按已确认 Q1=B 的 Apple/OCaml producer 清单重核；接口/tests 成套更新。
- **验收/退出：** warm/local restore、origin mismatch/account switch、current phase/info/error、admission stale close/reopen tests 保持；发现 current producer 仍输出则暂停并写明支持来源，不能删展示需求。

### C11：Undo 局部 footprint，避免全历史比较

- **现状/消费者：** [staged.before](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_timeline_state.ml#L56-L59) 是结构共享引用，**非深复制**。[stage](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_timeline_state.ml#L1049-L1085)/[undo](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_timeline_state.ml#L1108-L1150) 要保留期间编辑/分页；Undo restage before 后 fold 全历史，每项 exists 扫 current，另有 retained_keys mem/anchor search。源码约 O(N²)，本次未 benchmark。
- **成本/范围：** staging 记录实际 removed/hidden restore-set、day knowledge/邻接 stable anchors；Undo 在 current state 仅恢复 footprint，去 restage/full diff。允许一次 current index/遍历，不要求零遍历、不新增长期全局 index。约 10–25 行可能持平，价值是删一种协调义务。
- **护栏/替代：** 不直接赋 staged.before；保留 intervening edits/capture/pagination、hidden section/placeholder/sibling、pending fences/anchor，same key 已存在不重复插入/覆盖新内容。保守替代是在 Undo 一次建 key set，保留 before 但去二次扫描；需比较总概念/成本。不是 deferred session history/Redo。
- **影响/风险/依赖：** P3 等 C6，owner-local 中风险在 hidden-day footprint/anchor 已变；notice timeout/admission 语义不变。
- **验收/退出：** [exact slots/pending](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/test/journal_timeline_state_test.ml#L560-L604)、[512-row edit/insert](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/test/journal_timeline_state_test.ml#L1050-L1094)、[hidden placeholder/sibling](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/test/journal_timeline_state_test.ml#L1178-L1186)；10k 固定小 footprint 验工作量近线性非二次，不用脆弱 wall-clock 阈值。public owner 无法表达 ordering/footprint 时暂停说明缺口，不改 protected spec 迁就实现。

### C12：active text-event 去重复，revision 每 mount 独立

- **现状/消费者：** [composer](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_view.ml#L937-L984)、[secure_field](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_view.ml#L1058-L1102) 都在 mount 内创建 ref、递增 TextChanged revision、构造相同 Text_edit；Capture/Detail 与 E2EE password 实用。LUI 只带全文本，当前 selection 0/0/composing None 不等于 owner 合同无用。
- **成本/范围：** 窄 translation helper 取 session/document/accepted revision/on_edit，每 mount 创建独立 callback/ref；不合并 capture/password state、不 hoist shared ref。约净 12–20。
- **护栏/替代：** duplicate echo/base/session/saving guards、Unicode/IME 全值保留。两份代码最保守但后续易漂移，不为少行数造通用输入框架。
- **影响/风险/依赖：** P1 在 C4 后，低至中风险在 ref scope/stale captured owner；不改 native keyboard/submit/password 限制。
- **验收/退出：** public editor burst/old-equal base/stale session/future base/duplicate revision/Unicode/IME/saving、mounted composer/password events；同时 mount 不共享 revision。生命周期改变即停止去重复。

### A0：Timeline Status/Delete row_event 断链是正确性先决项

[collection action callbacks](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_native_collection.ml#L54-L99) → [serializer](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_view.ml#L1866-L1909) → [Swift emit](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/swift/JournalList.swift#L279-L284)，但 [Timeline vertical](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_native_collection.ml#L174-L180) 未传 on_row_event；[wrapper](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_view.ml#L2102-L2116) 只转发可选 handler。Detail [table/raw JSON adapter](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/application.ml#L2475-L2594) 是真实工作路径，**不能先删 Detail 补丁**。

建议另立 bugfix：wrapper 从自身 row/action records dispatch 实际 callbacks，让 Timeline/Detail 同 owner；保留 enabled/row path/disclosure/missing/retired action/entry fence。shared routing 完整覆盖后才去 Detail custom adapter。约 35 行 custom 可能换成 15–25 行 shared routing，不计本次行为保持收益。

探索时原 review 是完整静态链，新 public mount/event harness 被 frozen Signal ABI 不匹配挡住，当时无真实 Swift tap PASS。实施后已建立匹配依赖并运行实际 Release 验收，见实施记录。原验收计划为先尝试 public pure reducer；若 reducer 已正确、缺陷只在 mounted callback binding，则记录缺口，只测最窄 public extension-event 边界，不复制 router。验收 Timeline Status 打开对应 sheet、Delete 发 undoable notice、disabled/missing/retired 无效、Detail 无回归，再做 native context smoke。C8 等此 owner 明确；C11 不能因断链而删 cancellation 语义。

### 其余审查点与明确保留

[Semantics/help/text_selection](https://github.com/logseq/logseq_journal/blob/953f71b5852b5ffd094bf75a040e46656ab8a1c9/app/journal_view.ml#L738-L753) 部分接受 intent 却无 native 行为（help/text_selection identity、Semantics 主要只发 label）；password 还有被忽略选项。真实消费者存在，不能悄悄删除 accessibility/selection/limit 意图计收益。后续在 native 公共边界查清要求/差距，另立功能或正确性 decision，本文件不重开全 accessibility redesign，也不把技术调查交给用户。

保留 typed NavigationStack/root/entry、local dyn/selectors、prepared List snapshot/positions cache、scope/generation/admitted mutations、media lease/demand/version/checksum/stale acquire release、分页/visible demand/recovery、mounted import/session/revision/IME、gallery/preview/fixed slots、Effect thunk/pump/queue/notice timers。它们有真实消费者；转移至另一 map/router、whole-model 订阅、永不 Release 或减少 reserved slots 均非本次简化。

### 分阶段依赖与停止条件

1. **P0 合同/证据：** Q1=B/Q2=A/Q3=A 已答，按上述 Apple 支持集合、独立 Store 与四字段最终合同制定实施清单；A0 单独 public bugfix 证据。媒体修复 owner 独立，后续媒体阶段消费 final diff。protected spec 不清楚/不合理时按 AGENTS 停实施，报告精确接口，不改 spec/Dune。
2. **P1 机械批次：** C1→C4/C12、C2、C3；C6/startup marker 独立。每批 matching exports 删除后 compile/相关已有 tests；独立范围无需等媒体修复。
3. **P2 平台退休/保留合同：** C5/C10 旧 labels，先迁 Apple Decoder，盘点并闭合 Flutter-only 入口/依赖/profile/测试与 CI 退休范围；Apple/OCaml schema/fingerprint/fixtures 同批切换，不提交半套 wire，不维护退休 Flutter 的新协议。涉及保护文件须另获明确编辑授权。
4. **P3 单来源/Undo：** C7 按 Q2=A 原子迁移全部 static/review/testing API 与独立 seed，仍等媒体 final review；C11 等 C6；两项不共享新协调基础设施。
5. **P4 typed actions：** C8 等 A0，媒体 family 等 final owner/必要 C7，逐 family 迁移、最后消费者消失再删旧 router。
6. **P5 环境：** C9 按 Q3=A 实施 Apple/OCaml 四字段 cutover；先核对诊断/probe/native 布局职责，原子更新保留 hosts/codecs/fixtures。键盘/safe area 不通过则暂停受影响删除并保留原生职责，不把暂时存在旧 wire 当作最终验收，也不自行切换为 Q3=B。

每批按可观察行为/合同、实际净 diff 和 owner 数退出，不按估计行数退出。新真实 consumer、旧 guard 丢失、owner 无法复现、mixed ABI、独立修复冲突均停止受影响批次，无关范围可继续。本次按用户已明确授权推进分阶段本地 implementation/验证/提交，在后续统一 draft PR 授权前不推送；现完成当前批次后统一提交 draft PR 并跟踪 CI，不合并。

## Alternatives considered

### 保留完整 shim/旧 media/static 双轨

最强理由是稳定 source/wire/static fixture、为未来能力留空间。对明确支持合同合理，但对 C1–C6 无消费者支路意味着永久维护不存在能力的 exports/registry/fingerprint/双表示；C7/C9 已按 Q2=A/Q3=A 放弃旧 source 调用形状和完整 snapshot 的兼容承诺；fixture 功能及原生布局职责依然保留。继续双镜像或完整 wire 只能是未完成的技术过渡，不是已选最终方案。

### 全量 Journal_view 改 raw LUI

可能删更多 shim，却将 keys/labels/actions/editor scopes/platform choices 散到调用方，放大 churn，未证明总概念减少。逐个确证删除更可验收，仍使用标准 native/LUI 组件，不重造布局/滚动/动画。

### 合并所有状态、重放 snapshot、跳过 generation

whole-model media、Undo state=before、typed callback 无 fence 更短，却分别回退局部更新、丢 intervening edits、接受 retired owner，违反已有决策，拒绝。

### fallback/feature flag 分批 rollout

旧 2105、可选旧环境字段、新旧内部 router 双轨降低短期部署耦合，却保留本次要消除的支持义务。按已明确无兼容 transport 原子切换；发现实际外部承诺则重定范围，不暗加 fallback。Q1=B 已明确 Flutter host 退休产品决定，因此不再为其维护新协议；Apple iOS/macOS 与 OCaml 的原子切换/验收义务仍在。

## Acceptance criteria

### 本次文档完成条件

- C1–C12/A0、媒体独立边界、保留机制均记录，每项有固定 SHA source/consumer、范围、护栏、替代、风险/依赖、验收/退出。
- 原探索仅修改文档。Questions 已全部回答，实施已完成并转为 implemented，允许本地 source/test 变更与提交；继续保护其他 Dune/spec；后续用户已授权统一 draft PR、跟踪 CI，不 merge/手机安装，不上传 Git 外截图或报告。
- 新文档 schema、固定 SHA paths/line ranges、相对决策链接、whitespace 核对完成；全仓既有 fail 与新增 fail 分开报告。
- 交付路径、branch/status、三项已答记录与一致的决定/范围/验收；无新增待用户问题，不重复索取已答选择。

### 实施验收计划（原探索时未运行，结果见实施记录）

既有测试优先；新增回归按 AGENTS 找生产 state owner，先尝试 public pure events/completions/state/effects，能 reducer 复现只加 reducer test，不能跨 runner/persistence/UI 重复覆盖。不能复制 implementation、绕 `.mli`、删现有测试来满足新形状；必要回归先 RED 后修复 PASS。

| 阶段 | 最窄边界/预期 | 后续检查 |
| --- | --- | --- |
| P1 wrapper/input | 当前 buttons/menus/status/capsules/password/composer 事件/mount 保持，退休 API 无消费者 | `dune exec test/application_view_test.exe`、`dune exec test/journal_semantics_test.exe`、`dune exec test/journal_routes_test.exe` |
| C6/C11 Timeline | exact slots/count/anchor/pending/stale/hidden-day、Undo 保留 intervening changes；10k 工作量非二次 | `dune exec test/journal_timeline_state_test.exe` + 必要 public RED regression |
| P2 media | fingerprint 同一 registry，import Decoder、LUI image/file/gallery/preview 保持 | `dune exec test/journal_media_test.exe`、`dune exec test/journal_media_runtime_test.exe` + Apple registry/import；静态核对 Flutter-only 入口/profile/依赖/测试与 CI 退休闭环、共享覆盖保留 |
| A0/C8 action | actual public extension-event→callback→reducer、enabled/retired/entry fences、Detail 保持 | public Application + 必要最窄 mount event；native context smoke |
| C7 Store | static/review/testing API 原子迁移、各自 Store seed、无 root live mirror/optional fallback；one-item 只实际 channels、zero unrelated builders | targeted decision 的 mounted Application/Store/review fixtures、隔离性与 shared/topology/epoch/dispose，matched final-source probes |
| C9 environment | canonical 四字段 wire、initial/reconnect、诊断同步；native keyboard/safe area/rotation/accessibility 保持 | OCaml codec/Application、Apple environment/composer、必要 native smoke；Flutter 旧 encoder 已归退休清单 |

命令名称核对基线 test/dune，后续 harness 写明 public owner/真实依赖/执行输入，stub-only Apple link 不作 UI 验收。Apple/OCaml tests 与退休范围静态核对完成后按修改范围 `dune build @all`、`dune runtest`；Q1=B 后续不以 Flutter build/test/analyze 为保留产品验收，不保留只为运行退休 hosts 的 CI 要求。共享语义覆盖继续在现有保留 owner/Apple 测试中验收；最终 `git diff --check`、`spec-dev-tool check --all`。后续按实际 source 变更执行所列检查，重构建/原生验收需协调资源。

未来 native 验证按仓库 `.agents/skills` 协调独立设备/GUI owner，不操作用户 graph。区分 builders/notifications/patch/decode 与 body/layout/paint，不由 builder0 推断 FPS。frozen Signal ABI 不匹配则建立匹配 isolated dependencies，不换 CMI/改 CRC 混编。原 review PASS 不替代新 final-source 验收。

## Risks

- 无 production call 仍可能有外部 private consumer；保留 Apple 产品的真实消费者须查清，`.mli`/Apple/OCaml 成套切换。Q1=B 明确使 Flutter 入口不再受支持，迁出/退休漏项会造成错误发布或 CI 支持宣告；不提供 Flutter 兼容层，也不误删共享逻辑/测试。
- Q2=A 已允许原子改 static source API，Q3=A 已选择四字段环境；仍须保留 fixture 功能/隔离性及 native keyboard/accessibility，迁移漏项或未核对诊断会造成回归。实现授权已另行记录；C1–C6 的证据不授权删其它形似代码。
- A0 是正确性先决项，Detail adapter 留到 shared owner 覆盖；媒体修复的旧探索时无本文件验收结果，实施已消费 clean c0e14e11 并重新验收，仍不能覆盖其 owner policy。
- Undo before 结构共享本身低成本，错误 footprint/anchor 会损坏期间工作；以 exact public state/effects/工作量验证，不以行数/机器时间验证。
- generation/session/lease/分页/IME guard 具有真实生命周期；helper 迁移要保留每 mount ref scope。
- 零 OCaml geometry read 不证明 native 键盘/accessibility 可删；Q3=A 的诊断核对/probe 职责分离是硬验收。projection 过渡不能代替最终四字段 cutover，不声称未测性能收益。

## Consequences

保留产品只有一个 Apple/OCaml wire 和一个媒体 presentation 来源；无人消费的扩展支持义务及 Flutter hosts 已移除。静态 source API 与环境完整快照的兼容承诺按已答决定终止，未来新增能力需重新建立明确消费者和合同。Undo 不再遍历删除时的全部历史，期间编辑和当前顺序仍受 public reducer 验证。

代价是退休 Flutter 的运行入口不再受支持、旧 static 调用方必须 seed Store、外部环境快照消费者须随合同更新。独立媒体修复与正确性 guard 保留；原生验收和性能证据的边界在实施记录中逐项说明。全仓历史文档规范缺口独立记录，不修改无关文件。

### 探索阶段文档验证（历史）

`TZ=Asia/Shanghai` 工具创建 canonical 日期路径；HEAD 固定 PR44 merge。2026-10-04 答案更新后 `spec-dev-tool check <doc>` 通过；91 个 Markdown 链接完成存在性复核，其中 73 个源码链接通过固定 SHA 的 Git blob 路径/行范围检查。相对 decision 链接与本机报告路径存在，Questions 为最后 level-two section。已核对 Q1=B/Q2=A/Q3=A 原选项并记录原话/日期，全文无旧的待答依赖或 retained Flutter 验收要求。`git diff --check` 与本次修改前副本的 no-index whitespace 检查无输出；后者退出 1 仅表示文档内容不同。工作树仍仅本文件 untracked，未改其它 tracked/untracked 仓库文件。

全仓历史 `docs/agent-guide/implemented/feature/2026-09-28-bottom-lui-capsules.md` 缺 Problem、Alternatives considered、Consequences，初版完成前 check --all 已失败；答案更新后重跑仍仅该历史文档失败。本次不修其它文件；这是既有文档规范缺口，不是新增 source/test 失败。原媒体与 A0 native 证据限制见上文，不隐去未执行 PDF/真实点击验收。

## Implementation record（2026-10-04）

### 探索到实施的固定基线

Implementation checkout: `journal-impl`, branch `simplify/ui-supported-boundaries-2026-10-04`. Safe fetch resolves Journal origin/main to 953f71b5852b5ffd094bf75a040e46656ab8a1c9; local base is clean reviewed c0e14e11d8cf17ab75a267b53ca1845589ff12d3, preserving separate b3ab77d/aaea1c4/0798a5c/c0e14e1 commits. R1 retained-return owner, R2 collapsed/retired owner, R3 independent preview lease, shared owners, pressure join for already-shown controllers, rejection of new requests and late completion guards are mandatory regressions. Dependency main resolution and actual native validation inputs are recorded in the implementation evidence below.

### 已落地范围与实际证据

- C1–C4/C12：删除未消费 UI 构造/导出/挂载表示，输入翻译每 mount 仍持独立 revision；真实 Toolbar、flat Account、Inline status、composer/secure field、Native_list 与 typed navigation 保留。
- A0：wrapper 绑定当前 mounted rows 的 enabled actions；折叠子行、缺失/退休 node 与未知 key 不进入回调。Timeline/Detail 同一转发路径通过后才删 Detail raw JSON/Hashtbl 补丁。原生 Status 暴露基线已有的 Picker label 缺失，修复真实 batch rejection。另补显式 Radio Change 合同与公开事件 RED→GREEN；旧 LUI 有 Toggle/Press fallback，直接注入 Change 的旧失败不证明实际 native 点击失败。最终验收验证标准 Change 路径，不以 synthetic Press 冒充。
- C5/Q1=B：116 个 Flutter 路径（含 46 个 binary files）全部退休，删除 9,479 行文本；外部未发现仅 Flutter 的 tool/CI/config。旧 media schema/kind/profile/Swift renderer 移除，仍实际使用的导入 Decoder/cache/cancel/security-scoped owner 保留为 `JournalImportThumbnail`。共享 OCaml/C/worker/Apple/crypto 边界与测试保留。`test/dune` 仅删获授权的 3 个 source_tree、8 个明确依赖，不改 stanza/action。
- C6/C11：offset 删除、count 从 slots 长度导出；Undo 仅保存被删 target 和必要 day knowledge，在当前 `(day,sibling_order,id)` 顺序恢复。公共 reducer 捕获 intervening insert/pagination、隐藏 sibling、同 key 新内容、过期 anchor 与 hidden-budget prune 的业务 RED；31 原有加 6 新回归共 37 个通过，不恢复整份 before。
- C7/Q2=A：所有 production/static/review/testing 视图必须接收独立 Store，fixtures seed 功能保留；根 media_views 镜像、optional fallback 删除。Store flush 保留 graph/session context 校验与局部结构/item 订阅，不发布重复根 model。
- C8：按钮、Account、Detail、媒体、Capture attach/remove 走 typed callbacks；保留原生 external wire 的一次解码，scope/entry/request generation 不由去字符串而撤销。
- C9/Q3=A：Apple/OCaml wire 最终仅 platform/brightness/highContrast/accessibleNavigation 四项。旧几何探针无 layout/诊断消费者后移除；实际 platform owner 先缓存连接前/断连样本，再由 connect/reconnect 发送最新样本，四个公开生命周期 RED→GREEN。native layout/keyboard/安全区/Dynamic Type owner 保留。
- C10：managed_sync_startup 恒 true 分支、旧 diagnostic label 过滤移除；保留 origin 与当前 diagnostics/lifecycle。

实施源基线为 c0e14e11d8cf17ab75a267b53ca1845589ff12d3；本地提交记录保留媒体修复原提交，不覆盖原任务工作区。解析 Journal main 为 953f71b5852b5ffd094bf75a040e46656ab8a1c9、LUI main 为 27e8d149cd725c722cb0b17604a491e407f5153a、Signal main 为 868c1459f865b4ba3b227eb440dba40f1c812899。匹配 OCaml 5.5.0/Dune 3.23.1、最新 main 的 OCaml/Apple Release 闭包都在隔离 overlay，未改共享 opam/冻结前缀；Signal 20、LUI 56 测试通过，冻结库 4,990 文件 hash 无漂移。[依赖证据](/Users/rcmerci/Documents/Codex/2026-10-04/task/evidence/dependencies/README.md)。

[wrapper/A0 证据](/Users/rcmerci/Documents/Codex/2026-10-04/task/evidence/wrapper/ownership-and-proof.md)、[Picker label 证据](/Users/rcmerci/Documents/Codex/2026-10-04/task/evidence/wrapper/status-label/report.md)、[Undo 证据](/Users/rcmerci/Documents/Codex/2026-10-04/task/evidence/timeline/implementation-evidence.txt)、[环境合同/owner 证据](/Users/rcmerci/Documents/Codex/2026-10-04/task/evidence/environment/summary.md)、[退役清单](/Users/rcmerci/Documents/Codex/2026-10-04/task/evidence/retirement/flutter-retirement-freeze.json)、[独立 review](/Users/rcmerci/Documents/Codex/2026-10-04/task/evidence/independent-simplification/report.md) 均 Git 外保存，便于复核且不混入产品路径。

Undo 轻量单次 CPU 对照（排除 setup/feed/stage）：5k 旧 1.037320s、新 0.000750s；10k 旧 4.537246s、新 0.001433s。只说明此次全历史二次扫描已移除，不设时间阈值，不声称正式 benchmark、全 Timeline 算法线性或零分配；其它 normalize/recovery 扫描保留。

### 验证记录与局限

产品源码冻结为 `e5803bd902b1eae7cc2ec29aa6f013d0250c9d8d`，后续仅本正式文档与 lifecycle 路径变更。该版本 `dune build @all --profile release` 与完整 `dune runtest --profile release` 均退出 0；Application 55、semantics 31、Timeline 37 与现有共享/媒体/分页/transport/crypto 覆盖保留。使用隔离绝对 build-dir、匹配 main 依赖，最终日志：[Release build](/Users/rcmerci/Documents/Codex/2026-10-04/task/evidence/root/final-change-build.log)、[Release runtest](/Users/rcmerci/Documents/Codex/2026-10-04/task/evidence/root/final-change-runtest.log)。此前所有套件成功结果与最终增量聚合检查相同源码闭包，不把只重新执行的 Application 55 项描述成所有套件重新执行。

最终 iOS 26.1 / iPhone 13 专用 Simulator 的真实 Release `-O`/WMO 二进制完成九项新验收：collapse、PNG/PDF/TXT Quick Look、两次 retained Back、Status/Delete、四字段环境/Capture keyboard、Append、import thumbnail。31 张截图及 lease/layout/source/hash assertions 均通过。Status 是 CUA 激活真实 SwiftUI Todo 按钮，sheet 关闭、production command 到 synthetic Worker fixture 一次；Delete optimistic rows 从 50 变 49。QL 实际呈现并执行真实 dismiss callback；背景 UIKit `scrollToItem` 产生自然 visible range 18..29，未注入 range/dismiss。Back 使用程序化实际 UIKit pop，保留同一 collection/layout/media IDs，并非手势测试。Append 等 Detail loaded/native settled 后验证真实编辑器中文与 keyboard；初次过早触发被 loading guard 正确拒绝。Capture 验证实际 first responder、文本和键盘通知，Dynamic Type 验证同一 collection 内容高度变化。[最终原生报告](/Users/rcmerci/Documents/Codex/2026-10-04/task/evidence/native-simplification/report.md)、[二进制与源码 provenance](/Users/rcmerci/Documents/Codex/2026-10-04/task/evidence/native-simplification/build-provenance-e580.json) Git 外保存。

原生验收使用独立合成 graph、实际 Journal/LUI/Swift 组件与本地 Worker fixture，不操作用户 graph。它不覆盖 native admission saturation、platform reconnect、延迟 Delete commit/Undo notice、full Graph file import、远端 Worker、OS VoiceOver/IME 或正式 benchmark。reconnect 由实际 platform owner 的公开生命周期测试补证，admission/late completions/Undo 由已有或新增公共 owner 测试补证，不能据此声称全端到端流程通过。accessibilityNavigation=true 的环境样本是显式 LJP2 输入，不是 OS VoiceOver 手势。Simulator 采用仓库既有 host-arm64 OCaml complete object 的 vtool restamp；这是 Simulator 验收，不是 device cross-target package 或手机安装。

首轮产品冻结 e580 相对 clean media base `c0e14e11` 的实际分组统计：app/Swift 21 文件新增 1,172、删除 2,362，净删除 **1,190** 行；Flutter 116 路径删除 **9,479** 文本行及 46 binary files；test 6 文件净新增 **506** 行（含精确授权 Dune 依赖删除）；fixture/.gitignore 2 文件净删除 5 行。正式文档单独统计，binary 不换算行数。这是完成后的 diff，原各项估计仍为历史估计、不作交付配额；C5 media renderer 与 Flutter 总退休不重复累计。独立 final-source review 无新增 P1/P2。首轮 sandbox 阻止本地 loopback peer 与临时 RSA fixture，造成 transport/crypto 的环境失败；已在相同源码、仅这些 OS 能力可用的执行环境重跑完整 Release runtest 通过，未改生产 crypto/transport 或删测试。源码 boundary 对 manifest 的公开 CMI 检查改为同样精确路径后缀，支持隔离绝对 build-dir；接口、private module、shared owner 检查均保留。历史 bottom-lui-capsules 文档缺三个必需 section 的 check --all 失败依旧独立报告。

### PR45 的既有 fixture teardown 修复（另行授权）

首轮 PR45 head `1df1707` 的 [CI run37171150824](https://github.com/logseq/logseq_journal/actions/runs/37171150824) 构建/native embed 通过，Application 54/55 通过，唯一 regions/7 在 initial feed 前因 `Worker Domain session is already attached` 失败。旧 main953 的 [run37131983436](https://github.com/logseq/logseq_journal/actions/runs/37131983436) 已记录同一签名；共享 fixture 的 conditional finally 与 Worker runtime 当时均未改。`Application.dispose` 请求异步停止并清空 current app，fixture 却只在 media_rows=Some 时等公开 Runtime.stop，下一 fixture 可在全局 Attached 尚未退出时启动。

用户随后明确回复 **“处理”**，授权此既有测试清理问题纳入 PR45。先补全部 fixture 清理后的公开 Idle/active_sessions=0 断言，及实际初始化后 body Failure/Exit 两个场景：旧逻辑的 11 项局部检查一次通过（保留竞态限制），完整 57 项在两项退出的 Idle 断言 RED，后继媒体 fixture 也 Busy→initial feed false，共三项失败。再按最小范围去掉 media_rows 条件，在 release Acquire gate→dispose 后无条件调用公开 Runtime.stop，等待 client stopped 与全局 Attached 退出；不 join/shutdown 全局 Domain。Fun.protect 保留 body 异常/提前退出的 finally 与原异常身份，不新增 sleep、retry、UUID/tempdir workaround、生产 API、Dune 或 protected spec 修改。

测试源码冻结 `f07deacbb0c70967d30e8abd86f7d89644fd90b0`；修复后 11 项局部 GREEN，最终 Release `dune build @all` 与 **`dune runtest --force` 完整重跑均退出 0**，Application 全 57 项通过（非首轮增量聚合）。实际 build-source/Git 字节一致，app/Swift 与 e580 原生验收产品源码不变，因此不把已有九项原生结果描述为此轮重新安装/运行。[fixture RED/GREEN、源码与检查证据](/Users/rcmerci/Documents/Codex/2026-10-04/task/evidence/fixture-teardown/report.md)、[最终强制回归日志](/Users/rcmerci/Documents/Codex/2026-10-04/task/evidence/fixture-teardown/final-runtest.log)。独立复核未发现实质问题。

此授权增量只改 test/application_view_test.ml，新增 36、删除 2 行；相对 c0 的最终 tests 净增 **540** 行，Apple/Swift 净删 1,190 与 Flutter 9,479 文本行/46 binary 的产品统计不变。首轮失败 CI 保留，后续更新到 PR45 的精确 head 并跟踪新 CI，不能把旧 head 的结果当新 head 通过；最终远端结论以 GitHub 对应 head/run 与 Git 外交付记录为准。无新增待答产品取舍。

## Questions

**三项均已答，无新增待用户回答问题。** 用户于 **2026-10-04（Asia/Shanghai）** 原话回复：**“1B, 2A, 3A”**。以下保留原问题/选项用于决策追溯，A 的“推荐”是当时提供的原选项标签，不代表覆盖用户选择；正文以上述已答范围为准。后续实现授权已另行记录；实施与验收完成后转为 implemented，按后续明确授权统一提交 draft PR 并跟踪 CI，不 merge/手机安装。诊断消费者、原生布局、Flutter 退休清单与独立媒体修复结果属于技术核对/验收，结果见实施记录，不再要求用户重复回答。

1. **Q1 — 已答 B（2026-10-04）：退役全部 Flutter hosts，保留 Apple iOS 与 macOS 基础支持。** 原问题： UI 合同收窄后，仓库已注册的 Flutter iOS/Android/macOS hosts 是否仍须保持可运行，并随 Apple/OCaml 原子更新？
   - **A（推荐）：全部保留。** 同步修改 Flutter registry/schema/环境编码并做相应 host tests；代价是跨三端验证与发布协调，不会悄悄退役现有注册能力。
   - **B：仅保留 Apple iOS 主产品与 macOS 基本测试。** 先单独明确 Flutter hosts 退役决定，再消除合同义务；代价是这些 Flutter 运行入口不再受支持，本文件不把“未测”当退役。
   - 原选项附注：若只保留部分 Flutter hosts，请列明平台；实现不能自行猜测。**本次选择 B，已明确全部 Flutter hosts 退休，无待补的平台清单问题。**

2. **Q2 — 已答 A（2026-10-04）：允许原子改 static/review/testing API，独立 Store seed，移除 root live media_views 镜像。** 原问题： 是否允许现有 static view/For_testing 消费者改为 seed 独立 Store，并同步调整 source API，以移除根 model 的 live media_views 镜像？
   - **A（推荐）：允许原子改接口，保留 fixture 功能。** production/fixture 共用一个 presentation 来源；代价是调用方调整 seed/读取方式，不保留旧 optional live fallback。
   - **B：现有 static/snapshot 调用形状必须继续支持。** 优先从 Store 派生同样 snapshot/getter；若做不到且必须双镜像，则暂缓 C7。代价是净删较少或继续双发布义务，不恢复 whole-model 订阅。

3. **Q3 — 已答 A（2026-10-04）：四字段最终环境合同，保留原生行为，删探针前核对诊断消费者。** 原问题： 是否将 Journal OCaml 环境 wire 限定为现用 platform、brightness、high_contrast、accessible_navigation 四项，停止支持其余几何/键盘/设备/辅助设置快照字段？native 键盘布局、safe area、Dynamic Type、accessibility 行为继续保留。
   - **A（推荐）：收窄四项，保留 hosts 原子切换。** 证明 probe 无布局/诊断消费者并通过 native 验收后删仅用于旧 wire 的探针/编码；代价是依赖完整快照的外部诊断/host 必须同步改合同，未来业务需要字段再正式引入。
   - **B：保留完整 17-field snapshot 合同。** 只缩窄 Application 比较/通知 projection；代价是继续维护完整 probe/codecs，不能宣称 140–220 行整退役收益。
