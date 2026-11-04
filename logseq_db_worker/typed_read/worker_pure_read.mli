(** App/Worker coordination boundary. Pure data belongs to [Worker_pure_data];
    sealed authority is issued by the trusted
    Worker runner. Abstraction is not authentication: every message, continuation,
    receipt and resource is validated against its actual channel and owner. *)
module Graph = Logseq_db_types.Graph_types

module Uuid = Graph.Uuid
module Data = Worker_pure_data

type account_generation
type graph_generation
type worker_incarnation
type binding

val binding_incarnation : binding -> worker_incarnation
val equal_binding : binding -> binding -> bool

type session
val account_generation : session -> account_generation
val graph_generation : session -> graph_generation
val graph_id : session -> Uuid.t
val equal_session : session -> session -> bool
val compare_session : session -> session -> int
val same_logical_graph : session -> session -> bool
val matches_scope : session -> Logseq_sync_pure_reducer.Core.timeline_scope -> bool
val matches_asset_scope : session -> Logseq_sync_pure_reducer.Core.graph_scope -> bool

val worker_incarnation
  :  runtime_epoch:Journal_worker_ids.Runtime.epoch
  -> worker_generation:Journal_worker_ids.Worker.generation
  -> worker_incarnation

(** Sessions survive focus changes while resident. Close/reopen, account changes,
    removal and rebinding revoke execution authority. Presentation has a separate
    lifetime. Admission and completion recheck all identities, not just UUID. *)
type error =
  | Revoked_session
  | Invalid_input of string
  | Response_budget_exceeded
  | Stale_read of string
  | Resync_required of string
  | Host_change_in_progress
  | Protocol_mismatch of string
  | Db_error of Logseq_db_worker_contract.Error.t
  | Service_failed of string
  | Unsupported_operation of string




type read_budget

(** Validate positive item/encoded-byte bounds against this session's advertised
    limits. Every final enriched result, including summary/refs/properties, fits
    both bounds. An oversized singleton fails explicitly; no silent truncation.
    Requests also validate Protocol limits on IDs, roots, depth, payload and lists. *)
val read_budget
  :  session
  -> maximum_items:int
  -> maximum_bytes:int
  -> (read_budget, error) result

type journal_day

val journal_day : int -> (journal_day, error) result

type page
type block

val page_uuid : page -> Uuid.t
val page_title : page -> string
val block_uuid : block -> Uuid.t
val block_title : block -> string

(** Full storage-independent DTOs retain timestamps, parent/page/order, properties,
    source title, refs/tags, rendered titles and task status used by current App
    projections. Missing/recycled objects remain distinguishable in lookup queries.
    Values grant no execution authority. Revisions are scoped opaque protocol text,
    never parsed or compared lexically as counters. *)
val page_data : page -> Graph.page

val page_revision : page -> string
val block_data : block -> Worker_pure_data.block_record
val block_revision : block -> string

type 'a continuation

type 'a slice = private
  { items : 'a list
  ; next : 'a continuation option
  }

(** At most Data.maximum_page_size items (<1000). A continuation is bound to
    session, query kind, parameters, budget and revision. Only its item type is a
    static guarantee; runtime rejects a different parent/range/depth/filter or
    stale snapshot. Ordinary reads do not change an observation epoch. *)

type graph_info = private
  { graph_uuid : Uuid.t
  ; graph_name : string
  ; schema : Graph.schema_version
  ; admission_facts : Graph.admission_fact list
  ; journal_title_format : string option
  ; limits : Worker_pure_data.capability_limits
  ; generation : string
  ; projection_revision : string
  }

type block_summary = private
  { lookup : Worker_pure_data.block_lookup
  ; page : Worker_pure_data.page_lookup option
  ; items : Worker_pure_data.child_member list
  ; next : Worker_pure_data.child_member continuation option
  ; scope_revision : string
  ; generation : string
  ; projection_revision : string
  }

(** Canonical target, owning page and direct children share one DB snapshot,
    as in today's V2_get_outline_block_summary. Count is exact only at next=None.
    No sequential page/children calls may masquerade as this atomic summary. *)
type favorites = private
  { favorites_page : Uuid.t option
  ; generation : string
  ; projection_revision : string
  ; items : Worker_pure_data.favorite_item list
  ; next : Worker_pure_data.favorite_item continuation option
  }

type task_status_catalog = private
  { property_uuid : Uuid.t option
  ; default_status : Uuid.t option
  ; items : Graph.task_status_definition list
  ; next : Graph.task_status_definition continuation option
  }

type asset_listing = private
  { generation : string
  ; projection_revision : string
  ; items : Logseq_db_types.Asset_descriptor.t list
  ; next : Logseq_db_types.Asset_descriptor.t continuation option
  }

type children = private
  { parent : Uuid.t
  ; revision_scope : Worker_pure_data.revision_scope
  ; scope_revision : string
  ; items : Worker_pure_data.child_member list
  ; next : Worker_pure_data.child_member continuation option
  }

type change_batch = private
  { change_owner : session
  ; generation : string
  ; from_exclusive : string option
  ; through : string
  ; windows : Worker_pure_data.change_window list
  ; next : string option
  }

type change_ack = private
  { ack_owner : session
  ; generation : string
  ; through : string
  }

(** Typed forms of the existing App query families, not an untyped command escape
    hatch. Journal is a bounded single-day convenience; it preserves page revision
    and never creates a page. Children serves simple consumers; Child_members also
    exposes the exact scope revision required by current planners/confirmation.
    Typed results preserve present/missing and full metadata without UI layout
    types. List/lookup result ordering matches input IDs, including missing slots. *)
type _ query =
  | Graph_info : graph_info query
  | Admission : Worker_pure_data.admission_inspection query
  | Journal : journal_day -> page option query
  | Journals :
      { from_day : journal_day
      ; through_day : journal_day
      ; revision : string option
      ; after : Worker_pure_data.journal_item continuation option
      }
      -> Worker_pure_data.journal_item slice query
  | Page :
      { uuid : Uuid.t
      ; revision : string option
      }
      -> Worker_pure_data.page_lookup query
  | Outline_block :
      { uuid : Uuid.t
      ; revision : string option
      }
      -> Worker_pure_data.block_lookup query
  | Block_summary :
      { block : Uuid.t
      ; after : Worker_pure_data.child_member continuation option
      }
      -> block_summary query
  | Children :
      { parent : Uuid.t
      ; after : block continuation option
      }
      -> block slice query
  | Child_members :
      { parent : Uuid.t
      ; revision : string option
      ; after : Worker_pure_data.child_member continuation option
      }
      -> children query
  | Tree :
      { page : Uuid.t
      ; maximum_depth : int
      ; revision : string option
      ; after : Worker_pure_data.tree_member continuation option
      }
      -> Worker_pure_data.tree_member slice query
  | Favorites : Worker_pure_data.favorite_item continuation option -> favorites query
  | Task_statuses :
      Graph.task_status_definition continuation option
      -> task_status_catalog query
  | Task_status_definitions :
      Uuid.t list
      -> Graph.task_status_definition option list query
  | Asset_descriptors : Uuid.t list -> asset_listing query
  | Assets :
      { recursive : bool
      ; roots : Uuid.t list
      ; after : Logseq_db_types.Asset_descriptor.t continuation option
      }
      -> asset_listing query
  | Changes :
      { generation : string
      ; after : string option
      }
      -> change_batch query


val change_batch_session : change_batch -> session

val change_ack_session : change_ack -> session
val change_ack_generation : change_ack -> string
val change_ack_through : change_ack -> string


(** Trusted construction and access to original representations. Business
    libraries depend on Worker_api and cannot name this implementation library. *)
module For_worker : sig
  val worker_incarnation_runtime_epoch : worker_incarnation -> Journal_worker_ids.Runtime.epoch
  val worker_incarnation_worker_generation : worker_incarnation -> Journal_worker_ids.Worker.generation
  val binding : serial:int64 -> incarnation:worker_incarnation -> origin:string -> user:string -> binding
  val binding_serial : binding -> int64
  val binding_origin : binding -> string
  val binding_user : binding -> string
  val session : binding:binding -> graph:Uuid.t -> account:int -> lifecycle:int64 -> generation:int -> scope:Logseq_sync_pure_reducer.Core.timeline_scope -> asset_scope:Logseq_sync_pure_reducer.Core.graph_scope -> limits:Worker_pure_data.capability_limits -> session
  val session_binding : session -> binding
  val session_account : session -> int
  val session_lifecycle : session -> int64
  val session_generation : session -> int
  val session_scope : session -> Logseq_sync_pure_reducer.Core.timeline_scope
  val session_asset_scope : session -> Logseq_sync_pure_reducer.Core.graph_scope
  val session_limits : session -> Worker_pure_data.capability_limits
  val read_budget : owner:session -> maximum_items:int -> maximum_bytes:int -> read_budget
  val read_budget_owner : read_budget -> session
  val read_budget_maximum_items : read_budget -> int
  val read_budget_maximum_bytes : read_budget -> int
  val page : data:Graph.page -> revision:string -> page
  val block : data:Worker_pure_data.block_record -> revision:string -> block
  val continuation : owner:session -> key:string -> budget:read_budget -> cursor:Graph.Cursor.t -> 'a continuation
  val continuation_owner : 'a continuation -> session
  val continuation_key : 'a continuation -> string
  val continuation_budget : 'a continuation -> read_budget
  val continuation_cursor : 'a continuation -> Graph.Cursor.t
  val slice : items:'a list -> next:'a continuation option -> 'a slice
  val graph_info : graph_uuid:Uuid.t -> graph_name:string -> schema:Graph.schema_version -> admission_facts:Graph.admission_fact list -> journal_title_format:string option -> limits:Worker_pure_data.capability_limits -> generation:string -> projection_revision:string -> graph_info
  val block_summary : lookup:Worker_pure_data.block_lookup -> page:Worker_pure_data.page_lookup option -> items:Worker_pure_data.child_member list -> next:Worker_pure_data.child_member continuation option -> scope_revision:string -> generation:string -> projection_revision:string -> block_summary
  val favorites : favorites_page:Uuid.t option -> generation:string -> projection_revision:string -> items:Worker_pure_data.favorite_item list -> next:Worker_pure_data.favorite_item continuation option -> favorites
  val task_status_catalog : property_uuid:Uuid.t option -> default_status:Uuid.t option -> items:Graph.task_status_definition list -> next:Graph.task_status_definition continuation option -> task_status_catalog
  val asset_listing : generation:string -> projection_revision:string -> items:Logseq_db_types.Asset_descriptor.t list -> next:Logseq_db_types.Asset_descriptor.t continuation option -> asset_listing
  val children : parent:Uuid.t -> revision_scope:Worker_pure_data.revision_scope -> scope_revision:string -> items:Worker_pure_data.child_member list -> next:Worker_pure_data.child_member continuation option -> children
  val change_batch : change_owner:session -> generation:string -> from_exclusive:string option -> through:string -> windows:Worker_pure_data.change_window list -> next:string option -> change_batch
  val change_ack : ack_owner:session -> generation:string -> through:string -> change_ack
  val journal_day_value : journal_day -> int
end
