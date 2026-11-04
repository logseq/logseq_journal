module Graph = Logseq_db_types.Graph_types
module Uuid = Graph.Uuid
module Data = Worker_pure_data

type account_generation = int
type graph_generation = int
type worker_incarnation =
  { runtime_epoch : Journal_worker_ids.Runtime.epoch
  ; worker_generation : Journal_worker_ids.Worker.generation
  }

type binding =
  { serial : int64
  ; incarnation : worker_incarnation
  ; origin : string
  ; user : string
  }

type session =
  { binding : binding
  ; graph : Uuid.t
  ; account : account_generation
  ; lifecycle : int64
  ; generation : graph_generation
  ; scope : Logseq_sync_pure_reducer.Core.timeline_scope
  ; asset_scope : Logseq_sync_pure_reducer.Core.graph_scope
  ; limits : Worker_pure_data.capability_limits
  }

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


type read_budget =
  { owner : session
  ; maximum_items : int
  ; maximum_bytes : int
  }

type journal_day = int

type page =
  { data : Graph.page
  ; revision : string
  }

type block =
  { data : Worker_pure_data.block_record
  ; revision : string
  }

type 'a continuation =
  { owner : session
  ; key : string
  ; budget : read_budget
  ; cursor : Graph.Cursor.t
  }

type 'a slice =
  { items : 'a list
  ; next : 'a continuation option
  }

type graph_info =
  { graph_uuid : Uuid.t
  ; graph_name : string
  ; schema : Graph.schema_version
  ; admission_facts : Graph.admission_fact list
  ; journal_title_format : string option
  ; limits : Worker_pure_data.capability_limits
  ; generation : string
  ; projection_revision : string
  }

type block_summary =
  { lookup : Worker_pure_data.block_lookup
  ; page : Worker_pure_data.page_lookup option
  ; items : Worker_pure_data.child_member list
  ; next : Worker_pure_data.child_member continuation option
  ; scope_revision : string
  ; generation : string
  ; projection_revision : string
  }

type favorites =
  { favorites_page : Uuid.t option
  ; generation : string
  ; projection_revision : string
  ; items : Worker_pure_data.favorite_item list
  ; next : Worker_pure_data.favorite_item continuation option
  }

type task_status_catalog =
  { property_uuid : Uuid.t option
  ; default_status : Uuid.t option
  ; items : Graph.task_status_definition list
  ; next : Graph.task_status_definition continuation option
  }

type asset_listing =
  { generation : string
  ; projection_revision : string
  ; items : Logseq_db_types.Asset_descriptor.t list
  ; next : Logseq_db_types.Asset_descriptor.t continuation option
  }

type children =
  { parent : Uuid.t
  ; revision_scope : Worker_pure_data.revision_scope
  ; scope_revision : string
  ; items : Worker_pure_data.child_member list
  ; next : Worker_pure_data.child_member continuation option
  }

type change_batch =
  { change_owner : session
  ; generation : string
  ; from_exclusive : string option
  ; through : string
  ; windows : Worker_pure_data.change_window list
  ; next : string option
  }

type change_ack =
  { ack_owner : session
  ; generation : string
  ; through : string
  }

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

let binding_incarnation (b : binding) = b.incarnation

let equal_binding (a : binding) (b : binding) =
  a.serial = b.serial
  && Journal_worker_ids.Runtime.Epoch.equal
       a.incarnation.runtime_epoch
       b.incarnation.runtime_epoch
  && Journal_worker_ids.Worker.Generation.equal
       a.incarnation.worker_generation
       b.incarnation.worker_generation
;;

let account_generation (s : session) = s.account
let graph_generation (s : session) = s.generation
let graph_id (s : session) = s.graph

let equal_session (a : session) (b : session) =
  equal_binding a.binding b.binding
  && a.account = b.account
  && a.lifecycle = b.lifecycle
  && a.generation = b.generation
  && Uuid.equal a.graph b.graph
;;

let compare_session (a:session)(b:session)=
  let key (s:session)=(s.binding.incarnation,s.binding.serial,s.binding.origin,s.binding.user,
    s.account,s.lifecycle,s.generation,s.graph) in
  Stdlib.compare(key a)(key b)
;;

let matches_asset_scope (session:session) (scope:Logseq_sync_pure_reducer.Core.graph_scope)=
  let expected=session.asset_scope in
  expected.graph_id=scope.graph_id && expected.graph_generation=scope.graph_generation
  && expected.account.user_id=scope.account.user_id
  && Uri.equal expected.account.managed_sync_origin scope.account.managed_sync_origin
  && expected.account.account_generation=scope.account.account_generation
  && expected.account.lifecycle_generation=scope.account.lifecycle_generation
;;

let same_logical_graph (a : session) (b : session) =
  a.binding.origin = b.binding.origin
  && a.binding.user = b.binding.user
  && Uuid.equal a.graph b.graph
;;

let matches_scope (session : session) (scope : Logseq_sync_pure_reducer.Core.timeline_scope) =
  session.account = scope.startup.account_generation
  && session.generation = scope.graph_generation
  && Uuid.equal session.graph scope.graph_id
;;

let worker_incarnation ~runtime_epoch ~worker_generation =
  { runtime_epoch; worker_generation }
;;


let read_budget (owner : session) ~maximum_items ~maximum_bytes =
  if
    maximum_items <= 0
    || maximum_items > Worker_pure_data.maximum_page_size
    || maximum_bytes <= 0
    || maximum_bytes > owner.limits.response_budget_bytes
  then Error (Invalid_input "Read budget exceeds advertised limits")
  else Ok { owner; maximum_items; maximum_bytes }
;;

let journal_day day =
  let year = day / 10000
  and month = day / 100 mod 100
  and date = day mod 100 in
  let leap = year mod 400 = 0 || (year mod 4 = 0 && year mod 100 <> 0) in
  let days =
    match month with
    | 2 -> if leap then 29 else 28
    | 4 | 6 | 9 | 11 -> 30
    | _ -> 31
  in
  if year < 1 || year > 9999 || month < 1 || month > 12 || date < 1 || date > days
  then Error (Invalid_input "Invalid journal day")
  else Ok day
;;

let page_uuid (p : page) = p.data.uuid
let page_title (p : page) = p.data.title
let page_data (p : page) = p.data
let page_revision (p : page) = p.revision
let block_uuid (b : block) = b.data.block.uuid
let block_title (b : block) = b.data.block.title
let block_data (b : block) = b.data
let block_revision (b : block) = b.revision
let change_batch_session (batch : change_batch) = batch.change_owner
let change_ack_session (ack : change_ack) = ack.ack_owner
let change_ack_generation (a : change_ack) = a.generation
let change_ack_through (a : change_ack) = a.through

module For_worker = struct
  let worker_incarnation_runtime_epoch (value:worker_incarnation) = value.runtime_epoch
  let worker_incarnation_worker_generation (value:worker_incarnation) = value.worker_generation
  let binding ~serial ~incarnation ~origin ~user : binding = { serial; incarnation; origin; user }
  let binding_serial (value:binding) = value.serial
  let binding_origin (value:binding) = value.origin
  let binding_user (value:binding) = value.user
  let session ~binding ~graph ~account ~lifecycle ~generation ~scope ~asset_scope ~limits : session = { binding; graph; account; lifecycle; generation; scope; asset_scope; limits }
  let session_binding (value:session) = value.binding
  let session_account (value:session) = value.account
  let session_lifecycle (value:session) = value.lifecycle
  let session_generation (value:session) = value.generation
  let session_scope (value:session) = value.scope
  let session_asset_scope (value:session) = value.asset_scope
  let session_limits (value:session) = value.limits
  let read_budget ~owner ~maximum_items ~maximum_bytes : read_budget = { owner; maximum_items; maximum_bytes }
  let read_budget_owner (value:read_budget) = value.owner
  let read_budget_maximum_items (value:read_budget) = value.maximum_items
  let read_budget_maximum_bytes (value:read_budget) = value.maximum_bytes
  let page ~data ~revision : page = { data; revision }
  let block ~data ~revision : block = { data; revision }
  let continuation ~owner ~key ~budget ~cursor : 'a continuation = { owner; key; budget; cursor }
  let continuation_owner (value:'a continuation) = value.owner
  let continuation_key (value:'a continuation) = value.key
  let continuation_budget (value:'a continuation) = value.budget
  let continuation_cursor (value:'a continuation) = value.cursor
  let slice ~items ~next : 'a slice = { items; next }
  let graph_info ~graph_uuid ~graph_name ~schema ~admission_facts ~journal_title_format ~limits ~generation ~projection_revision : graph_info = { graph_uuid; graph_name; schema; admission_facts; journal_title_format; limits; generation; projection_revision }
  let block_summary ~lookup ~page ~items ~next ~scope_revision ~generation ~projection_revision : block_summary = { lookup; page; items; next; scope_revision; generation; projection_revision }
  let favorites ~favorites_page ~generation ~projection_revision ~items ~next : favorites = { favorites_page; generation; projection_revision; items; next }
  let task_status_catalog ~property_uuid ~default_status ~items ~next : task_status_catalog = { property_uuid; default_status; items; next }
  let asset_listing ~generation ~projection_revision ~items ~next : asset_listing = { generation; projection_revision; items; next }
  let children ~parent ~revision_scope ~scope_revision ~items ~next : children = { parent; revision_scope; scope_revision; items; next }
  let change_batch ~change_owner ~generation ~from_exclusive ~through ~windows ~next : change_batch = { change_owner; generation; from_exclusive; through; windows; next }
  let change_ack ~ack_owner ~generation ~through : change_ack = { ack_owner; generation; through }
  let journal_day_value (day:journal_day) = day
end
