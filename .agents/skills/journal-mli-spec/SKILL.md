---
name: journal-mli-spec
description: 编写、修改或审查 Journal 的 OCaml .mli 规格接口，以 TLDR 和紧随其后的使用示例组织面向人的契约。适用于所有 spec/ 下的 .mli，以及其他目录中承担规格契约的 .mli。
---

# Journal MLI Spec

让读者只看前两部分就能理解模块的职责、核心对象、输入输出、使用顺序和关键生命周期。遵守仓库现有的契约修改授权边界；本 skill 本身不授权修改 spec、实现、Dune 或其他接口。

## 固定结构

每份规格接口按下列顺序组织，使用 odoc 章节。前两部分必需；第 3–6 部分仅在适用时保留，不添加空章节。

| 顺序 | 章节 | 内容 |
| --- | --- | --- |
| 1 | TLDR | 一句话职责、核心类型、输入输出、主入口、影响正确使用的关键约束 |
| 2 | 最小使用示例 | 一个典型流程，包含必要的结果处理、状态安装或资源清理 |
| 3 | 构造与校验 | 配置、限制、参数和受校验值的构造 |
| 4 | 能力细节 | 按业务能力展开，每组放相关输入、结果、错误和操作 |
| 5 | 生命周期与恢复 | 取消、释放、重试、持久化、失效与过期事件处理 |
| 6 | 观察与辅助 | 状态投影、比较、诊断、编码等辅助接口 |

文件开头的模块简介属于 TLDR，不另设排在 TLDR 前面的章节。纯类型或能力接口的第二部分展示如何消费该值，或如何接入真实 owner 的执行入口；不要为凑示例增加 API。

## TLDR 的内容与边界

- 优先使用真实导出声明，展示少量核心定义和主入口。关键业务 record、variant 和错误应直接可读；内部状态和受控句柄可以抽象。不要把所有输入输出都隐藏成没有语义说明的抽象类型。
- 通常约 30–60 行，小接口可以更短；这是阅读目标，不是硬性行数限制。不要压缩排版、删掉关键保证或添加无用声明来迎合行数。
- 明确模块负责什么、状态或资源由谁持有、是否执行 I/O、是否持久化，以及正常调用顺序。只在相关时写出这些信息。
- 把影响理解或正确使用的事实留在 TLDR，例如成功仅代表入队、取消不证明回滚、关闭需要真实完成 ACK。具体字段限制和完整异常分支放到展开部分。
- 不重复声明 TLDR 已导出的名字。OCaml 类型必须先于其使用，不能先声明抽象类型，再在后面展开同名类型。优先移动依赖允许的声明；大型现有 GADT 等依赖阻碍时，可在 TLDR 文档代码块中摘录主签名并用 `{!name}` 指向真实声明。摘录必须与真实接口一致，不能伪装成额外 API。
- 不为排版新增包装层、改变类型相等关系、削弱抽象边界或重设协议。需要改变契约才能实现的结构调整，应先明确契约问题和理由，并遵守已有授权。

不同角色应在 TLDR 突出不同定义：

| 接口角色 | 核心定义 |
| --- | --- |
| 领域数据 | 核心 record/variant、校验入口、主要转换 |
| 纯 reducer | 可观察阶段、事件、指令、`initial` / `step` 及转换结果 |
| I/O 或资源 | handle、主要错误、创建/使用/关闭入口、成功与关闭的含义 |
| UI | `props` / `action` / `view`，以及状态与事件的 owner |
| 协议或 codec | 消息方向、核心消息、编码/解码入口和失败结果 |

## 第二部分：最小使用示例

紧跟 TLDR，展示一个完整的典型流程；特殊分支的示例放在对应能力旁边。

- 使用真实公开入口，不绕过 `.mli`、制造 sealed 值或调用实现内部函数。
- 对 reducer 展示先安装返回状态、再按序解释指令；若回调必须排到后续串行回合，写明这一点。
- 对资源接口展示获取、使用和必要的释放；对 I/O 展示成功和错误如何传播。仅在类型或 API 确实如此时使用 `Fun.protect`、`result` 或特定关闭协议。
- 示例引用后文声明是允许的。明确例子由调用者提供的变量或回调；不要把未导出的方便函数写得像模块 API。
- 示例反映该模块真实的持久化和所有权语义，不套用其他层的保证。

## 展开部分的写法

按业务能力或生命周期分组，相关类型、错误和函数尽量相邻。使用章节改善导航；只有独立概念或所有者需要时才拆模块。不要把所有类型和所有函数机械地分成两大块。

注释说明类型表达不了的契约：前置条件、成功保证、失败后保留的状态/资源、后续动作和生命周期。短操作不必机械填写全部项目。

对 session、continuation、ticket、receipt、lease 等句柄，在定义附近交代创建者、持有者、绑定范围、失效条件和是否跨重启保存。区分编译期类型保证与运行时 owner/generation 校验；抽象类型或 GADT 本身不证明当前授权有效。

分别表达状态、输入事件、输出指令和操作结果。复杂状态机补充关键转换规则，尤其是过期或重复事件、取消竞争、未知结果、清理失败和真实结束条件。不能仅列阶段名称就声称协议完整。

保留各层真实差异。例如单次 admission、执行结果、持久化结果与呈现确认不能混为一谈；`None`、空页、缺失项和带 continuation 的部分结果也必须按实际语义解释。

用 `(** ... *)`、`{1 ...}`、`{2 ...}`、`{!name}` 和 `{[ ... ]}`，让源码和 odoc 文档都有清晰导航。不要在函数注释里塞入无关的模块级规则。

## 模板示意

下面是一个异步有界读取 reducer 的组织示例，不是对项目现有接口的替换要求。采用真实模块的名称、类型和行为，不照搬示意协议。

```ocaml
(** 协调有界读取及其完成事件。

    {1 TLDR}

    本模块拥有进程内请求状态，runner 拥有实际 I/O。
    step 是纯函数，不持久化状态。 *)

type t
type ticket
type request = private { key : string; limit : int }
type error = Invalid_request of string | Read_failed of string
type reply = (string list, error) result
type phase = Active | Draining | Stopped

type event =
  | Requested of request
  | Read_completed of ticket * reply
  | Shutdown_requested

type instruction = private
  | Run_read of ticket * request
  | Cancel_read of ticket
  | Publish of ticket * reply

type transition = private
  { next : t
  ; instructions : instruction list
  }

val initial : t

(** 先安装 next，再按序解释 instructions。 *)
val step : t -> event -> transition
val phase : t -> phase

(** Shutdown 进入 Draining，待实际读取及其回调结束后才为 Stopped。 *)

(** {1 最小使用示例}

    调用者提供 state 引用、输入 event 和 runner 的 interpret：
    {[
      let transition = step !state event in
      state := transition.next;
      List.iter interpret transition.instructions
    ]}
    interpret 将完成事件排入后续串行回合。 *)

(** {1 构造与校验} *)

val maximum_limit : int

(** key 非空，limit 在 1..maximum_limit 内。 *)
val request : key:string -> limit:int -> (request, error) result

(** {1 生命周期与恢复}

    完成事件匹配原 ticket。无关或重复完成不改变状态。
    Draining 继续接收完成事件，不接纳新请求。 *)

(** {1 观察与辅助} *)

val pending_count : t -> int
val error_message : error -> string
```

## 验收

1. 遮住第二部分之后的内容，读者仍能说清职责、核心对象、输入输出和基本使用流程。
2. 第一部分是 TLDR，第二部分是使用示例；示例和摘要都与真实声明一致。
3. 类型依赖合法，没有重复声明、伪造 API、弱化 sealed/private 边界或改变协议语义。
4. 详细部分能找到调用所需的限制、失败处理和结束条件；句柄的持久化与失效语义明确。
5. 只整理任务授权的目标接口，不自动迁移其他 `.mli`。检查按仓库 [最终验证范围](../journal-code-review/references/validation.md#final-validation) 选择。

项目参考：[紧凑纯接口](../../../logseq_db_types/lib/squuid.mli)、[UI 输入与动作](../../../app/journal_composer_view.mli)、[按生命周期展开的数据库契约](../../../logseq_overlay_db/spec/database.mli)。这些文件提供结构参考，并不表示已全部符合本模板。
