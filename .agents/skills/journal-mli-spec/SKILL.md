---
name: journal-mli-spec
description: Write, change or review Journal OCaml .mli specifications as readable English contracts, starting with TLDR and an immediate usage example. Applies to every .mli under spec/ and other .mli files serving as specification contracts.
---

# Journal MLI Spec

Let readers understand the module's responsibility, core objects, inputs, outputs, usage order and essential lifecycle from the first two sections. Follow the repository's existing contract-change authorization boundaries; this skill does not itself authorize changes to specifications, implementations, Dune files or other interfaces.

## Language

Use English throughout the template and the resulting `.mli` declarations, documentation, comments, section headings and explanatory text in examples. Preserve externally defined names and domain data where required; do not translate literals whose exact value is part of a contract.

## Fixed structure

Organize each specification in this order using odoc sections. The first two sections are required. Include sections 3-6 only when applicable; do not add empty sections.

| Order | Section | Contents |
| --- | --- | --- |
| 1 | TLDR | One-sentence responsibility, core types, inputs, outputs, primary entry points and constraints essential to correct use |
| 2 | Minimal usage example | One typical flow, including necessary result handling, state installation or resource cleanup |
| 3 | Construction and validation | Configuration, limits, parameters and constructors for validated values |
| 4 | Capability details | Group related inputs, results, errors and operations by business capability |
| 5 | Lifecycle and recovery | Cancellation, release, retry, persistence, invalidation and stale-event handling |
| 6 | Observation and helpers | State projections, comparison, diagnostics, codecs and other helpers |

The opening module synopsis belongs to TLDR; do not introduce a separate section before it. For interfaces exporting only types or capabilities, the second section shows how to consume the value or reach its actual owner's execution entry point. Do not add APIs merely to produce an example.

## TLDR contents and boundaries

- Prefer actual exported declarations showing a small set of core definitions and primary entry points. Make essential business records, variants and errors directly readable; internal state and controlled handles may remain abstract. Do not hide every input and output behind unexplained abstract types.
- Aim for roughly 30-60 lines; small interfaces can be shorter. This is a reading goal, not a hard limit. Do not compress formatting, remove essential guarantees or add unnecessary declarations to meet a line count.
- State the module's responsibility, ownership of state or resources, whether it performs I/O or persists data, and the normal call order. Include these facts only where relevant.
- Keep facts that affect understanding or correct use in TLDR: success may mean only queue admission, cancellation may not prove rollback, and shutdown may require an actual completion ACK. Put detailed field limits and exhaustive failure branches in later sections.
- Do not redeclare names already exported in TLDR. OCaml types must be declared before use; an abstract type cannot be expanded under the same name later in the signature. Move declarations when dependencies permit. If dependencies such as an existing large GADT prevent this, summarize the primary signatures in a TLDR documentation code block and link to the actual declarations with `{!name}`. Keep excerpts accurate and distinguish them from additional APIs.
- Do not add wrappers, change type equalities, weaken abstraction or redesign a protocol for layout. If a structural change requires a contract change, identify the issue and rationale and follow the existing authorization boundary.

Emphasize the definitions appropriate to the interface's role:

| Interface role | Core definitions |
| --- | --- |
| Domain data | Core records/variants, validation entry points and primary conversions |
| Pure reducer | Observable phases, events, instructions, `initial` / `step` and transition results |
| I/O or resources | Handles, principal errors, create/use/close entry points and the meaning of success and closure |
| UI | `props` / `action` / `view`, with the owner of state and event handling |
| Protocol or codec | Message direction, core messages, encode/decode entry points and failure results |

## Second section: minimal usage example

Place one complete typical flow immediately after TLDR. Put examples for special branches beside the relevant capability.

- Use actual public entry points. Do not bypass `.mli` boundaries, manufacture sealed values or call implementation internals.
- For reducers, show installation of the returned state before ordered interpretation of instructions. State when callbacks must queue a later serialized turn.
- For resource interfaces, show acquisition, use and required release. For I/O, show how success and errors propagate. Use `Fun.protect`, `result` or a particular close protocol only when supported by the actual types and API.
- Examples may reference declarations appearing later in the file. Identify caller-supplied variables and callbacks; do not present unexported convenience functions as module APIs.
- Reflect the module's actual persistence and ownership semantics rather than borrowing guarantees from another layer.

## Detailed sections

Group by business capability or lifecycle, keeping related types, errors and functions close together. Use sections for navigation; split modules only for distinct concepts or owners. Do not mechanically place all types in one block and all functions in another.

Document contracts that types cannot express: preconditions, success guarantees, state/resources retained on failure, subsequent actions and lifecycle. Short operations need not mechanically fill every category.

Near each session, continuation, ticket, receipt or lease definition, explain its creator, holder, binding scope, invalidation conditions and whether it survives restart. Distinguish compile-time type guarantees from runtime owner/generation validation; an abstract type or GADT does not itself prove current authority.

Represent state, input events, output instructions and operation results separately. For complex state machines, add essential transition rules, especially stale or duplicate events, cancellation races, unknown outcomes, cleanup failures and actual termination conditions. Enumerating phases alone does not describe the complete protocol.

Preserve real differences between layers. Admission, execution results, durable outcomes and presentation confirmation are separate facts. Explain `None`, empty pages, missing items and partial results with continuations according to their actual semantics.

Use `(** ... *)`, `{1 ...}`, `{2 ...}`, `{!name}` and `{[ ... ]}` so both source and odoc output are navigable. Keep unrelated module-wide rules out of individual function comments.

## Illustrative template

This asynchronous bounded-read reducer illustrates the organization. It is not a replacement contract for an existing interface. Use the actual module's names, types and behavior rather than copying the illustrative protocol.

```ocaml
(** Coordinate bounded reads and their completion events.

    {1 TLDR}

    This module owns process-local request state; the runner owns actual I/O.
    [step] is pure and does not persist state. *)

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

(** Install [next] before interpreting [instructions] in order. *)
val step : t -> event -> transition
val phase : t -> phase

(** Shutdown enters [Draining]; [Stopped] requires actual reads and callbacks
    to have finished. *)

(** {1 Minimal usage example}

    The caller supplies the [state] reference, input [event] and runner's [interpret]:
    {[
      let transition = step !state event in
      state := transition.next;
      List.iter interpret transition.instructions
    ]}
    [interpret] queues completion events for a later serialized turn. *)

(** {1 Construction and validation} *)

val maximum_limit : int

(** Require a nonempty [key] and [limit] within [1..maximum_limit]. *)
val request : key:string -> limit:int -> (request, error) result

(** {1 Lifecycle and recovery}

    Completions match the original ticket. Unrelated or duplicate completions
    leave state unchanged. [Draining] accepts completions but no new requests. *)

(** {1 Observation and helpers} *)

val pending_count : t -> int
val error_message : error -> string
```

## Acceptance

1. Hide everything after the second section: a reader can still explain the responsibility, core objects, inputs, outputs and basic usage flow.
2. TLDR is first and the usage example is second. Both agree with the actual declarations. All explanatory text and headings in the `.mli` are in English.
3. Type dependencies are valid, without duplicate declarations, invented APIs, weakened sealed/private boundaries or changed protocol semantics.
4. Detailed sections expose the limits, failure handling and termination conditions needed by callers. Handle persistence and invalidation are explicit.
5. Organize only interfaces within the authorized task; do not automatically migrate other `.mli` files. Choose checks using the repository's [final validation scope](../journal-code-review/references/validation.md#final-validation).

Project references: [compact pure interface](../../../logseq_db_types/lib/squuid.mli), [UI inputs and actions](../../../app/journal_composer_view.mli), and [database contract organized by lifecycle](../../../logseq_overlay_db/spec/database.mli). These illustrate useful structure; they are not assertions that every reference already conforms to this template.
