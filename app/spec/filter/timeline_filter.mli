(** Named Timeline filters and the transactional configuration sheet.

    {1 TLDR}

    The App owns one [t] per active graph. [entry] chooses direct configuration
    or a native menu; [submit] applies a draft, saves and selects a name,
    selects an existing name, or clears the current filter. The host owns
    graph-local UserDefaults and installs the [next] state only after any
    required preference replacement succeeds. [restore] takes the validated
    graph preferences before the first Timeline feed request. Timeline still
    owns date resolution, query construction, matching, and paging.

    {1 Minimal usage example}

    Given the active graph's validated [preferences], [publish] installs state
    and updates the existing feed if effective criteria changed. The host's
    [commit] replaces the graph record and returns a result; [report] surfaces
    failures. Run the command in the graph owner's serialized turn.
    {[
      let restored = restore preferences in
      publish restored;
      let draft = open_sheet restored in
      match submit draft Apply with
      | Error error -> report (`Filter error)
      | Ok { next; replacement = None } -> publish next
      | Ok { next; replacement = Some preferences } ->
        (match commit preferences with
         | Ok () -> publish next
         | Error error -> report (`Storage error))
    ]}

    {1 Criteria and relative time} *)

module Uuid = Logseq_db_types.Graph_types.Uuid

type tag_id = Uuid.t
type status_id = Uuid.t

type unit_ =
  | Days
  | Weeks

type preset =
  | Past_14_days
  | Past_3_months

type relative_time
type time_error = Invalid_count

val any_time : relative_time
val preset : preset -> relative_time

(** The custom count is a positive integer. Reject arithmetic overflow rather
    than wrapping or silently changing the number or unit. *)
val custom : count:int -> unit_:unit_ -> (relative_time, time_error) result

(** Preserve the user's choice: custom 2 weeks and the 14-day preset match the
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

(** Count active groups (0..3), not selections or named definitions. *)
val active_count : criteria -> int

(** {1 Graph preferences and restoration} *)

type preferences

type preference_error =
  | Empty_name
  | Duplicate_name
  | Name_too_long
  | Too_many_filters
  | Too_many_selections
  | Unknown_selection

val empty_preferences : preferences

(** Validate a decoded graph record. Proposed policy: trim surrounding
    whitespace, reject empty names and exact case-sensitive duplicates after
    trimming, and never overwrite a definition. Allow at most five saved
    definitions per graph. Each name is at most 128 UTF-8 bytes after trimming;
    each criteria group allows up to 100 unique IDs. A selected name must refer
    to a definition in the same record.
    Reject payloads exceeding 512 KiB before decoding; enforce collection
    limits during decoding as well as on the validated record. Validate UUIDs,
    UTF-8 and relative time. Retain definition order. *)
val preferences
  :  definitions:(string * criteria) list
  -> selected_name:string option
  -> (preferences, preference_error) result

val definitions : preferences -> (string * criteria) list
val selected_name : preferences -> string option

(** The host stores the definitions and optional selected name in one record
    per graph in UserDefaults, never in graph data. No draft or anonymous
    criteria are persisted. Missing or legacy anonymous records start empty;
    do not migrate anonymous criteria into named definitions. Surface invalid
    records and start unfiltered without rewriting them on read. *)
type t

(** Restore the selected named criteria, or [all], with a closed sheet. On
    startup and graph switch, restore before the first feed request for that
    graph. Resolve relative time against the current local day as before, not
    the save date. Feed matching, existing OR semantics and paging are unchanged;
    Favorites and Capture do not consume filter state. *)
val restore : preferences -> t

val applied : t -> criteria

(** {1 Toolbar and draft} *)

type entry =
  | Configure_directly
  | Native_menu of
      { names : string list
      ; active_name : string option
      }

(** With no saved definitions, the icon opens configuration directly.
    Otherwise show all names in stored order in a native menu, mark the active
    name (never mark one for an anonymous filter), then show Clear filter and
    Configure filters, with Configure filters last. An empty feed still offers
    access to Filters. *)
val entry : t -> entry

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

(** Show Any time, 14 days, 3 months, and Custom. The 3-month preset starts on
    the same day of the month three Gregorian calendar months before today,
    clamped to that month's last day if necessary. Both endpoints are inclusive.
    Only Custom exposes the numeric input and Days/Weeks selector. Raw text can be partial or invalid; show the
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

(** Cancel or dismiss the configuration sheet without touching applied
    criteria or preferences. Save and Apply are text-only buttons in the same
    row, with equal width and height and centered labels. Apply retains primary
    styling; Save uses secondary styling. *)
val cancel : t -> t

(** Save opens naming over the same draft; canceling naming returns to that
    draft unchanged. The host owns the naming prompt and its input. Do not use
    an existing name as an implicit overwrite. *)

(** {1 Apply, save, select, and clear} *)

type command =
  | Apply
  | Save_as of string
  | Select of string
  | Clear

type error =
  | Invalid_time of time_error
  | Invalid_preferences of preference_error
  | No_open_sheet
  | Unknown_name

type transition = private
  { next : t
  ; replacement : preferences option
  }

(** Apply and Save_as validate the open draft and close it on success.
    Apply activates anonymous criteria in memory and clears any persisted
    selected name, so reopening the graph starts at [all]. Save_as appends
    a definition and selects it in the same replacement, then applies it.
    At five saved definitions, Save_as rejects an additional definition with
    [Invalid_preferences Too_many_filters]. Show the limit without discarding
    the draft or changing the current selection. Apply remains available at
    capacity; it does not add a definition.
    Select activates an existing name and persists the selection. Clear
    applies [all] and clears the selected name without deleting definitions.
    Select and Clear do not modify a draft. Validation errors preserve the
    draft, active criteria and preferences. Keep naming open with feedback
    for a rejected name; surface draft errors in the sheet.

    [None] means the preferences did not change. For [Some], the App host
    serializes read/modify/replace through one owner per graph, deriving each
    command from the latest committed graph record, never a sheet-open
    snapshot. Replace the whole record in one UserDefaults operation. Install
    [next] and expose the change to the feed only after the host acknowledges
    that it accepted and applied the replacement to UserDefaults. This is not
    a guarantee of synchronous disk flush. On rejection retain the previous
    state and surface the error. Do not publish
    a completion to a different or reopened graph session. A selection-only
    change with identical effective criteria need not reload the feed. *)
val submit : t -> command -> (transition, error) result
