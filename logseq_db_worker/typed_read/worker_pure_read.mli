(** {1 TLDR}
    Define pure typed read queries and sealed session-owned paging values for the
    existing Worker coordination channel. The effect runner executes packed
    queries and validates complete final DTOs against advertised budgets. This
    module performs no I/O and owns no snapshot, subscription or persistence.
    Timeline reads carry local-scope receipts; other read families retain their
    existing projection-bound continuation semantics.

    {1 Minimal usage example}
    Trusted Worker code receives [session] from its live authority and sends the
    packed query to its existing executor:
    {[
      match read_budget session ~maximum_items:20 ~maximum_bytes:65536 with
      | Error error -> report error
      | Ok budget ->
        execute (For_worker.pack_query budget
          (Timeline_read { query = Timeline.roots ~page; after = None }))
    ]}
    [page], [report] and [execute] are caller-provided values. Application code
    obtains these types through Worker_api and submits its typed Query request.

    {1 Construction and validation} *)
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
    Requests also validate effective limits on IDs, roots, depth, payload and lists.
    [Timeline_check] produces one aggregate check value: its receipt/result vector
    uses [Timeline.maximum_receipts], independently of the data-row item budget,
    and the complete encoded check value still fits the byte budget. *)
val read_budget
  :  session
  -> maximum_items:int
  -> maximum_bytes:int
  -> (read_budget, error) result

type journal_day = Logseq_db_worker_contract.Worker_pure_day.t

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

val continuation_budget : 'a continuation -> read_budget

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

type asset_lookup_result = private
  { generation : string
  ; projection_revision : string
  ; items : Logseq_db_types.Asset_descriptor.t option list
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
module Timeline : sig
  (** {1 TLDR}
      Typed queries enumerate dates, direct page roots or direct preview children.
      Every packet, including an empty final packet, carries a freshness receipt.
      Execute through [Timeline_read] and validate retained receipts together with
      [Timeline_check]; each request borrows and releases one immutable snapshot. *)
  module Day = Logseq_db_worker_contract.Worker_pure_day
  type worker_error = error
  type _ query = private
    | Dates : { from_day : Day.t; through_day : Day.t } -> Data.journal_item query
    | Roots : Graph.page_uuid -> Data.tree_member query
    | Preview_children : Graph.block_uuid -> Data.child_member query
  type invalidation = Owner_changed | Scope_changed
  type error =
    | Invalid_request of string
    | Invalidated of invalidation
    | Read_failed of worker_error
    | Limit_exceeded of string
    | Invalid_source_reply of string
  type 'a receipt
  type 'a cursor
  type 'a remaining = End | More of 'a cursor
  type 'a packet = private { items : 'a Rrbvec.t; receipt : 'a receipt; next : 'a remaining }
  type packed_receipt = Receipt : 'a receipt -> packed_receipt
  type check = private { results : (unit, error) result Rrbvec.t }
  val maximum_receipts : int

  (** {1 Minimal usage example}
      The caller supplies [page], [budget] and the existing session executor [run]:
      {[
        let query = roots ~page in
        match run (Timeline_read { query; after = None }) with
        | Ok (Ok packet) -> retain packet.items packet.receipt packet.next
        | Ok (Error error) -> report_paging_error error
        | Error error -> report_worker_error error
      ]}
      [retain], [report_paging_error] and [report_worker_error] are caller
      callbacks. Worker transport errors remain separate from the inner paging
      result. *)

  (** {1 Construction and validation} *)
  val dates : from_day:Day.t -> through_day:Day.t -> Data.journal_item query
  val roots : page:Graph.page_uuid -> Data.tree_member query
  val preview_children : parent:Graph.block_uuid -> Data.child_member query

  (** {1 Lifecycle and recovery}
      Cursors and receipts bind the exact session owner, query and write-maintained
      DB scope version. They contain bounded values only and do not survive owner
      revocation. A changed scope invalidates both an active continuation and an
      exhausted receipt. Drop that scope's prefix before reloading; another scope
      may remain loaded. [Timeline_check] checks its bounded vector against one
      borrowed snapshot, preserves input order and returns every concrete cause.
      Freshness uses authoritative lookups, never collection scans or global
      projection revisions. Dates cover the journal index; roots and previews
      cover only their returned direct-member DTOs. A packet bound includes the
      final enriched DTOs, receipt and continuation. Oversized singletons fail.
      Error control frames are outside the successful packet data-byte budget.
      Inverted date ranges are empty. Outline ordering preserves DB tie behavior.
      Visibility and selecting three preview summaries remain caller-owned. *)
  val equal_query : 'a query -> 'a query -> bool
  val error_message : error -> string
end

type _ query =
  | Timeline_read : { query : 'a Timeline.query; after : 'a Timeline.cursor option }
      -> ('a Timeline.packet, Timeline.error) result query
  | Timeline_check : Timeline.packed_receipt Rrbvec.t -> Timeline.check query
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
  | Asset_descriptors : Uuid.t list -> asset_lookup_result query
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


type packed_query = private Read_query : read_budget * 'a query -> packed_query
type answer = private Query_answer : read_budget * 'a query * ('a,error) result -> answer

type (_, _) equality = Refl : ('a, 'a) equality
val query_result_equality : 'a query -> 'b query -> ('a, 'b) equality option

val change_batch_session : change_batch -> session

val change_ack_session : change_ack -> session
val change_ack_generation : change_ack -> string
val change_ack_through : change_ack -> string


(** Trusted construction and access to original representations. Business
    libraries depend on Worker_api and cannot name this implementation library. *)
module For_worker : sig
  val timeline_check : (unit, Timeline.error) result Rrbvec.t -> Timeline.check
  val timeline_receipt : owner:session -> query:'a Timeline.query -> version:string -> 'a Timeline.receipt
  val timeline_packet : receipt:'a Timeline.receipt -> items:'a Rrbvec.t -> next:string option -> 'a Timeline.packet
  val timeline_cursor_position : 'a Timeline.cursor -> string
  val timeline_cursor_receipt : 'a Timeline.cursor -> 'a Timeline.receipt
  val timeline_receipt_owner : 'a Timeline.receipt -> session
  val timeline_receipt_query : 'a Timeline.receipt -> 'a Timeline.query
  val timeline_receipt_version : 'a Timeline.receipt -> string

  val pack_query : read_budget -> 'a query -> packed_query
  val answer : read_budget -> 'a query -> ('a,error) result -> answer
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
  val asset_lookup_result : generation:string -> projection_revision:string -> items:Logseq_db_types.Asset_descriptor.t option list -> asset_lookup_result
  val asset_listing : generation:string -> projection_revision:string -> items:Logseq_db_types.Asset_descriptor.t list -> next:Logseq_db_types.Asset_descriptor.t continuation option -> asset_listing
  val children : parent:Uuid.t -> revision_scope:Worker_pure_data.revision_scope -> scope_revision:string -> items:Worker_pure_data.child_member list -> next:Worker_pure_data.child_member continuation option -> children
  val change_batch : change_owner:session -> generation:string -> from_exclusive:string option -> through:string -> windows:Worker_pure_data.change_window list -> next:string option -> change_batch
  val change_ack : ack_owner:session -> generation:string -> through:string -> change_ack
  val journal_day_value : journal_day -> int
end

(** Pure validation and ephemeral continuation identity for the original query.
    No transport envelope is constructed. *)
val query_key : read_budget -> 'a query -> string
val query_cursor : session -> read_budget -> 'a query -> (Graph.Cursor.t option,error) result
val checked_query : session -> read_budget -> 'a query -> (Graph.Cursor.t option,error) result
val validate_query : session -> read_budget -> 'a query -> (unit,error) result
val observable : 'a query -> bool

(** Size the complete enriched result and continuation payload. Timeline packets
    include their receipt and any continuation receipt, including owner/query
    identities; check values include every receipt result. Other query families
    retain their existing data-only encoding. *)
val encoded_value_bytes : 'a query -> 'a -> int
val validate_value : session -> read_budget -> 'a query -> 'a -> (unit,error) result

val equal_packed_query : packed_query -> packed_query -> bool

(** Pure next fetch bound for the same original query. No new query, session,
    budget or cursor is minted. A singleton fails rather than losing data. *)
val smaller_page_size : 'a query -> int -> int option
