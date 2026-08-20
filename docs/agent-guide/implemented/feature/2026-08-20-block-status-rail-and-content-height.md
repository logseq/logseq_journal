# Block Status Rail And Content Height

## Problem

The annotated reference asks for two changes to journal block rows:

- replace the current task-status glyph with a colored vertical rail at the
  block's leading edge; and
- size each block row to its displayed content, from one through four lines,
  with block text aligned to the leading edge.

Only those two annotations are requirements. The status filter cards, counts,
dates, composer, example text, typography weight, and other controls visible in
the reference image are contextual artwork and are outside this decision.

The current application cannot implement the annotations as isolated styling
changes. `Journal_model.task_state` has only `Not_a_task`, `Todo`, and `Done`.
`Journal_graph_projection.task_state` maps `done` and `canceled` to `Done`, maps
every other status value to `Todo`, and therefore loses the distinction among
the reference's Todo, Doing, Done, and Later categories. The row then renders a
checkbox-like task glyph in a conditional leading slot. Task rows consequently
start farther from the leading edge than blocks without a status.

Collapsed top-level rows also share one profile-wide `top_level_extent` even
though `Journal_row.Item.preview` displays between one and three logical lines.
The largest preview fits, but short rows retain unused vertical space. The same
fixed extent is published independently by `Journal_row`, `Journal_timeline`,
and `Journal_timeline_state`, so changing only the text widget would make the
rendered row disagree with the virtual list's scroll geometry.

The installed `bonsai_flutter` contract is explicit: `Sliver.varied_extent`
accepts application-owned known extents and Flutter does not measure arbitrary
row heights for the application. `Host_effect.measure_layout` reports an
already-laid-out node; it is not an intrinsic text-measurement API and cannot
derive an unbounded paragraph height before a virtual row is materialized.
Consequently, exact height based on platform font wrapping is not available
without a separate framework capability.

Logseq data already contains more status information than the application
retains. The current graph schema exposes `backlog`, `todo`, `doing`,
`in-review`, `done`, and `canceled`; the worker's task query also recognizes the
historical `waiting`, `now`, and `later` identifiers. The graph block property
summary carries the exact status ident, so no worker protocol or database
migration is needed to preserve it.

## Decision

Adopt an application-owned four-category status rail and a deterministic
one-to-four-line preview layout. Keep the existing varied-extent virtual list
and provide it the same pure row metrics used by rendering.

### Status model and presentation

Replace the lossy three-state application model with exact known status values:

| Logseq status ident | Application status | Rail category |
| --- | --- | --- |
| no status property | `No_status` | no rail |
| `status.todo` | `Todo` | Todo |
| `status.doing` | `Doing` | Doing |
| `status.in-review` | `In_review` | Doing |
| `status.now` | `Now` | Doing |
| `status.done` | `Done` | Done |
| `status.canceled` | `Canceled` | Done |
| `status.backlog` | `Backlog` | Later |
| `status.waiting` | `Waiting` | Later |
| `status.later` | `Later` | Later |

Projection must match the complete ident, preserve the exact application
status, and reject an unknown status ident as corrupt graph data instead of
silently painting it as Todo. Mutation code must serialize the selected exact
status value rather than retain the obsolete Todo/Done-only conversion.

Define semantic color tokens for Todo, Doing, Done, and Later in both normal
and high-contrast palettes. The intended visual families are neutral slate,
blue, green, and purple respectively. Token values must remain distinguishable
against the row background and must be verified in the runtime golden rather
than embedding ad hoc colors in `Journal_row` or `Journal_timeline`.

For every top-level block and materialized direct-child block with a status,
render a narrow rounded vertical rail at the row's leading inset. The rail spans
the preview text stack, excluding vertical row padding. Blocks without a status
render no rail. Reserve the same content leading position for every block, so
adding or removing a status never shifts its text.

The rail is a status indicator, not a disguised checkbox. Remove the timeline
task glyph, its conditional layout slot, its independent press target, and the
`timeline-task` dispatch path. Do not leave a transparent compatibility target
over the rail or text. Existing status actions in Detail and Capture remain the
editing surfaces; adding the four filter controls or a new status picker shown
in the reference is out of scope. Row semantics must include the exact status
name so the state is not conveyed by color alone.

### Content and height policy

Define a preview line as one application-known logical line, not a line
produced by platform-dependent font wrapping:

1. split the block source on explicit newline boundaries;
2. add source lines in order;
3. for a collapsed top-level block, add direct-child summary lines in order
   while budget remains; and
4. clamp the result to one through four lines.

Each preview line is a single-line, leading-aligned text widget with ellipsis.
This makes long text deterministic at every viewport width and ensures that
one logical line cannot wrap and invalidate the virtual extent. Source consumes
the budget before child summaries. Expanded parents omit their collapsed child
summaries, while each materialized direct-child block uses its own source lines
and the same one-to-four-line rule.

"Left aligned" means `Text_align.Start` and top-start stack alignment: physical
left in left-to-right locales and the correct leading edge in right-to-left
locales. Timestamp and disclosure affordances remain in their trailing slots
and do not consume the four-line block-content budget.

Calculate a block extent from the clamped visible-line count, scaled line
height, vertical padding, and the minimum row target. Round the result up to a
logical pixel. Replace the fixed `top_level_extent` and the separate
`expanded_parent_extent` policy with one authoritative line-based metric; do
not retain aliases or fallback extent paths.

Use the one-line block extent as the varied sliver's default. Publish sparse
overrides for every retained top-level or direct-child slot whose computed
extent differs from that default, and keep the existing explicit overrides for
day headings, continuations, and bottom clearance. `Journal_row`, direct-child
rendering, swipe wrappers, focus scopes, group separators, connectors, and
`Journal_timeline_state.extent_geometry` must all consume the same computed
extent. The status rail and child connector use that extent rather than a
profile-wide fixed height.

This remains a known-extent strategy. It does not introduce asynchronous
measurement, hidden offstage text, layout callbacks, renderer events, or
changes to `bonsai_flutter`. Likely application scope includes
`journal_model`, `journal_graph_projection`, `journal_graph_runtime`,
`journal_capture`, `journal_detail`, `application`, `journal_visual_tokens`,
`journal_row`, `journal_timeline`, and `journal_timeline_state`, together with
their focused OCaml and compiled-runtime tests. No file under `spec/`, no dune
file, and no OCaml file in the `bonsai_flutter` repository is in scope.

## Alternatives considered

### Keep the three-state model and recolor the existing glyph

Rejected. It could show at most Todo and Done truthfully. Doing, In Review,
Backlog, and Later would continue to be mislabeled before rendering, so adding
more palette entries would not produce the requested status distinction.

### Keep the status rail as a 44-point timeline toggle

Rejected. A 44-point target centered on a narrow leading rail overlaps the
requested common text leading position. Moving text around the target would
retain the current misalignment between status and non-status blocks. An
invisible overlapping target would also make text taps ambiguous with row
expansion and would present a four-category status as a checkbox. Status
editing remains available outside the timeline row.

### Let each Text widget wrap intrinsically and measure it afterward

Rejected for the current framework. The varied sliver requires extents before
materialization, and the available layout measurement reports the constrained
rendered box rather than an intrinsic paragraph height. Rendering hidden text,
measuring it asynchronously, and then replacing extents would add extra frames,
scroll-anchor movement, cache invalidation, and measurement work proportional
to retained rows.

If product requirements later demand platform-exact wrapping, that work needs a
separate `bonsai_flutter` text-metrics or intrinsic-varied-sliver design. It
must not be approximated here with character counts, because proportional
fonts, Unicode graphemes, locale, text scale, and viewport width make such
estimates disagree with Flutter.

### Give every block the four-line maximum extent

Rejected. It preserves known virtualization geometry but directly violates the
one-line minimum and content-dependent height requirement. It would retain more
empty space than the current three-line row.

### Apply variable height only inside `Journal_row`

Rejected. The sliver, focus wrapper, swipe wrapper, group separator, and row
surface would disagree about the same slot's extent. The resulting clipping or
scroll-offset drift would be a geometry defect, not merely a visual mismatch.

## Consequences

The application now preserves all ten known status states, groups them into
four semantic rail categories, and rejects unknown status identifiers during
projection. Timeline rows no longer expose the obsolete task glyph, checkbox,
or `timeline-task` action. Detail and Capture remain the status-editing
surfaces.

Top-level and direct-child rows now render explicit logical lines with a shared
one-to-four-line budget. `Journal_visual_tokens.block_extent` is the only block
height policy, and the renderer, wrappers, connectors, rails, and sparse sliver
geometry consume the same result. The sliver uses the one-line extent as its
default and publishes overrides only for rows and fixed slots that differ.

The implemented behavior has the following verified properties:

- Projection preserves every known status listed above, maps it to the specified
  rail category, and rejects an unknown status ident instead of coercing it to
  Todo.
- Todo, Doing, Done, and Later render distinct semantic rail colors in normal
  and high-contrast palettes; a block without status has no rail.
- Status and non-status blocks share exactly the same source-text leading
  position. The rail is the leading-most block decoration and does not create a
  conditional content indent.
- The timeline contains no task glyph, task checkbox semantics, transparent
  rail target, or `timeline-task` event path. Row semantics announce the exact
  status when present.
- A source-only block displays one through four explicit source lines. A
  collapsed parent fills any remaining budget with direct-child summary lines,
  source first, and never displays more than four total preview lines.
- Long logical lines ellipsize on one rendered line and never change the known
  extent through platform wrapping.
- Block source and supporting text use leading alignment at compact, adaptive,
  high text-scale, and RTL configurations. Trailing timestamps and disclosures
  remain trailing.
- One-, two-, three-, and four-line top-level rows publish four corresponding
  exact extents. Materialized direct-child rows follow the same rule.
- Row surface, swipe content, focus scope, group separator, status rail, child
  connector, and sparse extent override agree on each block's exact height.
- Changing a retained block's status does not move its text horizontally;
  changing its visible line count updates its sparse extent while preserving
  the visible-slot anchor policy.
- Focused OCaml view/state tests cover the status mapping, semantics, line
  budget, colors, alignment, and extent matrix. The compiled runtime golden is
  regenerated with at least one example of each rail category and each line
  count, and swipe/delete coverage remains green.
- Existing bounded-window, pagination, expansion, deletion, accessibility,
  RTL, high-contrast, and text-scale tests remain green without modifying
  `bonsai_flutter`, `spec/`, or dune files.

## Remaining tradeoffs

- Deterministic logical lines intentionally give up automatic paragraph
  wrapping in the timeline preview. Users can still read the full source in
  Detail; the timeline uses ellipsis to preserve exact virtualization geometry.
- Removing the inline task target removes one-tap completion from the timeline.
  Keeping it would conflict with the requested common text alignment and with
  truthful four-category semantics. Detail and Capture remain the explicit
  status-editing surfaces.
- Several known Logseq statuses share one visual rail category. The exact value
  remains in the model and accessibility label, but color alone distinguishes
  only the four categories shown by the reference.
- Variable block extents increase the number of sparse overrides compared with
  one profile-wide top-level extent. The retained timeline is already bounded,
  so the list remains bounded by `maximum_slots`; tests should guard that extent
  computation remains linear in retained slots.
- Extent changes after source edits or expansion can affect scroll position.
  The existing stable slot key and `Preserve_visible_slot` policy must remain
  authoritative, and compiled tests must cover a visible row growing and
  shrinking without an unintended reset to the top.
