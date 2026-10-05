# Capture Task Actions

## Problem

Direct Capture needs optional task intent without interrupting the fast-capture flow or losing its draft.

## Proposal

Use a binary composer task selector. Plain captures use No_status and task captures use Todo; preserve exact source and the existing mutation lifecycle.

### Capture task IconButton

Render a Material task IconButton in the expanded Capture composer's bottom
action row at the logical leading edge. Save remains at the logical trailing
edge. The task action is visible even when the draft is empty so task intent can
be selected before typing.

The IconButton has exactly two states:

```text
Unchecked task icon -> No_status
Checked task icon   -> Todo
```

The icon, selected presentation, tooltip, and accessibility label must make the
intended capture type understandable without relying on color. The unchecked
state uses the composer's plain IconButton style and an unchecked task icon. The
checked state uses its filled IconButton style and a checked task icon. Their
state-aware tooltips announce `Capture as task, off` and `Capture as task, on`.
Do not imitate the action with generic decoration or create a second nested
interactive control.

This feature uses the published, pinned `bonsai_flutter`
`Expandable_message_composer.button` API. The application does not modify
generated Flutter host files, create a second application-owned composer, or
modify any OCaml file in the `bonsai_flutter` repository from this worktree.
Before application changes, the installed switch and generated host must be
synchronized to the repository's selected framework revision.

`Journal_capture` owns the selected task intent. Pressing the task IconButton
must preserve the exact draft, selection, composing range, focus, active modal
route, and FAB presentation. `admit_save` snapshots the exact untrimmed source
and current task intent into the same `Journal_graph_projection.capture`
command. It must no longer hard-code `No_status` or expose a `task_state`
accessor that ignores its state.

During a pending save, the editor, task IconButton, and Save action are disabled.
Success dismisses the composer and resets both the draft and task IconButton for
the next capture. Failure keeps the exact draft, selected task intent, and
admitted request. Re-saving an unchanged failed capture reuses its mutation
identity. Changing either text or task intent after a terminal failure ends the
failed attempt under the same direct-capture replacement rules; it must not
silently turn an unknown commit outcome into a new mutation.

Deliberately dismissing the composer without saving preserves the exact draft
and selected task intent. Reopening the composer restores both values; only a
successful persistence resets them for the next capture.

## Decision

Retain the Capture task selector and authoritative save path.

## Alternatives considered

### More task states in Capture

Rejected because Capture needs a single optional task flag. Exact status selection belongs to the row context menu's status sheet.

## Acceptance criteria

- Task intent can be selected before typing without changing the draft, focus or editor selection.
- Save snapshots exact source and task intent; failure retains both and success resets both.
- Pending saves prevent duplicate submission; dismissing and reopening preserves unsaved intent.

## Consequences

Capture task intent, drafts and authoritative save behavior remain; only obsolete block swipe content was removed from this historical decision.

## Risks

- An unchanged failed save must retain its mutation identity until its outcome is terminal.

## Questions

None. Capture keeps its existing binary task contract.
