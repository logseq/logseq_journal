(** A1 Timeline filters: one toolbar entry and a transactional bottom sheet.
    Settings only. Timeline owns query construction, matching, and paging. *)

module Uuid = Logseq_db_types.Graph_types.Uuid

type tag_id = Uuid.t
type status_id = Uuid.t

type unit_ =
  | Days
  | Weeks

type preset =
  | Past_7_days
  | Past_2_weeks

type relative_time
type time_error = Invalid_count

val any_time : relative_time
val preset : preset -> relative_time

(** The custom count is a positive integer. Reject arithmetic overflow rather
    than wrapping or silently changing the number or unit. *)
val custom : count:int -> unit_:unit_ -> (relative_time, time_error) result

(** Preserve the user's choice: custom 2 weeks and the 2-week preset match the
    same date range but reopen in different controls. *)
val time_choice
  :  relative_time
  -> [ `Any_time | `Preset of preset | `Custom of int * unit_ ]

type criteria

(** No tag or status selected, with [any_time]. The default Timeline settings. *)
val all : criteria

(** Construct settings from validated values, e.g. after decoding local
    preferences. Duplicate selections are removed. *)
val criteria
  :  tags:tag_id list
  -> statuses:status_id list
  -> time:relative_time
  -> criteria

val tags : criteria -> tag_id list
val statuses : criteria -> status_id list
val time : criteria -> relative_time

(** Count active groups (0..3), not selections. Only the Filters button is
    shown on Timeline; no summary row and no Clear all row. An empty result
    keeps Filters available and may offer an action to reopen the sheet. *)
val active_count : criteria -> int

(** State for the active graph. The sheet draft is ephemeral. Only applied
    criteria are saved by the App host in per-graph UserDefaults; this module
    performs no persistence and nothing is written to the graph. Favorites and
    Capture do not consume filter state. *)
type t

val initial : t

(** Start with the active graph's loaded criteria and a closed sheet. Use
    [initial] if that graph has no valid saved settings. *)
val restore : criteria -> t

val applied : t -> criteria

type sheet

val sheet : t -> sheet option
val draft_tags : sheet -> tag_id list
val draft_statuses : sheet -> status_id list

type time_control =
  | Any_time
  | Preset of preset
  | Custom of
      { count_text : string
      ; unit_ : unit_
      }

val draft_time : sheet -> time_control

(** Show Any time, 7 days, 2 weeks, and Custom. Only Custom exposes the numeric
    input and Days/Weeks selector. Raw text can be partial or invalid; show the
    error near the field and do not apply a previous valid value in its place.
    The returned value is a relative setting, not an absolute date range. *)
val validate_draft_time : sheet -> (relative_time, time_error) result

(** Copy applied criteria into a draft. Opening an already-open sheet is a no-op. *)
val open_sheet : t -> t

type edit =
  | Toggle_tag of tag_id
  | Toggle_status of status_id
  | Set_time of time_control
  | Reset

(** Edit the open draft only; ignore edits while closed. Toggles are independent
    and maintain unique IDs. Labels and available options are supplied by the
    active graph; selections do not depend on the current search results. Reset
    clears all draft groups, including time; Apply is still required. *)
val edit : t -> edit -> t

(** Cancel or dismiss discards the sheet without touching applied criteria. *)
val cancel : t -> t

(** Validate the draft, then commit and close it atomically. When closed this
    is a no-op. On error the caller retains its unchanged state and open sheet. *)
val apply : t -> (t, time_error) result
