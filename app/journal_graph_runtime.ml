module Graph = Logseq_db_types.Graph_types
module Error = Logseq_db_worker.Error
module Projection = Journal_graph_projection
module Reference = Journal_graph_reference_plan
module Favorites = Journal_graph_favorites_plan
module Feed = Journal_graph_feed_plan
module Confirmation = Journal_graph_mutation_confirmation
module Child = Journal_graph_mutation_confirmation.Pure_insertion
module Worker = Journal_worker_coordination.Worker_api
module Coordination = Journal_worker_coordination.Worker_pure_coordinator

type worker_read_result =
  | Query_result : 'a Worker.query * 'a -> worker_read_result
  | Read_failed of { code : Logseq_db_worker.Error.code; message : string }
  | Read_error of Logseq_db_worker.Error.t
  | Changes_resync of string
  | Changes_retired
  | Changes_acknowledged of Worker.change_ack

let timeline_version value =
  let digits s = s <> "" && String.length s <= 19
    && String.for_all (fun c -> c >= '0' && c <= '9') s
    && Option.is_some (Int64.of_string_opt s) in
  let valid = String.length value <= 96 && match String.split_on_char ':' value with
    | ["generation"; "v1"; epoch; sequence] -> digits epoch && digits sequence
    | [("projection" | "change-window"); "v1"; number] -> digits number
    | _ -> false in
  `String (if valid then value else "invalid")
;;

let report_timeline stage fields =
  try
    let text = Yojson.Safe.to_string (`Assoc (("stage", `String stage) :: fields)) in
    if String.length text <= 8192 then (
      output_string stderr ("journal-timeline: " ^ text ^ "\n"); flush stderr)
  with _ -> ()
;;

type worker_failure =
  { operation : string
  ; request_id : Graph.Uuid.t
  ; error : Error.t
  }

type failure_source =
  | Worker_failure of worker_failure
  | Projection_failure of string

type mutation_kind =
  | Capture_mutation
  | Status_mutation
  | Delete_subtree_mutation

type payload =
  | Child_projection_ready of
      { root : Graph.Uuid.t; round : int64; command : Projection.create_child;
        presentation : Worker.presentation; result : payload; failure : Worker.error option }
  | Child_not_admitted of {command:Journal_graph_projection.create_child;message:string}
  | Child_waiting of {command:Journal_graph_projection.create_child;message:string}
  | Child_projection_settled of
      { command : Projection.create_child; presentation : Worker.presentation option; result : payload; failure : Worker.error option;
        insert_rejected : bool }
  | Capture_projection_ready of
      {root:Logseq_db_types.Graph_types.Uuid.t;round:int64;command:Journal_graph_projection.capture;
       presentation:Journal_worker_coordination.Worker_api.presentation;result:payload;
       failure:Journal_worker_coordination.Worker_api.error option}
  | Capture_not_admitted of {command:Journal_graph_projection.capture;message:string}
  | Capture_waiting of {command:Journal_graph_projection.capture;message:string}
  | Capture_projection_settled of
      {command:Journal_graph_projection.capture;presentation:Journal_worker_coordination.Worker_api.presentation option;
       result:payload;failure:Journal_worker_coordination.Worker_api.error option;insert_rejected:bool}
  | Mutation_settled of Journal_worker_coordination.Worker_api.durable_intent * Journal_worker_coordination.Worker_api.presentation * payload
  | Mutation_waiting of { mutation_id:string; block_id:string; message:string }
  | Projection_changes of Worker_pure_data.change_window list
  | Projection_resync
  | Task_statuses_changed of
      { items : Graph.task_status_definition Rrbvec.t
      ; default_status : Graph.Uuid.t option
      ; complete : bool
      ; error : string option
      }
  | Reference_sources_changed of (string * string option) list
  | Favorites_loaded of
      Journal_graph_request.favorites_request
      * Journal_worker_coordination.Worker_api.favorites
  | Favorites_failed of Journal_graph_request.favorites_request * bool * string
  | Favorites_invalidated
  | Graph_ready
  | Admission_inspected of
      { request : Journal_graph_request.admission_request
      ; observation : Worker_pure_data.admission_inspection
      }
  | Admission_unavailable of Journal_graph_request.admission_request
  | Block_captured of
      { block : Projection.block
      ; timeline_entry_update : Projection.timeline_entry option
      }
  | Child_failed of
      { mutation_id : string
      ; block_id : string
      ; failure : failure_source
      }
  | Child_created of
      { child : Projection.block
      ; parent : Projection.block
      ; timeline_entry_update : Projection.timeline_entry option
      }
  | Block_updated of
      { block : Projection.block
      ; timeline_entry_update : Projection.timeline_entry option
      }
  | Block_removed of { block_id : string }
  | Block_observed_missing of { block_id : string }
  | Page_tree_reconciled of
      { page : Projection.page
      ; value : Projection.timeline_entry_page
      }
  | Projection_unavailable of [ `Detail_calendar | `Detail_time | `Detail ]
  | Children_reconciled of Projection.detail
  | Update_conflict of {block:Projection.block;timeline_entry_update:Projection.timeline_entry option}
  | Subtree_deleted of
      { block_id : string
      ; deleted_count : int option
      ; parent : Projection.block option
      ; timeline_entry_update : Projection.timeline_entry option
      }
  | Delete_conflict of {block:Projection.block;timeline_entry_update:Projection.timeline_entry option}
  | Delete_reappeared of {block:Projection.block;timeline_entry_update:Projection.timeline_entry option}
  | Block_found of Projection.block option
  | Feed_refresh_started of { request_generation : int64 }
  | Feed_loaded of
      { request_generation : int64
      ; feed : Projection.feed
      ; complete : bool
      }
  | Day_blocks_failed of
      { day : int
      ; request_generation : int64
      ; stale_cursor : bool
      ; failure : failure_source
      }
  | Detail_loaded of
      { request_generation : int64
      ; detail : Projection.detail
      }
  | Detail_failed of
      { request_generation : int64
      ; block_id : string
      ; missing : bool
      ; stale_cursor : bool
      ; failure : failure_source
      }
  | Feed_failed of
      { request_generation : int64
      ; failure : failure_source
      }
  | Open_failed of worker_failure
  | Mutation_failed of
      { kind : mutation_kind
      ; mutation_id : string
      ; block_id : string
      ; failure : failure_source
      }
  | Diagnostic of worker_failure
  | Rejected of failure_source

type response = { payload : payload }

type refresh = Confirmation.purpose =
  | Updated of { block_id : string }
  | Update_conflict_refresh of { block_id : string }
  | Delete_conflict_refresh of { block_id : string }

type page_tree_interest =
  { page : Projection.page
  ; limit : int
  }

type children_interest =
  { page : Graph.page
  ; root : Projection.block_member
  ; limit : int
  }

type operation =
  | Feed_read of Feed.operation
  | Reference_read of Reference.read
  | Favorite_read of Favorites.read
  | Task_catalog of
      { epoch : int64
      ; seen : string Rrbvec.t
      ; after : Graph.task_status_definition Worker.continuation option
      }
  | Task_definitions of Graph.Uuid.t list
  | Graph_info
  | Admission_info of Journal_graph_request.admission_request
  | Pull_changes of
      { request_generation : int64
      ; generation : string
      }
  | Acknowledge_changes of { batch:Worker.change_batch option; continuation:int64 option }
  | Detail_block of
      { generation : int64
      ; block_id : string
      ; limit : int
      ; after : Projection.child_cursor option
      }
  | Detail_page of
      { generation : int64
      ; root : Projection.block_member
      ; limit : int
      ; after : Projection.child_cursor option
      }
  | Child_chain of { chain : Child.t; projection : payload option }
  | Capture_chain of { chain : Child.t; projection : payload option; command : Projection.capture }
  | Child_write of { root : Graph.Uuid.t; index : int; round : int64 }
  | Child_canonical of { root : Graph.Uuid.t; round : int64 }
  | Child_chain_parent of { root : Graph.Uuid.t; round : int64; summary : Worker.block_summary }
  | Child_ack of { root : Graph.Uuid.t; index : int; round : int64;
      intent : Worker.durable_intent; presentation : Worker.presentation }
  | Child_insert of Projection.create_child * Graph.page
  | Changed_block of { block_id : string }
  | Changed_detail_block of { block_id : string; observed : bool }
  | Changed_point_context of
      { block_id : string
      ; value : Worker_pure_data.block_record
      ; revision : string
      ; child_count : int
      }
  | Changed_detail_page of Graph.Uuid.t
  | Find_block_result
  | Detail_children of
      { generation : int64
      ; page : Graph.page
      ; root : Projection.block_member
      ; after : Projection.child_cursor option
      ; limit : int
      }
  | Changed_children of children_interest
  | Capture_append of Projection.capture
  | Target_summary of Confirmation.read
  | Mutation_refresh of
      { page : Projection.page
      ; refresh : refresh
      }
  | Delete_mutation of Projection.delete_subtree

type failure_owner =
  | Mutation_owner of
      { kind : mutation_kind
      ; mutation_id : string
      ; block_id : string
      }
  | Child_owner of
      { mutation_id : string
      ; block_id : string
      }

type request_delivery =
  | Planned
  | Queued
  | Dispatched

type worker_read =
  | Confirm_readback of {intent:Worker.durable_intent;presentation:Worker.presentation;query:Worker.block_summary Worker.query}
  | Read :
      { query : 'a Worker.query
      ; maximum_items : int
      }
      -> worker_read
  | Acknowledge of {batch:Worker.change_batch}


type planned =
  | Query of worker_read
  | Mutation of {mutation_id:Graph.Uuid.t;command:Worker.mutation_command}
  | Append of Worker_pure_data.append_node
  | Stage
  | Child_acknowledgement

type durable_operation =
  { intent : Worker.durable_intent
  ; presentation : Worker.presentation
  ; confirm_readback : bool
  ; root_request : Graph.Uuid.t
  ; submission_recovered : bool
  ; acknowledgement_recovered : Worker.presentation option
  ; acknowledgement_in_flight : bool
  }

type pending_operation =
  { operation : operation
  ; original : Graph.Uuid.t
  ; planned : planned
  ; durable : durable_operation option
  ; source_epoch : int64
  ; failure_owner : failure_owner option
  ; mutable change_application : Coordination.change_application option
  ; mutable external_children : Graph.Uuid.t Rrbvec.t
  ; mutable background : bool
  ; mutable delivery : request_delivery
  }

type t =
  { on_change : Coordination.event -> unit
  ; on_projection_changes : Worker_pure_data.change_window list -> unit
  ; external_reads : (Graph.Uuid.t,Coordination.change_application) Hashtbl.t
  ; mutable application_context : (Coordination.change_application * Graph.Uuid.t * Graph.Uuid.t Rrbvec.t ref) option
  ; mutable latest_application : Coordination.change_application option
  ; mutable latest_change_batch : Worker.change_batch option
  ; validate_session : Worker.session -> (unit, Worker.error) result
  ; pending : (string, pending_operation) Hashtbl.t
  ; mutable insertion_recoveries : (Graph.Uuid.t * Child.recovery) Rrbvec.t
  ; hydration_queue : Graph.Uuid.t Queue.t
  ; hydration_active : (string, unit) Hashtbl.t
  ; mutable next_request : int64
  ; task_definitions : (string, int64 * Graph.task_status_definition option) Hashtbl.t
  ; task_lookup_epochs : (string, int64) Hashtbl.t
  ; task_catalog_deletions : (string, int64) Hashtbl.t
  ; mutable task_catalog_loading : bool
  ; mutable task_catalog_epoch : int64
  ; mutable task_catalog_started : bool
  ; mutable task_catalog_complete : bool
  ; mutable task_property : Graph.Uuid.t option
  ; mutable default_task_status : Graph.Uuid.t option
  ; mutable change_generation : string option
  ; mutable change_cursor : string option
  ; block_revisions : (string, string) Hashtbl.t
  ; page_revisions : (string, string) Hashtbl.t
  ; scope_revisions : (string, string) Hashtbl.t
  ; mutable calendar : Journal_calendar.t option
  ; localtime : float -> Unix.tm
  ; graph_pages : (string, Graph.page) Hashtbl.t
  ; mutable pages : (string * Projection.page) list
  ; mutable block_pages : (string * Projection.page) list
  ; tag_titles : (string, string list) Hashtbl.t
  ; references : Reference.t
  ; projected_blocks : (string, Projection.block) Hashtbl.t
  ; page_tree_interests : (string, page_tree_interest) Hashtbl.t
  ; children_interests : (string, children_interest) Hashtbl.t
  ; detail_pages : (string, Graph.page) Hashtbl.t
  ; detail_children : (string, Projection.children_page) Hashtbl.t
  ; favorites : Favorites.t
  ; changed_point_epochs : (string, int64) Hashtbl.t
  ; confirmations : Confirmation.t
  ; feed : Feed.t
  }

type output =
  { requests : Graph.Uuid.t list
  ; responses : response list
  }

let empty = { requests = []; responses = [] }
let requests values = { empty with requests = values }
let response payload = { payload }
let responses values = { empty with responses = values }

let day_failure ~day request_generation message =
  responses
    [ response
        (Day_blocks_failed
           { day
           ; request_generation
           ; stale_cursor = false
           ; failure = Projection_failure message
           })
    ]
;;

let create ?(on_change=fun _->()) ?(on_projection_changes=fun _->()) ?(localtime = Unix.localtime) ?(validate_session = fun _ -> Error Worker.Revoked_session) () =
  { validate_session;on_change;on_projection_changes;external_reads=Hashtbl.create 16;application_context=None;latest_application=None;latest_change_batch=None
  ; pending = Hashtbl.create 32
  ; insertion_recoveries=Rrbvec.empty
  ; hydration_queue = Queue.create ()
  ; hydration_active = Hashtbl.create 4
  ; next_request = 1L
  ; task_definitions = Hashtbl.create 32
  ; task_lookup_epochs = Hashtbl.create 32
  ; task_catalog_deletions = Hashtbl.create 32
  ; task_catalog_loading = false
  ; task_catalog_epoch = 0L
  ; task_catalog_started = false
  ; task_catalog_complete = false
  ; task_property = None
  ; default_task_status = None
  ; change_generation = None
  ; change_cursor = None
  ; block_revisions = Hashtbl.create 64
  ; page_revisions = Hashtbl.create 32
  ; scope_revisions = Hashtbl.create 32
  ; calendar = None
  ; localtime
  ; graph_pages = Hashtbl.create 32
  ; pages = []
  ; block_pages = []
  ; tag_titles = Hashtbl.create 64
  ; references = Reference.create ~localtime ()
  ; projected_blocks = Hashtbl.create 64
  ; page_tree_interests = Hashtbl.create 32
  ; children_interests = Hashtbl.create 32
  ; detail_pages = Hashtbl.create 32
  ; detail_children = Hashtbl.create 32
  ; favorites = Favorites.create ()
  ; changed_point_epochs = Hashtbl.create 32
  ; confirmations = Confirmation.create ()
  ; feed = Feed.create ()
  }
;;

let reset t =
  Option.iter(fun token->t.on_change(Coordination.Change_application_retired token)) t.latest_application;
  t.latest_application<-None;t.latest_change_batch<-None;t.application_context<-None;
  Hashtbl.clear t.external_reads;
  Hashtbl.clear t.pending;
  t.insertion_recoveries<-Rrbvec.empty;
  Queue.clear t.hydration_queue;
  Hashtbl.clear t.hydration_active;
  Hashtbl.clear t.task_definitions;
  Hashtbl.clear t.task_catalog_deletions;
  t.task_catalog_loading <- false;
  Hashtbl.clear t.task_lookup_epochs;
  t.task_catalog_epoch <- t.next_request;
  t.task_catalog_started <- false;
  t.task_catalog_complete <- false;
  t.task_property <- None;
  t.default_task_status <- None;
  t.change_generation <- None;
  t.change_cursor <- None;
  Hashtbl.clear t.block_revisions;
  Hashtbl.clear t.page_revisions;
  Hashtbl.clear t.scope_revisions;
  Hashtbl.clear t.graph_pages;
  t.pages <- [];
  t.block_pages <- [];
  Reference.reset t.references;
  Hashtbl.clear t.projected_blocks;
  Hashtbl.clear t.tag_titles;
  Hashtbl.clear t.page_tree_interests;
  Hashtbl.clear t.children_interests;
  Hashtbl.clear t.detail_pages;
  Hashtbl.clear t.detail_children;
  Favorites.reset t.favorites;
  Hashtbl.clear t.changed_point_epochs;
  Confirmation.reset t.confirmations;
  Feed.reset t.feed
;;

let set_calendar t (calendar : Journal_calendar.t) =
  match t.calendar with
  | Some current when not (Journal_calendar.is_newer ~than:current calendar) -> ()
  | None | Some _ -> t.calendar <- Some calendar
;;

let projection_time_context t =
  match t.calendar with
  | None -> Error "The host calendar is unavailable."
  | Some _ -> Ok Projection.{ localtime = t.localtime }
;;

let calendar_generation_is_current t generation =
  match t.calendar with
  | Some calendar -> Int64.equal (Journal_calendar.generation calendar) generation
  | None -> false
;;

let request_uuid t =
  let value = Printf.sprintf "f0000000-0000-4000-8000-%012Lx" t.next_request in
  t.next_request <- Int64.succ t.next_request;
  Result.get_ok (Graph.Uuid.of_string value)
;;

let uuid value = Graph.Uuid.of_string value

let changed_point_current t operation epoch =
  match operation with
  | Changed_block { block_id; _ }
  | Changed_detail_block { block_id; _ }
  | Changed_point_context { block_id; _ } ->
    Hashtbl.find_opt t.changed_point_epochs block_id = Some epoch
  | _ -> true
;;

let make_request ?source_epoch ?(background = false) t operation planned =
  let source_epoch = Option.value source_epoch ~default:t.next_request in
  let request_id = request_uuid t in
  (match operation with
   | Changed_block { block_id; _ } | Changed_detail_block { block_id; _ } ->
     Hashtbl.replace t.changed_point_epochs block_id source_epoch
   | Task_definitions ids ->
     List.iter
       (fun uuid ->
          Hashtbl.replace t.task_lookup_epochs (Graph.Uuid.to_string uuid) source_epoch)
       ids
   | _ -> ());
  let participates=match operation with Acknowledge_changes _->false|_->true in
  Hashtbl.replace
    t.pending
    (Graph.Uuid.to_string request_id)
    { operation; original=request_id;planned;durable=None; source_epoch; failure_owner = None; background; delivery = Planned;
      external_children=Rrbvec.empty;change_application=(if participates then Option.map(fun(token,_,_)->token)t.application_context else None) };
  if participates then Option.iter(fun(_,_,children)->children:=Rrbvec.push_back !children request_id)t.application_context;
  request_id
;;

let read ?source_epoch ?background ?(maximum_items=1) t operation query =
  make_request ?source_epoch ?background t operation (Query(Read{query;maximum_items}))
let point ?source_epoch ?background t operation ~page uuid =
  if page then read ?source_epoch ?background t operation (Worker.Page{uuid;revision=None})
  else read ?source_epoch ?background t operation (Worker.Outline_block{uuid;revision=None})
let mutate = make_request
let favorites_ports t =
  Favorites.
    { plan_read = (fun ~maximum_items value query -> read ~maximum_items t (Favorite_read value) query)
    ; remember_page = (fun (page : Graph.page) ->
        Hashtbl.replace t.graph_pages (Graph.Uuid.to_string page.uuid) page)
    }
;;

let favorites_output (value : Favorites.output) =
  { requests = Rrbvec.to_list value.requests
  ; responses = Rrbvec.to_list (Rrbvec.map
      (function
        | Favorites.Favorites_loaded (request, result) -> response (Favorites_loaded (request, result))
        | Favorites_failed (request, stale, message) -> response (Favorites_failed (request, stale, message))
        | Favorites_invalidated -> response Favorites_invalidated
        | Rejected (Projection_rejection message) -> response (Rejected (Projection_failure message))
        | Diagnostic { operation; request_id; error } ->
          response (Diagnostic { operation; request_id; error })
        | Rejected (Worker_rejection { operation; request_id; error }) ->
          response (Rejected (Worker_failure { operation; request_id; error })))
      value.responses)
  }
;;

(* Only a public output boundary issues a demand. Internal completions never
   reserve a hydration slot or return an already dispatched request. *)
let issue_request t (request : Graph.Uuid.t) =
  let key = Graph.Uuid.to_string request in
  let pending = Hashtbl.find t.pending key in
  pending.delivery <- Dispatched;
  if pending.background then Hashtbl.replace t.hydration_active key ();
  request
;;

let task_catalog_response ?error t =
  let items =
    Hashtbl.to_seq_values t.task_definitions |> Seq.filter_map snd |> Array.of_seq
  in
  Array.sort
    (fun (a : Graph.task_status_definition) b ->
       let c = String.compare a.order b.order in
       if c = 0 then Graph.Uuid.compare a.uuid b.uuid else c)
    items;
  let items = Array.to_seq items |> Seq.fold_left Rrbvec.push_back Rrbvec.empty in
  response
    (Task_statuses_changed
       { items
       ; default_status = t.default_task_status
       ; complete = t.task_catalog_complete
       ; error
       })
;;

let request_task_catalog t =
  t.task_catalog_started <- true;
  t.task_catalog_loading <- true;
  t.task_catalog_complete <- false;
  Hashtbl.clear t.task_catalog_deletions;
  let epoch = t.next_request in
  t.task_catalog_epoch <- epoch;
  read
    t
    (Task_catalog { epoch; seen = Rrbvec.empty; after = None })
    ~maximum_items:Worker_pure_data.maximum_page_size (Worker.Task_statuses None)
;;

let start t = issue_request t (read t Graph_info Worker.Graph_info)

let remember_page t (page : Projection.page) =
  t.pages
  <- (page.id, page) :: List.filter (fun (id, _) -> not (String.equal id page.id)) t.pages
;;

let page_by_uuid t uuid = List.assoc_opt (Graph.Uuid.to_string uuid) t.pages
let page_by_block t block_id = List.assoc_opt block_id t.block_pages

let remember_block_page t page block_id =
  t.block_pages
  <- (block_id, page)
     :: List.filter
          (fun (candidate, _) -> not (String.equal candidate block_id))
          t.block_pages
;;

let remember_blocks t page blocks =
  List.iter
    (fun (member : Projection.block_member) ->
       remember_block_page t page (Graph.Uuid.to_string member.block.uuid))
    blocks
;;

let page_by_day t day =
  List.find_map
    (fun (_, (page : Projection.page)) -> if page.day = day then Some page else None)
    t.pages
;;

let parse_uuid field value =
  match uuid value with
  | Ok value -> Ok value
  | Error message -> Error (field ^ ": " ^ message)
;;

let mutation_context (_t : t) mutation_id = parse_uuid "mutation ID" mutation_id

let scope_key = function
  | Worker_pure_data.V2_children_scope parent -> "children:" ^ Graph.Uuid.to_string parent
;;

let preconditions ?(blocks = []) ?(pages = []) ?(scopes = []) () =
  Worker_pure_data.{ blocks; pages; scopes }
;;

let scope_precondition t scope =
  match Hashtbl.find_opt t.scope_revisions (scope_key scope) with
  | None -> Error "The structure revision is not retained."
  | Some revision -> Ok (scope, revision)
;;


let journal_uuid day =
  let text = Printf.sprintf "%08d" day in
  Graph.Uuid.of_string
    (Printf.sprintf
       "00000001-%s-%s-0000-000000000000"
       (String.sub text 0 4)
       (String.sub text 4 4))
;;

let reject message = responses [ response (Rejected (Projection_failure message)) ]

(* Admission identity follows only direct continuations of this operation.
   Reference reconciliation and queued background hydration are merged later. *)
let scope_output t owner output =
  match owner with
  | None -> output
  | Some owner ->
    List.iter
      (fun (request : Graph.Uuid.t) ->
         let key = Graph.Uuid.to_string request in
         match Hashtbl.find_opt t.pending key with
         | None -> ()
         | Some pending ->
           Hashtbl.replace t.pending key { pending with failure_owner = Some owner })
      output.requests;
    let responses =
      List.map
        (fun response ->
           match response.payload, owner with
           | Rejected failure, Mutation_owner { kind; mutation_id; block_id } ->
             { payload = Mutation_failed { kind; mutation_id; block_id; failure } }
           | Rejected failure, Child_owner { mutation_id; block_id } ->
             { payload = Child_failed { mutation_id; block_id; failure } }
           | _ -> response)
        output.responses
    in
    { output with responses }
;;

(* A page is a detail root, never an outline mutation target. Its identity
   (uuid = page) survives the existing model projection and child ownership. *)
let page_root_member (page : Graph.page) revision : Projection.block_member =
  { revision
  ; block =
      { uuid = page.uuid; page = page.uuid; parent = page.uuid; order = "page"
      ; title = page.title; created_at_ms = page.created_at_ms
      ; updated_at_ms = page.updated_at_ms; refs = []; tags = page.tags
      ; properties = page.properties }
  }
;;

let task_status_uuid t = function
  | Journal_model.No_status -> Ok None
  | Status value ->
    Result.bind (parse_uuid "status UUID" value) (fun uuid ->
      if t.task_catalog_complete && not (Hashtbl.mem t.task_definitions value)
      then Error "This task status is unavailable. Choose another status before saving."
      else Ok (Some uuid))
  | Default_status ->
    (match t.default_task_status with
     | Some uuid -> Ok (Some uuid)
     | None -> Error "Choose a task status; this graph has no available default.")
  | Invalid_status _ -> Error "Choose a valid task status before saving."
;;

let page_of_graph_page (page : Graph.page) =
  let summary : Graph.page_summary =
    { uuid = page.uuid
    ; name = page.name
    ; title = page.title
    ; kind = page.kind
    ; recycled = page.recycled
    }
  in
  Projection.page_of_summary summary
;;

let feed_ports t =
  Feed.
    { now = (fun () -> t.next_request)
    ; validate_session = t.validate_session
    ; plan_read = (fun ~maximum_items operation query -> read ~maximum_items t (Feed_read operation) query)
    ; context = (fun () -> {today=Option.map Journal_calendar.local_day t.calendar;time_context=projection_time_context t})
    ; tag_titles = (fun uuid -> Option.value (Hashtbl.find_opt t.tag_titles (Graph.Uuid.to_string uuid)) ~default:[])
    ; project_journal_page = page_of_graph_page
    ; retain_root_interest = (fun page ~minimum_limit ->
        let limit = Option.fold ~none:minimum_limit ~some:(fun (i:page_tree_interest)->max minimum_limit i.limit)
          (Hashtbl.find_opt t.page_tree_interests page.id) in
        Hashtbl.replace t.page_tree_interests page.id {page;limit})
    ; retained_anchor = (fun ~page_id -> Hashtbl.fold
        (fun id block anchor ->
          if Journal_model.page_id block = page_id && Journal_model.parent_id block = None && id <> page_id then
            let key = Journal_model.sibling_order block,id in
            Some (Option.fold ~none:key ~some:(fun old->max old key) anchor)
          else anchor) t.projected_blocks None)
    ; observe_packet = (function
        | Dates items -> Seq.iter (fun (i:Worker_pure_data.journal_item)->
            Hashtbl.replace t.graph_pages (Graph.Uuid.to_string i.page.uuid) i.page;
            Hashtbl.replace t.page_revisions (Graph.Uuid.to_string i.page.uuid) i.revision) items
        | Roots items -> Seq.iter (fun (i:Worker_pure_data.tree_member)->
            Hashtbl.replace t.block_revisions (Graph.Uuid.to_string i.value.block.uuid) i.revision;
            Hashtbl.replace t.tag_titles (Graph.Uuid.to_string i.value.block.uuid) i.value.tag_titles) items
        | Preview items -> Seq.iter (fun (i:Worker_pure_data.child_member)->
            Hashtbl.replace t.block_revisions (Graph.Uuid.to_string i.value.block.uuid) i.revision;
            Hashtbl.replace t.tag_titles (Graph.Uuid.to_string i.value.block.uuid) i.value.tag_titles) items)
    ; remember_fragment = (fun {page;members;entries}->
        remember_page t page;
        Rrbvec.iter (fun (item:Projection.tree_member)->
          remember_block_page t page (Graph.Uuid.to_string item.block.uuid)) members;
        Rrbvec.iter (fun (entry:Projection.timeline_entry)->
          let id = Journal_model.id entry.block in
          remember_block_page t page id;
          Hashtbl.replace t.projected_blocks id entry.block) entries)
    ; report = report_timeline
    }
;;


let worker_error code request_id message =
  Error.create ~code ~message ~details:[]
  |> Result.fold ~ok:Fun.id ~error:(fun _ ->
    let module D=Logseq_db_types.Failure_diagnostic in
    let detail=D.of_source ~operation:"workerOperation" ~reason:"invalidContent" message in
    Error.create ~code ~message:(D.message detail)
      ~details:[Error.{name=D.detail_name;value=Detail_string(D.encode detail)}]
    |> Result.get_ok)
  |> fun error -> request_id, error
;;

let feed_output ?source (value : Feed.output) =
  { requests = Rrbvec.to_list value.requests
  ; responses =
      Rrbvec.to_list
        (Rrbvec.map
           (function
             | Feed.Loaded { request_generation; feed; complete } ->
               response (Feed_loaded { request_generation; feed; complete })
             | Reconciled { page; value } ->
               response (Page_tree_reconciled { page; value })
             | Failed { scope; stale_cursor; message; cause } ->
               let failure = match source,cause with
                 | Some (operation,request_id), Some cause ->
                   let code = match cause with
                     | Worker.Db_error error -> Error.code error
                     | Revoked_session | Host_change_in_progress -> Error.Closed_session
                     | Response_budget_exceeded -> Error.Response_too_large
                     | Stale_read _ -> Error.Stale_read_cursor
                     | Invalid_input _ | Protocol_mismatch _ -> Error.Invalid_request
                     | Resync_required _ | Service_failed _ | Unsupported_operation _ -> Error.Unsupported_semantics in
                   let error = match cause with Worker.Db_error error -> error
                     | _ -> snd (worker_error code request_id message) in
                   Worker_failure {operation;request_id;error}
                 | _ -> Projection_failure message in
               response
                 (match scope with
                  | Feed request_generation -> Feed_failed { request_generation; failure }
                  | Day { day; request_generation } ->
                    Day_blocks_failed { day; request_generation; stale_cursor; failure }
                  | Reconciliation -> Rejected failure))
           value.publications)
  }
;;

let child_error_message = function
  | Worker.Db_error error -> Error.message error
  | Invalid_input message | Service_failed message | Unsupported_operation message
  | Protocol_mismatch message | Stale_read message | Resync_required message -> message
  | Revoked_session -> "The child graph session changed."
  | Host_change_in_progress -> "The graph is closing. The child outcome is retained."
  | Response_budget_exceeded -> "The child result exceeded its response budget."
;;
let child_failure (command : Projection.create_child) message = response (Child_failed
  {mutation_id=command.Projection.mutation_id;block_id=command.block_id;
   failure=Projection_failure message})
;;
let child_root t root =
  match Hashtbl.find_opt t.pending (Graph.Uuid.to_string root) with
  | Some ({operation=Child_chain value;_} as pending) -> Some(pending,value.chain,value.projection)
  | Some ({operation=Capture_chain value;_} as pending) -> Some(pending,value.chain,value.projection)
  | _ -> None
;;
let capture_snapshot t (request:Graph.Uuid.t) =
  let root=match Hashtbl.find_opt t.pending(Graph.Uuid.to_string request) with
    | Some{operation=Capture_chain _;_}->Some request
    | Some{operation=(Child_write{root;_}|Child_ack{root;_});_}->Some root
    | _->None in
  Option.bind root(fun root->match Hashtbl.find_opt t.pending(Graph.Uuid.to_string root) with
    | Some{operation=Capture_chain value;_}->Some(value.command,value.chain)
    | _->None)
;;
let child_snapshot t (request:Graph.Uuid.t) =
  let root=match Hashtbl.find_opt t.pending(Graph.Uuid.to_string request) with
    | Some{operation=Child_chain _;_}->Some request
    | Some{operation=(Child_write{root;_}|Child_ack{root;_});_}->Some root
    | _->None in
  Option.bind root(fun root->match Hashtbl.find_opt t.pending(Graph.Uuid.to_string root) with
    | Some{operation=Child_chain value;_}->Some(Child.command value.chain,value.chain)
    | _->None)
;;
let retained_child_chains t =
  Hashtbl.to_seq_values t.pending |> Seq.fold_left(fun retained pending->match pending.operation with
    | Child_chain value->Rrbvec.push_back retained (Child.command value.chain,value.chain)
    | _->retained)Rrbvec.empty
;;
let child_request_root = function
  | Child_write {root;_} | Child_canonical {root;_} | Child_chain_parent {root;_}
  | Child_ack {root;_} -> Some root
  | _ -> None
;;
let changed_child_chains t (output:output) =
  let module Roots=Set.Make(struct type t=Graph.Uuid.t let compare=Graph.Uuid.compare end) in
  let roots=List.fold_left(fun roots (request:Graph.Uuid.t)->
    match Hashtbl.find_opt t.pending(Graph.Uuid.to_string request) with
    | Some pending->Option.fold ~none:roots ~some:(fun root->Roots.add root roots)(child_request_root pending.operation)
    | None->roots)Roots.empty output.requests in
  let roots=List.fold_left(fun roots response->match response.payload with
    | Child_projection_ready{root;_}->Roots.add root roots
    | Child_waiting{command;_}->
      Hashtbl.to_seq t.pending |> Seq.fold_left(fun roots(key,pending)->match pending.operation with
        | Child_chain value when Child.matches_child value.chain command->Roots.add(Graph.Uuid.of_string key |> Result.get_ok)roots
        | _->roots)roots
    | _->roots)roots output.responses in
  Roots.fold(fun root snapshots->match Hashtbl.find_opt t.pending(Graph.Uuid.to_string root) with
    | Some{operation=Child_chain value;_}->Rrbvec.push_back snapshots(Child.command value.chain,value.chain)
    | _->snapshots)roots Rrbvec.empty
;;
let update_child_root t root chain projection =
  Option.iter (fun (pending,_,_) -> Hashtbl.replace t.pending (Graph.Uuid.to_string root)
    {pending with operation=(match pending.operation with
      | Capture_chain value->Capture_chain{value with chain;projection}
      | _->Child_chain {chain;projection})}) (child_root t root)
;;
let capture_root_command t root =
  match Hashtbl.find_opt t.pending(Graph.Uuid.to_string root) with
  | Some{operation=Capture_chain{command;_};_}->Some command | _->None
;;
let capture_failure (command:Projection.capture) message =
  Mutation_failed{kind=Capture_mutation;mutation_id=command.mutation_id;block_id=command.block_id;
    failure=Projection_failure message}
;;
let project_capture_summary t (summary:Worker.block_summary) =
  match summary.lookup,summary.page,projection_time_context t with
  | Worker_pure_data.V2_present_block{value;revision},Some(Worker_pure_data.V2_present_page{page;revision=page_revision}),Ok time_context ->
    (match Projection.block_on_page ~page ~revision
      ~child_count:(List.length summary.items + if summary.next=None then 0 else 1)
      ~time_context value.block,page_of_graph_page page with
     | Ok block,Some journal ->
       let block=Journal_model.with_tag_titles block ~tag_titles:value.tag_titles in
       (match Projection.timeline_target_entry ~page:journal ~time_context
          ~root:Projection.{block=value.block;revision;depth=0}
          ~tag_titles:(fun _->value.tag_titles)(Rrbvec.of_list summary.items) with
        | Error message->Error message
        | Ok entry->
          Hashtbl.replace t.graph_pages (Graph.Uuid.to_string page.uuid) page;
          Hashtbl.replace t.page_revisions (Graph.Uuid.to_string page.uuid) page_revision;
          Hashtbl.replace t.block_revisions (Graph.Uuid.to_string value.block.uuid) revision;
          Hashtbl.replace t.projected_blocks (Graph.Uuid.to_string value.block.uuid) block;
          Hashtbl.replace t.tag_titles (Graph.Uuid.to_string value.block.uuid) value.tag_titles;
          Hashtbl.replace t.page_tree_interests journal.id {page=journal;limit=Worker_pure_data.maximum_page_size};
          remember_block_page t journal (Graph.Uuid.to_string value.block.uuid);
          (* The summary is a bounded slice. Keep the same lower bound on
             both projections; Timeline owns a preview and opens a fresh Detail
             read rather than treating this slice as a complete child set. *)
          Ok(Block_captured{block;timeline_entry_update=Option.map(fun (entry:Projection.timeline_entry)->
            {entry with block})entry}))
     | Error message,_->Error message
     | _,None->Error "The captured block has no canonical journal page.")
  | _,_,Error message->Error message
  | _->Error "The captured block is not available in its canonical journal page."
;;
let capture_append_root t (command:Projection.capture) =
  let bind=Result.bind in
  bind (parse_uuid "mutation UUID" command.mutation_id)(fun _mutation_id->
  bind (parse_uuid "block UUID" command.block_id)(fun block_id->
  bind (journal_uuid(Journal_time.local_day command.creation_time))(fun _page->
  bind (task_status_uuid t command.task_state)(fun task_status->
    if List.length command.children>=2000 then Error "Capture exceeds the atomic tree budget." else
    let children=List.fold_left(fun result (child:Projection.capture_child)->
      bind result(fun nodes->bind(parse_uuid "child UUID" child.block_id)(fun block_id->
        bind(task_status_uuid t child.task_state)(fun task_status->
          Ok(Rrbvec.push_back nodes Worker_pure_data.{block_id;title=child.source;task_status;children=Rrbvec.empty})))))
      (Ok Rrbvec.empty)command.children in
    bind children(fun children->
      let root:Worker_pure_data.append_node={block_id;title=command.source;task_status;children} in
      if not(Worker_pure_data.valid_append_node root) then Error "Capture tree has invalid or duplicate identities."
      else Ok root)))))
;;
let child_action t root chain projection action =
  let chain,recovery=Child.take_recovery chain in
  Option.iter(fun recovery->t.insertion_recoveries<-Rrbvec.push_back t.insertion_recoveries(root,recovery))recovery;
  update_child_root t root chain projection;
  let command=Child.command chain in
  let capture=capture_root_command t root in
  match action with
  | Child.Write(index,round) -> requests [mutate t (Child_write{root;index;round}) Stage]
  | Read_child round -> requests [read t (Child_canonical{root;round})
      ~maximum_items:Worker_pure_data.default_page_size
      (Worker.Block_summary {block=Graph.Uuid.of_string command.block_id |> Result.get_ok;after=None})]
  | Read_parent(round,summary) ->
    let parent=Graph.Uuid.of_string command.parent_block_id |> Result.get_ok in
    let page=Child.page chain in
    requests [point t (Child_chain_parent{root;round;summary}) ~page:(parent=page.uuid) parent]
  | Present round when capture<>None ->
    let command=Option.get capture in
    let result=match Child.failure chain,Child.canonical chain with
      | Some error,None->Ok(capture_failure command (child_error_message error))
      | _,Some summary->project_capture_summary t summary
      | _->Error "The captured result is not available." in
    (match result,Child.presentation chain with
     | Ok result,Some presentation->
       update_child_root t root chain (Some result);
       responses[response(Capture_projection_ready{root;round;command;presentation;result;failure=Child.failure chain})]
     | Error message,_->responses[response(Capture_waiting{command;message})]
     | _,None->responses[response(Capture_waiting{command;message="Capture lost its confirming presentation."})])
  | Present round ->
    let result=match projection with Some result->result
      | None->(child_failure command (Option.fold ~none:"The child could not be applied."
          ~some:child_error_message (Child.failure chain))).payload in
    (match Child.presentation chain with
     | Some presentation -> responses[response(Child_projection_ready
         {root;round;command;presentation;result;failure=Child.failure chain})]
     | None -> responses[child_failure command "The child result lost its confirming presentation."])
  | Acknowledge(index,round,intent,presentation) ->
    requests[mutate t (Child_ack{root;index;round;intent;presentation}) Child_acknowledgement]
  | Complete ->
    let insert_rejected=Child.insert_rejected chain in
    let result=match projection with Some result->result
      | None->(child_failure command (Option.fold ~none:"The child was not inserted."
          ~some:child_error_message(Child.failure chain))).payload in
    Hashtbl.filter_map_inplace (fun key pending ->
        if key=Graph.Uuid.to_string root || child_request_root pending.operation=Some root then None
        else Some pending) t.pending;
    let refresh=if Child.canonical chain=None then [] else
      match page_of_graph_page(Child.page chain) with None->[]|Some page->
        Option.to_list(Feed.reconcile_page t.feed ~ports:(feed_ports t) ~page ~limit:Worker_pure_data.maximum_page_size) in
    {requests=refresh;responses=[response(match capture with
      | Some command->Capture_projection_settled
        {command;presentation=Child.presentation chain;result;failure=Child.failure chain;insert_rejected}
      | None->Child_projection_settled
        {command;presentation=Child.presentation chain;result;failure=Child.failure chain;insert_rejected})]}
  | Ignore -> empty
  | Wait message -> responses[response(match capture with
      | Some command->Capture_waiting{command;message}
      | None->Child_waiting{command;message})]
;;
let child_step t root transition = match child_root t root with
  | None -> empty
  | Some(_,chain,projection) ->
    let next,action=transition chain in child_action t root next projection action
;;
let take_insertion_recoveries t =
  let pending=t.insertion_recoveries in t.insertion_recoveries<-Rrbvec.empty;pending
;;

let submit_unowned t (request : Journal_graph_request.t) =
  match request with
  | Load_task_statuses -> requests [ request_task_catalog t ]
  | Load_favorites request ->
    requests [ Favorites.load ~ports:(favorites_ports t) request ]
  | Inspect_admission request ->
    requests [ read t (Admission_info request) Worker.Admission ]
  | Load_feed { cursor; root_limit; day_limit; request_generation } ->
    Feed.load_feed t.feed ~ports:(feed_ports t) ~cursor ~root_limit ~day_limit ~request_generation |> feed_output
  | Load_day_blocks { day; after; limit; request_generation } ->
    (match page_by_day t day with
     | None -> day_failure ~day request_generation "The requested journal page is not retained."
     | Some page ->
       Feed.load_day t.feed ~ports:(feed_ports t) ~page ~after ~limit ~request_generation |> feed_output)
  | Load_detail { block_id; request_generation; limit; after } ->
    let cursor = Option.bind after (fun cursor -> cursor.Projection.protocol_cursor) in
    let parsed = match cursor with
      | Some (Projection.Root_tree_cursor _) -> Error "A Timeline cursor cannot continue Detail children."
      | Some (Projection.Child_cursor {maximum_items;_}) when maximum_items<=0 || maximum_items>Worker_pure_data.maximum_page_size ->
        Error "The Detail continuation budget is invalid."
      | Some (Projection.Child_cursor _) | None -> parse_uuid "block UUID" block_id in
    (match parsed with
     | Error message ->
       responses
         [ response
             (Detail_failed
                { request_generation
                ; block_id
                ; missing = false
                ; stale_cursor = false
                ; failure = Projection_failure message
                })
         ]
     | Ok block ->
       requests
         [ point
             t
             (Detail_block
                { generation = request_generation
                ; block_id
                ; limit = (match cursor with Some (Projection.Child_cursor value)->value.maximum_items
                    | _->max 1 (min Worker_pure_data.maximum_page_size limit))
                ; after = (match cursor with Some (Projection.Child_cursor value)->Some value | _->None)
                })
             ~page:(Hashtbl.mem t.graph_pages block_id || Favorites.is_page_target t.favorites block_id) block
         ])
  | Find_block block_id ->
    (match parse_uuid "block UUID" block_id with
     | Error message -> reject message
     | Ok block ->
       requests
         [ read t Find_block_result (Worker.Outline_block {uuid=block;revision=None}) ])
  | Capture { calendar_generation; command } ->
    let retained=Hashtbl.to_seq t.pending |> Seq.find_map(fun(key,pending)->match pending.operation with
      | Capture_chain value when value.command.mutation_id=command.mutation_id->
        Some(Graph.Uuid.of_string key |> Result.get_ok,value.command,value.chain,value.projection)
      | _->None) in
    (match retained with
     | Some(root,_original,chain,projection)->
       let previous=Child.command chain in
       let resolved=if command.status_intent_revision=previous.status_intent_revision
         && command.task_state=previous.task_state then Ok(Child.resolved_status chain)
         else task_status_uuid t command.task_state in
       (match resolved with Error message->responses[response(Capture_waiting{command;message})]
        | Ok resolved_status->match Child.retarget_capture chain ~command ~resolved_status with
          | Error message->responses[response(Capture_waiting{command;message})]
          | Ok chain->
            Option.iter(fun pending->Hashtbl.replace t.pending(Graph.Uuid.to_string root)
              {pending with operation=Capture_chain{command;chain;projection}})
              (Hashtbl.find_opt t.pending(Graph.Uuid.to_string root));
            let next,action=Child.retry chain in child_action t root next projection action)
     | None->
       if not(calendar_generation_is_current t calendar_generation) then
         responses[response(Capture_not_admitted{command;message="The local calendar changed before capture admission."})]
       else match capture_append_root t command with
       | Error message->responses[response(Capture_not_admitted{command;message})]
       | Ok root->requests[mutate t (Capture_append command) (Append root)])
  | Set_task_state command ->
    (match
       mutation_context t command.mutation_id, parse_uuid "block UUID" command.block_id
     with
     | Ok mutation_id, Ok block ->
       (match page_by_block t command.block_id with
        | None -> reject "The block page is not retained."
        | Some page ->
          let preconditions =
            preconditions ~blocks:[ block, command.expected_revision ] ()
          in
          let mutation =
            match task_status_uuid t command.task_state with
            | Ok None ->
              Ok (Mutation {mutation_id;command=Worker.Clear_task_status {block;preconditions}})
            | Ok (Some status) ->
              Ok
                (Mutation {mutation_id;command=Worker.Set_task_status {block;status;preconditions}})
            | Error message -> Error message
          in
          (match mutation with
           | Error message -> reject message
           | Ok mutation ->
          requests
            [ mutate
                t
                (Mutation_refresh
                   { page; refresh = Updated { block_id = command.block_id } })
                mutation
               ]))
     | Error message, _ | _, Error message -> reject message)
  | Create_child command ->
    let retained=Hashtbl.to_seq t.pending |> Seq.find_map(fun(key,pending)->
      match pending.operation with
      | Child_chain {chain;_} when (Child.command chain).mutation_id=command.mutation_id ->
        Some(Graph.Uuid.of_string key |> Result.get_ok,chain)
      | _->None) in
    (match retained with
     | Some(root,chain) ->
       (match (if command.status_intent_revision=(Child.command chain).status_intent_revision
             && command.task_state=(Child.command chain).task_state then Ok(Child.resolved_status chain)
           else task_status_uuid t command.task_state) with
        | Error message -> responses[child_failure command message]
        | Ok resolved_status ->
          (match Child.retarget chain ~command ~resolved_status with
           | Error message->responses[child_failure command message]
           | Ok chain->
             let next,action=Child.retry chain in
             let projection=Option.bind(child_root t root)(fun(_,_,projection)->projection) in
             child_action t root next projection action))
     | None ->
    let reject message = responses[response(Child_not_admitted{command;message})]in
    if not (calendar_generation_is_current t command.calendar_generation)
    then reject "The local calendar changed before child admission."
    else if Result.is_error (task_status_uuid t command.task_state)
    then reject (Result.get_error (task_status_uuid t command.task_state))
    else (
      match
        ( mutation_context t command.mutation_id
        , parse_uuid "child UUID" command.block_id
        , parse_uuid "parent UUID" command.parent_block_id )
      with
      | Ok mutation_id, Ok child, Ok parent ->
        let page =
          Hashtbl.to_seq_values t.children_interests
          |> Seq.find_map (fun interest ->
            if Graph.Uuid.to_string interest.root.block.uuid = command.parent_block_id
            then Some interest.page
            else None)
        in
        (match page with
         | None -> reject "The append parent is unavailable."
         | Some page ->
           (match scope_precondition t (Worker_pure_data.V2_children_scope parent) with
            | Error message -> reject message
            | Ok scope_revision ->
              requests
                [ mutate
                    t
                    (Child_insert (command, page))
                    (Mutation {mutation_id;command=Worker.Insert_blocks
                       { parent
                       ; roots =
                           [ { uuid = child; title = command.source; children = [] } ]
                       ; preconditions =
                           preconditions
                             ~blocks:(if Graph.Uuid.equal parent page.uuid then []
                               else [ parent, command.expected_parent_revision ])
                             ~pages:(if Graph.Uuid.equal parent page.uuid
                               then [ page.uuid, command.expected_parent_revision ] else [])
                             ~scopes:[ scope_revision ]
                             ()
                       }})
                ]))
      | Error message, _, _ | _, Error message, _ | _, _, Error message -> reject message))
  | Delete_subtree command ->
    (match
       mutation_context t command.mutation_id, parse_uuid "block UUID" command.block_id
     with
     | Ok mutation_id, Ok block ->
       let preconditions =
         preconditions ~blocks:[ block, command.expected_revision ] ()
       in
       requests
         [ mutate
             t
             (Delete_mutation command)
             (Mutation {mutation_id;command=Worker.Delete_blocks {root=block;preconditions}})
         ]
     | Error message, _ | _, Error message -> reject message)
;;

let plan_request t (request : Journal_graph_request.t) =
  let owner =
    match request with
    | Capture { command; _ } ->
      Some
        (Mutation_owner
           { kind = Capture_mutation
           ; mutation_id = command.mutation_id
           ; block_id = command.block_id
           })
    | Set_task_state command ->
      Some
        (Mutation_owner
           { kind = Status_mutation
           ; mutation_id = command.mutation_id
           ; block_id = command.block_id
           })
    | Delete_subtree command ->
      Some
        (Mutation_owner
           { kind = Delete_subtree_mutation
           ; mutation_id = command.mutation_id
           ; block_id = command.block_id
           })
    | Create_child command ->
      Some
        (Child_owner { mutation_id = command.mutation_id; block_id = command.block_id })
    | _ -> None
  in
  scope_output t owner (submit_unowned t request)
;;

let confirmation_ports t =
  Confirmation.
    { now = (fun () -> t.next_request)
    ; plan_read = (fun ~source_epoch value query ->
        read ~maximum_items:Worker_pure_data.default_page_size ~source_epoch t (Target_summary value) query) }
;;
let confirmation_planning = function
  | Ok request -> requests [request]
  | Error message -> reject message
;;
let request_target_summary_without_interest t refresh =
  Confirmation.start t.confirmations ~ports:(confirmation_ports t) refresh |> confirmation_planning
;;
let request_target_summary t page refresh =
  (* Journal interests are optional business subscriptions. The target summary
     itself supplies its real owning page, including ordinary pages. *)
  Hashtbl.replace t.page_tree_interests page.Projection.id {page;limit=Worker_pure_data.maximum_page_size};
  request_target_summary_without_interest t refresh
;;
let request_delete_summary t block_id =
  let refresh=Delete_conflict_refresh{block_id} in
  match page_by_block t block_id with
  | Some page->request_target_summary t page refresh
  | None->request_target_summary_without_interest t refresh
;;

let append_unique equal value values =
  if List.exists (equal value) values then values else values @ [ value ]
;;

let changed_interests windows =
  List.fold_left
    (fun (blocks, pages, structures) (window : Worker_pure_data.change_window) ->
       ( List.fold_left
           (fun values value -> append_unique Graph.Uuid.equal value values)
           blocks
           window.block_uuids
       , List.fold_left
           (fun values value -> append_unique Graph.Uuid.equal value values)
           pages
           window.page_uuids
       , List.fold_left
           (fun values value -> append_unique ( = ) value values)
           structures
           window.structure_interests ))
    ([], [], [])
    windows
;;

let registered_page t uuid = page_by_uuid t uuid

let registered_tree t uuid =
  Hashtbl.find_opt t.page_tree_interests (Graph.Uuid.to_string uuid)
;;

let registered_children t uuid =
  Hashtbl.find_opt t.children_interests (Graph.Uuid.to_string uuid)
;;

(* Keep reconciliation bursts below the worker budget without delaying foreground reads. *)
let maximum_active_hydration = 4

let favorite_request_current t pending =
  match pending.operation with
  | Favorite_read value -> Favorites.current t.favorites value
  | _ -> true
;;

let drain_hydration t =
  let rec drain reversed =
    if Hashtbl.length t.hydration_active >= maximum_active_hydration
       || Queue.is_empty t.hydration_queue
    then List.rev reversed
    else (
      let request = Queue.pop t.hydration_queue in
      let key = Graph.Uuid.to_string request in
      match Hashtbl.find_opt t.pending key with
      | Some pending when pending.delivery = Queued ->
        if favorite_request_current t pending
        then drain (issue_request t request :: reversed)
        else (
          Option.iter(fun token->t.on_change(Coordination.Change_consumer_retired(token,request))) pending.change_application;
          Hashtbl.remove t.pending key; drain reversed)
      | None | Some _ -> drain reversed)
  in
  drain []
;;

let background_demands t output =
  List.iter (fun (request : Graph.Uuid.t) ->
    match Hashtbl.find_opt t.pending (Graph.Uuid.to_string request) with
    | Some pending when pending.delivery = Planned -> pending.background <- true
    | None | Some _ -> ()) output.requests;
  output
;;

(* One dispatch per public transition. Delivery state makes queued/active
   ownership exclusive and suppresses repeated demand identities. *)
let dispatch_output t output =
  let foreground = List.filter_map (fun (request : Graph.Uuid.t) ->
    match Hashtbl.find_opt t.pending (Graph.Uuid.to_string request) with
    | Some pending when pending.delivery = Planned ->
      if pending.background then (
        pending.delivery <- Queued;
        Queue.push request t.hydration_queue;
        None)
      else Some (issue_request t request)
    | None | Some _ -> None) output.requests in
  { output with requests = foreground @ drain_hydration t }
;;

let retire_timeline t ~before ~after =
  let pages,entries = Journal_timeline_state.retired ~before ~after in
  if Rrbvec.is_empty pages && Rrbvec.is_empty entries then empty else (
    let detail_pages = Hashtbl.create (Hashtbl.length t.children_interests) in
    Hashtbl.iter (fun _ (interest:children_interest) ->
      Hashtbl.replace detail_pages (Graph.Uuid.to_string interest.page.uuid) ()) t.children_interests;
    let retained_blocks = Hashtbl.create (Rrbvec.length entries) in
    let iter_blocks f (entry:Projection.timeline_entry) =
      f (Journal_model.id entry.block);
      List.iter (fun (child:Projection.child_summary) -> f child.block_id) entry.child_summaries in
    Rrbvec.iter (fun (_,replacement) -> Option.iter
      (iter_blocks (fun id -> Hashtbl.replace retained_blocks id ())) replacement) entries;
    let retired_blocks = Hashtbl.create (Rrbvec.length entries) in
    Rrbvec.iter (fun ((entry:Projection.timeline_entry),_) ->
      if not (Hashtbl.mem detail_pages (Journal_model.page_id entry.block)) then
        iter_blocks (fun id -> if not (Hashtbl.mem retained_blocks id) then
          Hashtbl.replace retired_blocks id ()) entry) entries;
    Hashtbl.iter (fun id () ->
      Hashtbl.remove t.projected_blocks id;
      Hashtbl.remove t.block_revisions id;
      Hashtbl.remove t.tag_titles id;
      Hashtbl.remove t.changed_point_epochs id) retired_blocks;
    if Hashtbl.length retired_blocks > 0 then
      t.block_pages <- List.filter (fun (id,_) -> not (Hashtbl.mem retired_blocks id)) t.block_pages;
    let retired_pages = Hashtbl.create (Rrbvec.length pages) in
    Rrbvec.iter (fun (page:Projection.page) ->
      Hashtbl.remove t.page_tree_interests page.id;
      if not (Hashtbl.mem detail_pages page.id) then (
        Hashtbl.replace retired_pages page.id ();
        Hashtbl.remove t.graph_pages page.id;
        Hashtbl.remove t.page_revisions page.id)) pages;
    if Hashtbl.length retired_pages > 0 then
      t.pages <- List.filter (fun (id,_) -> not (Hashtbl.mem retired_pages id)) t.pages;
    if not (Journal_timeline_state.has_retained after) then Feed.reset t.feed else
      Feed.retire t.feed ~ports:(feed_ports t)
        ~pages:(Rrbvec.map (fun (page:Projection.page) -> page.id) pages) ~entries
        ~pending:(Hashtbl.to_seq_values t.pending |> Seq.filter_map (fun pending ->
          match pending.operation with Feed_read operation -> Some operation | _ -> None));
    let retired_requests = Hashtbl.create 8 in
    let rec prune output =
      let stale = Hashtbl.to_seq t.pending |> Seq.filter_map (fun (key,pending) ->
        match pending.operation with Feed_read operation when not (Feed.is_current t.feed operation) ->
          Some (key,pending,operation) | _ -> None) |> Rrbvec.of_seq in
      if Rrbvec.is_empty stale then output else (
        let output = Rrbvec.fold_left (fun output (key,pending,operation) ->
          Hashtbl.remove t.pending key;
          Hashtbl.remove t.hydration_active key;
          Hashtbl.replace retired_requests pending.original ();
          let previous = t.application_context and children = ref Rrbvec.empty in
          t.application_context <- Option.map (fun token -> token,pending.original,children)
            pending.change_application;
          let next = Fun.protect ~finally:(fun () -> t.application_context <- previous)
            (fun () -> Feed.superseded t.feed ~ports:(feed_ports t) operation |> feed_output) in
          Option.iter (fun token ->
            if not (Rrbvec.is_empty !children) then
              t.on_change (Coordination.Change_consumer_expanded (token,pending.original,!children));
            t.on_change (Coordination.Change_consumer_retired (token,pending.original))) pending.change_application;
          let next = if pending.background then background_demands t next else next in
          {requests=next.requests @ output.requests;responses=next.responses @ output.responses}) output stale in
        prune output) in
    let output = prune empty in
    let keep id = not (Hashtbl.mem retired_requests id) in
    Option.iter (fun (_,_,children) -> children := Rrbvec.filter keep !children) t.application_context;
    Hashtbl.iter (fun _ pending -> pending.external_children <- Rrbvec.filter keep pending.external_children) t.pending;
    for _ = 1 to Queue.length t.hydration_queue do
      let id = Queue.pop t.hydration_queue in
      if Hashtbl.mem t.pending (Graph.Uuid.to_string id) then Queue.push id t.hydration_queue
    done;
    dispatch_output t output)
;;

let capture_chain t ~(command:Projection.capture) =
  Hashtbl.to_seq_values t.pending |> Seq.find_map(fun pending->match pending.operation with
    | Capture_chain value when value.command.mutation_id=command.mutation_id
        && Child.matches_capture value.chain command->Some value.chain
    | _->None)
;;
let submit ?capture_chain:retained ?child_chain:retained_child t request =
  (match request,retained with
   | Journal_graph_request.Capture{command;_},Some chain
     when Child.matches_capture chain command && capture_chain t ~command=None ->
     (* A retained pure business owner survives Runtime reset. This root is a
        routing handle only; retry emits the exact existing stage wire. *)
     ignore(mutate t (Capture_chain{command;chain;projection=None})
       Stage : Graph.Uuid.t)
   | _->());
  (match request,retained_child with
   | Journal_graph_request.Create_child command,Some chain when Child.matches_child chain command ->
     let present=Hashtbl.to_seq_values t.pending |> Seq.exists(fun pending->match pending.operation with
       | Child_chain value->Child.matches_child value.chain command|_->false) in
     if not present then ignore(mutate t (Child_chain{chain;projection=None})
       Stage : Graph.Uuid.t)
   | _->());
  dispatch_output t (plan_request t request)


let remember_detail_members t ~page ~(root : Projection.block_member) children =
  let key = Graph.Uuid.to_string root.Projection.block.uuid in
  Hashtbl.replace t.detail_pages key page;
  List.iter
    (fun (member : Projection.block_member) ->
       Hashtbl.replace t.detail_pages (Graph.Uuid.to_string member.block.uuid) page)
    children.Projection.items;
  Hashtbl.replace t.detail_children key children
;;

let remember_detail_block t (block : Graph.block) revision =
  let key = Graph.Uuid.to_string block.uuid in
  Option.iter
    (fun (interest : children_interest) ->
       Hashtbl.replace
         t.children_interests
         key
         { interest with root = { block; revision } })
    (Hashtbl.find_opt t.children_interests key);
  Hashtbl.filter_map_inplace
    (fun _ children ->
       Some
         { children with
           Projection.items =
             List.map
               (fun (member : Projection.block_member) ->
                  if Graph.Uuid.equal member.block.uuid block.uuid
                  then { Projection.block; revision }
                  else member)
               children.Projection.items
         })
    t.detail_children
;;

let reference_ports t =
  Reference.
    { now = (fun () -> t.next_request)
    ; plan_read = (fun ~source_epoch value query ->
        read ?source_epoch ~background:true t (Reference_read value) query)
    ; known_page = (fun id -> Hashtbl.find_opt t.graph_pages id)
    }
;;

let reference_output (value : Reference.output) =
  { requests = Rrbvec.to_list value.requests
  ; responses =
      if Rrbvec.is_empty value.updates then []
      else [ response (Reference_sources_changed (Rrbvec.to_list value.updates)) ]
  }
;;

let hydration_for_changes t ~request_generation windows =
  let blocks, pages, structures = changed_interests windows in
  let favorites =
    Favorites.changes t.favorites ~ports:(favorites_ports t)
      ~blocks:(Rrbvec.of_list blocks) ~pages:(Rrbvec.of_list pages)
      ~structures:(Rrbvec.of_list structures) |> favorites_output
  in
  (* Fence old fragments before issuing the shared or dedicated point reads. *)
  List.iter (fun block -> Reference.fence t.references ~now:(fun () -> t.next_request) (Graph.Uuid.to_string block)) blocks;
  List.iter (fun page -> Reference.fence t.references ~now:(fun () -> t.next_request) (Graph.Uuid.to_string page)) pages;
  let owns_detail_page page =
    Hashtbl.to_seq_values t.children_interests
    |> Seq.exists (fun interest -> Graph.Uuid.equal interest.page.uuid page)
  in
  let refreshed_pages = Hashtbl.create 16 in
  let point_reads =
    List.filter_map
      (fun block ->
         let block_id = Graph.Uuid.to_string block in
         if Hashtbl.mem t.graph_pages block_id && owns_detail_page block then (
           Hashtbl.replace refreshed_pages block_id ();
           Some (read t (Changed_detail_page block)
             (Worker.Page {uuid=block;revision=None})))
         else (
           match page_by_block t block_id with
         | Some _ ->
           Some
             (read
                t
                (Changed_block { block_id })
                (Worker.Outline_block {uuid=block;revision=None}))
         | None ->
           Option.map
             (fun _ ->
                read
                  t
                  (Changed_detail_block { block_id; observed=false })
                  (Worker.Outline_block {uuid=block;revision=None}))
               (Hashtbl.find_opt t.detail_pages block_id)))
      blocks
  in
  let reference_reads =
    List.filter_map
      (fun block ->
        let id = Graph.Uuid.to_string block in
        Reference.plan_change t.references ~ports:(reference_ports t)
          (Block_changed { id; journal_block_known = Option.is_some (page_by_block t id) }))
      blocks
    @ List.filter_map
        (fun page ->
          Reference.plan_change t.references ~ports:(reference_ports t)
            (Page_changed { id = Graph.Uuid.to_string page
                          ; detail_page_owned = (fun () -> owns_detail_page page) }))
        pages
  in
  let tree_reads =
    List.filter_map
      (function
        | Worker_pure_data.V2_page_tree_interest page ->
          Option.bind (registered_tree t page) (fun interest ->
            if Feed.retained_page t.feed interest.page.id then None else Feed.reconcile_page t.feed ~ports:(feed_ports t)
              ~page:interest.page ~limit:interest.limit)
        | Worker_pure_data.V2_children_interest _ | Worker_pure_data.V2_journal_index_interest -> None)
      structures
  in
  let detail_page_reads =
    List.filter_map
      (fun page ->
         if owns_detail_page page
            && not (Hashtbl.mem refreshed_pages (Graph.Uuid.to_string page))
         then
           Some
             (read
                t
                (Changed_detail_page page)
                (Worker.Page {uuid=page;revision=None}))
         else None)
      pages
  in
  let children_reads =
    List.filter_map
      (function
        | Worker_pure_data.V2_children_interest parent ->
          Option.map
            (fun interest ->
               read
                 t
                 (Changed_children interest)
                 ~maximum_items:interest.limit (Worker.Child_members{parent;revision=None;after=None}))
            (registered_children t parent)
        | Worker_pure_data.V2_page_tree_interest _ | Worker_pure_data.V2_journal_index_interest -> None)
      structures
  in
  let journal_changed =
    List.exists
      (function
        | Worker_pure_data.V2_journal_index_interest -> true
        | Worker_pure_data.V2_children_interest _ | Worker_pure_data.V2_page_tree_interest _ -> false)
      structures
    || List.exists (fun page -> Option.is_some (registered_page t page)) pages
  in
  report_timeline "runtime-interest"
    [ "requestGeneration", `String (Int64.to_string request_generation)
    ; "journalChanged", `Bool journal_changed
    ; "hasInitialFeed", `Bool (Feed.has_initial_feed t.feed)
    ; "registeredPageHit", `Bool (List.exists (fun page -> Option.is_some (registered_page t page)) pages)
    ; "pageCount", `Int (List.length pages)
    ; "pages", `List (List.take 16 pages |> List.map (fun u -> `String (Graph.Uuid.to_string u)))
    ; "blockCount", `Int (List.length blocks)
    ; "blocks", `List (List.take 16 blocks |> List.map (fun u -> `String (Graph.Uuid.to_string u)))
    ; "interestCount", `Int (List.length structures)
    ; "interests", `List (List.take 16 structures |> List.map (function
        | Worker_pure_data.V2_journal_index_interest -> `Assoc ["kind", `String "journal-index"]
        | Worker_pure_data.V2_children_interest u -> `Assoc ["kind", `String "children"; "target", `String (Graph.Uuid.to_string u)]
        | Worker_pure_data.V2_page_tree_interest u -> `Assoc ["kind", `String "page-tree"; "target", `String (Graph.Uuid.to_string u)]))
    ; "truncated", `Bool (List.length pages > 16 || List.length blocks > 16 || List.length structures > 16)
    ];
  let timeline = Feed.validate_retained t.feed ~ports:(feed_ports t) ~request_generation ~refresh:journal_changed |> feed_output in
  let timeline = if journal_changed && Feed.has_retained t.feed then
    {timeline with responses=response (Feed_refresh_started {request_generation})::timeline.responses} else timeline in
  let journal =
    if not journal_changed || Feed.has_retained t.feed then empty else
      match Feed.refresh_initial t.feed ~ports:(feed_ports t) ~request_generation with
      | None -> empty
      | Some planned ->
        let output = feed_output planned in
        {output with responses=response (Feed_refresh_started {request_generation})::output.responses}
  in
  background_demands
    t
    { requests =
        point_reads
        @ reference_reads
        @ tree_reads
        @ children_reads
        @ detail_page_reads
        @ journal.requests
        @ timeline.requests
        @ favorites.requests
    ; responses = journal.responses @ timeline.responses @ favorites.responses
    }
;;

let rehydrate_current_interests t ~request_generation ~generation =
  Hashtbl.clear t.changed_point_epochs;
  t.change_generation <- Some generation;
  t.change_cursor <- None;
  t.task_catalog_started <- false;
  t.task_catalog_loading <- false;
  Hashtbl.clear t.task_catalog_deletions;
  t.task_catalog_complete <- false;
  t.task_catalog_epoch <- t.next_request;
  Hashtbl.clear t.task_lookup_epochs;
  let graph_info = read t Graph_info Worker.Graph_info in
  let timeline = Feed.validate_retained t.feed ~ports:(feed_ports t) ~request_generation ~refresh:true |> feed_output in
  let timeline = if Feed.has_retained t.feed then
    {timeline with responses=response (Feed_refresh_started {request_generation})::timeline.responses} else timeline in
  let journal =
    if Feed.has_retained t.feed then empty else match Feed.refresh_initial t.feed ~ports:(feed_ports t) ~request_generation with
    | None -> empty
    | Some planned ->
      let output = feed_output planned in
      {output with responses=response (Feed_refresh_started {request_generation})::output.responses}
  in
  let tree_requests =
    Hashtbl.to_seq_values t.page_tree_interests
    |> List.of_seq
    |> List.filter_map (fun (interest : page_tree_interest) ->
      if Feed.retained_page t.feed interest.page.id then None else Feed.reconcile_page t.feed ~ports:(feed_ports t)
        ~page:interest.page ~limit:interest.limit)
  in
  let children_requests =
    Hashtbl.to_seq t.children_interests
    |> List.of_seq
    |> List.filter_map (fun (parent_id, (interest : children_interest)) ->
      match parse_uuid "parent UUID" parent_id with
      | Error _ -> None
      | Ok parent ->
        Some
          (read
             t
             (Changed_children interest)
             ~maximum_items:interest.limit (Worker.Child_members{parent;revision=None;after=None})))
  in
  let reference_requests =
    Reference.resync t.references ~ports:(reference_ports t) |> Rrbvec.to_list
  in
  let detail_roots =
    Hashtbl.to_seq_values t.children_interests
    |> Seq.filter (fun (interest : children_interest) ->
      not (Graph.Uuid.equal interest.root.block.uuid interest.page.uuid))
    |> Seq.map (fun (interest : children_interest) ->
      let block_id = Graph.Uuid.to_string interest.root.block.uuid in
      read
        t
        (Changed_detail_block { block_id; observed=false })
        (Worker.Outline_block {uuid=interest.root.block.uuid;revision=None}))
    |> List.of_seq
  in
  let detail_pages = Hashtbl.create 16 in
  Hashtbl.iter
    (fun _ (interest : children_interest) ->
       Hashtbl.replace
         detail_pages
         (Graph.Uuid.to_string interest.page.uuid)
         interest.page.uuid)
    t.children_interests;
  let detail_page_requests =
    Hashtbl.to_seq_values detail_pages
    |> Seq.map (fun page ->
      read t (Changed_detail_page page) (Worker.Page {uuid=page;revision=None}))
    |> List.of_seq
  in
  background_demands
    t
    { requests =
        (graph_info :: (timeline.requests @ journal.requests))
        @ tree_requests
        @ children_requests
        @ detail_roots
        @ detail_page_requests
        @ reference_requests
    ; responses =
        response Projection_resync :: response Favorites_invalidated :: (timeline.responses @ journal.responses)
    }
;;

let remember_block_revision t uuid revision =
  Hashtbl.replace t.block_revisions (Graph.Uuid.to_string uuid) revision
;;

let remember_page_revision t uuid revision =
  Hashtbl.replace t.page_revisions (Graph.Uuid.to_string uuid) revision
;;

let remember_scope_revision t scope revision =
  let scope =
    match scope with
    | Worker_pure_data.V2_children_revision parent -> Worker_pure_data.V2_children_scope parent
  in
  Hashtbl.replace t.scope_revisions (scope_key scope) revision
;;

let detail_children t ~generation ~page ~root ~limit ~after =
  let interest = { page; root; limit } in
  Hashtbl.replace
    t.children_interests
    (Graph.Uuid.to_string root.Projection.block.uuid)
    interest;
  requests
    [ read
        t
        (Detail_children { generation; page; root; after; limit })
        ~maximum_items:limit
        (Worker.Child_members {parent=root.block.uuid;revision=None;after=Option.map(fun (cursor:Projection.child_cursor)->cursor.after)after})
    ]
;;

let detail_projection t ~page ~time_context ~root children =
  Result.map
    (fun (detail : Projection.detail) ->
       let tagged block =
         Journal_model.with_tag_titles block
           ~tag_titles:(Option.value
             (Hashtbl.find_opt t.tag_titles (Journal_model.id block)) ~default:[])
       in
       (* This is the already returned, bounded child page; metadata needs no reads. *)
       { Projection.root = tagged detail.root
       ; children = { detail.children with blocks = List.map tagged detail.children.blocks }
       })
    (Projection.detail_on_page ~page ~time_context ~root children)
;;

let complete_child ~parent_child_count ~child_child_count t (command : Projection.create_child) (page : Graph.page)
      (child : Projection.block_member) (parent : Projection.block_member) =
  if Graph.Uuid.to_string parent.block.uuid <> command.parent_block_id
     || Graph.Uuid.to_string child.block.uuid <> command.block_id
    || (not (Graph.Uuid.equal child.block.parent parent.block.uuid))
    || (not (Graph.Uuid.equal child.block.page page.uuid))
     || not (Graph.Uuid.equal parent.block.page page.uuid)
  then reject "The append completion does not match the selected parent."
  else (
    match projection_time_context t with
  | Error message -> reject message
  | Ok time_context ->
      (match
      (Projection.block_on_page ~page ~revision:parent.revision
         ~child_count:parent_child_count ~time_context parent.block,
       Projection.block_on_page ~page ~revision:child.revision ~child_count:child_child_count
         ~time_context child.block) with
    | Ok parent, Ok child ->
      let parent=Journal_model.with_tag_titles parent
        ~tag_titles:(Option.value(Hashtbl.find_opt t.tag_titles command.parent_block_id)~default:[]) in
      let child=Journal_model.with_tag_titles child
        ~tag_titles:(Option.value(Hashtbl.find_opt t.tag_titles command.block_id)~default:[]) in
      Hashtbl.replace t.projected_blocks command.parent_block_id parent;
      responses[response(Child_created{child;parent;timeline_entry_update=None})]
       | Error message, _ | _, Error message -> reject message))
;;

let finish_child_parent t ~root ~round ~(summary:Worker.block_summary) parent =
  match child_root t root with
  | None -> empty
  | Some(_,chain,_) ->
    let next,action=Child.projection_ready chain ~round in
    (match action,summary.lookup with
     | Child.Present _,Worker_pure_data.V2_present_block{value;revision} ->
       remember_block_revision t value.block.uuid revision;
       Hashtbl.replace t.tag_titles (Graph.Uuid.to_string value.block.uuid) value.tag_titles;
       let child=Projection.{block=value.block;revision} in
       (* These counts are lower bounds from the actual child snapshot, never a
          fabricated parent total or an increment of an old projection. *)
       let output=complete_child ~parent_child_count:1
         ~child_child_count:(List.length summary.items + if summary.next=None then 0 else 1)
         t (Child.command chain) (Child.page chain) child parent in
       (match List.find_map (fun response->match response.payload with
          | Child_created _ as value->Some value|_->None) output.responses with
        | Some projection->child_action t root next (Some projection) action
        | None->scope_output t (Some(Child_owner{mutation_id=(Child.command chain).mutation_id;
            block_id=(Child.command chain).block_id})) output)
     | Child.Ignore,_->empty
     | _->responses[child_failure (Child.command chain) "The canonical child projection is unavailable."])
;;

let publish_changed_point
      t
      ~block_id
      ~(value : Worker_pure_data.block_record)
      ~revision
      ~child_count
      ~(page : Graph.page)
  =
  match projection_time_context t with
  | Error message -> reject message
  | Ok time_context ->
    (match
       Projection.block_on_page
         ~page
         ~revision
         ~child_count
         ~time_context
         value.Worker_pure_data.block
     with
     | Error message -> reject message
     | Ok projected ->
       let projected =
         Journal_model.with_tag_titles projected ~tag_titles:value.tag_titles
       in
       Hashtbl.replace t.graph_pages (Graph.Uuid.to_string page.uuid) page;
       (match page_of_graph_page page with
        | Some journal ->
          remember_page t journal;
          remember_block_page t journal block_id
        | None ->
          t.block_pages <- List.filter (fun (id, _) -> id <> block_id) t.block_pages);
       if Hashtbl.mem t.detail_pages block_id
       then Hashtbl.replace t.detail_pages block_id page;
       Option.iter
         (fun (interest : children_interest) ->
            Hashtbl.replace t.children_interests block_id { interest with page })
         (Hashtbl.find_opt t.children_interests block_id);
       remember_block_revision t value.block.uuid revision;
       remember_detail_block t value.block revision;
       Hashtbl.replace t.projected_blocks block_id projected;
       responses
         [ response (Block_updated { block = projected; timeline_entry_update = None }) ])
;;

let resolve_changed_point
      t
      ~source_epoch
      ~block_id
      ~(value : Worker_pure_data.block_record)
      ~revision
  =
  let child_count =
    Hashtbl.find_opt t.projected_blocks block_id
    |> Option.map Journal_model.child_count
    |> Option.value ~default:0
  in
  let page =
    match Hashtbl.find_opt t.graph_pages (Graph.Uuid.to_string value.block.page) with
    | Some page -> Some page
    | None ->
      (match Hashtbl.find_opt t.detail_pages block_id with
       | Some page when Graph.Uuid.equal page.uuid value.block.page -> Some page
       | _ -> None)
  in
  match page with
  | Some page when not page.recycled ->
    publish_changed_point t ~block_id ~value ~revision ~child_count ~page
  | Some _ -> reject "The changed block page is unavailable."
  | None ->
    requests
      [ read
          ~source_epoch
          t
          (Changed_point_context { block_id; value; revision; child_count })
          (Worker.Page {uuid=value.block.page;revision=None})
      ]
;;

let operation_name = function
  | Feed_read operation -> Feed.operation_name operation
  | Reference_read _ -> "readUuidReference"
  | Favorite_read value -> Favorites.operation_name value
  | Task_catalog _ -> "listTaskStatuses"
  | Task_definitions _ -> "readTaskStatuses"
  | Graph_info -> "graphInfo"
  | Admission_info _ -> "inspectAdmission"
  | Pull_changes _ -> "pullChanges"
  | Acknowledge_changes _ -> "ackChanges"
  | Detail_block _ -> "loadDetailBlock"
  | Detail_page _ -> "loadDetailPage"
  | Child_chain _ -> "coordinateChild"
  | Capture_chain _ -> "coordinateCapture"
  | Child_write _ -> "mutateChild"
  | Child_canonical _ -> "readCanonicalChild"
  | Child_chain_parent _ -> "readCanonicalChildParent"
  | Child_ack _ -> "acknowledgeChildOutcome"
  | Child_insert _ -> "appendChild"
  | Changed_block _ -> "reconcileChangedBlock"
  | Changed_detail_block _ -> "reconcileChangedDetailBlock"
  | Changed_point_context _ -> "resolveChangedBlockPage"
  | Changed_detail_page _ -> "reconcileChangedDetailPage"
  | Find_block_result -> "findBlock"
  | Detail_children _ -> "loadDetailChildren"
  | Changed_children _ -> "refreshChildren"
  | Capture_append _ -> "appendCapture"
  | Target_summary _ -> "readMutationTargetSummary"
  | Mutation_refresh _ -> "refreshMutation"
  | Delete_mutation _ -> "deleteSubtree"
;;

let failure_output
      ~source_epoch
      ?(code = Error.Unsupported_semantics)
      ?error
      t
      operation
      request_id
      message
  =
  let request_id, error = match error with
    | Some error -> request_id,error
    | None -> worker_error code request_id message in
  let worker_failure = { operation = operation_name operation; request_id; error } in
  match operation with
  | Task_catalog { epoch; _ } when epoch <> t.task_catalog_epoch -> empty
  | Task_catalog _ ->
    t.task_catalog_loading <- false;
    Hashtbl.clear t.task_catalog_deletions;
    responses [ task_catalog_response ~error:message t; response(Diagnostic worker_failure) ]
  | Task_definitions ids ->
    let current = ref false in
    List.iter
      (fun uuid ->
         let id = Graph.Uuid.to_string uuid in
         if Hashtbl.find_opt t.task_lookup_epochs id = Some source_epoch
         then (
           current := true;
           Hashtbl.remove t.task_lookup_epochs id))
      ids;
    if !current then responses [ task_catalog_response ~error:message t;
      response(Diagnostic worker_failure) ] else empty
  | Favorite_read value ->
    Favorites.fail t.favorites value ~request_id ~code ~message ~error |> favorites_output
  | Feed_read operation ->
    responses [response (match Feed.failure_scope operation with
      | Feed request_generation -> Feed_failed {request_generation;failure=Worker_failure worker_failure}
      | Day {day;request_generation} -> Day_blocks_failed {day;request_generation;stale_cursor=code=Error.Stale_read_cursor;failure=Worker_failure worker_failure}
      | Reconciliation -> Rejected (Worker_failure worker_failure))]
  | Mutation_refresh { page; refresh = Updated { block_id } } when code = Error.Conflict
    -> request_target_summary t page (Update_conflict_refresh { block_id })
  | Graph_info -> responses [ response (Open_failed worker_failure) ]
  | Admission_info request -> responses [ response (Admission_unavailable request);
      response(Diagnostic worker_failure) ]
  | Pull_changes _ | Acknowledge_changes _ ->
    responses [ response (Rejected (Worker_failure worker_failure)) ]
  | Detail_block { generation; block_id; _ } ->
    responses
      [ response
          (Detail_failed
             { request_generation = generation
             ; block_id
             ; missing = false
             ; stale_cursor = code = Error.Stale_read_cursor
             ; failure = Worker_failure worker_failure
             })
      ]
  | Detail_page { generation; root; _ } | Detail_children { generation; root; _ } ->
    responses
      [ response
          (Detail_failed
             { request_generation = generation
             ; block_id = Graph.Uuid.to_string root.block.uuid
             ; missing = false
             ; stale_cursor = code = Error.Stale_read_cursor
             ; failure = Worker_failure worker_failure
             })
      ]
  | Child_chain _ | Capture_chain _ ->
    let output=child_step t request_id(fun chain->Child.interrupted chain ~index:0 ~round:1L message) in
    {output with responses=response(Diagnostic worker_failure)::output.responses}
  | Child_write{root;index;round}|Child_ack{root;index;round;_}->
    let output=child_step t root(fun chain->Child.interrupted chain ~index ~round message) in
    {output with responses=response(Diagnostic worker_failure)::output.responses}
  | Child_canonical{root;round}|Child_chain_parent{root;round;_}->
    let output=child_step t root(fun chain->Child.read_failed chain ~round message) in
    {output with responses=response(Diagnostic worker_failure)::output.responses}
  | Child_insert (command, _) ->
    responses
      [ response
          (Child_failed
             { mutation_id = command.mutation_id
             ; block_id = command.block_id
             ; failure = Worker_failure worker_failure
             })
      ]
  | Reference_read { block_id; depth; _ } ->
    let output=Reference.read_failed t.references ~ports:(reference_ports t) ~source_epoch ~block_id ~depth
      |> reference_output in
    {output with responses=response(Diagnostic worker_failure)::output.responses}
  | Changed_block { block_id; _ } | Changed_detail_block { block_id; _ } | Changed_point_context {block_id;_} ->
    let invalidation =
      Reference.shared_read_failed t.references ~ports:(reference_ports t)
        ~source_epoch ~block_id |> reference_output
    in
    { invalidation with
      responses =
        response (Rejected (Worker_failure worker_failure)) :: invalidation.responses
    }
  | Find_block_result
  | Changed_detail_page _
  | Changed_children _
  | Capture_append _
  | Target_summary _
  | Mutation_refresh _
  | Delete_mutation _ -> responses [ response (Rejected (Worker_failure worker_failure)) ]
;;

let children_result items continuation : Projection.children_page =
  { items =
      List.map
        (fun (item : Worker_pure_data.child_member) ->
           Projection.{ block = item.value.block; revision = item.revision })
        items
  ; continuation
  }
;;

let newer_target_point t pending =
  match pending.failure_owner with
  |Some(Mutation_owner{block_id;_})->
    Option.exists(fun epoch->epoch>pending.source_epoch)
      (Hashtbl.find_opt t.changed_point_epochs block_id)
  |_->false
;;

let resample_confirmation t ~finished durable =
  let key=Graph.Uuid.to_string finished in
  let root_key=Graph.Uuid.to_string durable.root_request in
  if key<>root_key then (
    Option.iter(fun pending->Option.iter(fun token->
      t.on_change(Coordination.Change_consumer_retired(token,finished)))pending.change_application)
      (Hashtbl.find_opt t.pending key);
    Hashtbl.remove t.pending key;
    Hashtbl.remove t.hydration_active key);
  match Hashtbl.find_opt t.pending root_key with
  |None->empty
  |Some pending->
    Hashtbl.replace t.pending root_key {pending with delivery=Planned};
    dispatch_output t (requests[durable.root_request])
;;

let receive_result t ~origin ~request_id result =
  let key = Graph.Uuid.to_string request_id in
  match Hashtbl.find_opt t.pending key with
  | None -> empty
  | Some {operation=Feed_read operation;_} when not (Feed.is_current t.feed operation) ->
    Hashtbl.remove t.pending key; Feed.superseded t.feed ~ports:(feed_ports t) operation |> feed_output
  | Some {operation;source_epoch;_} when not(changed_point_current t operation source_epoch)->
    Hashtbl.remove t.pending key;empty
  | Some { operation = Target_summary summary; source_epoch; _ }
    when not (Confirmation.current t.confirmations summary) ->
    Hashtbl.remove t.pending key;
    failure_output
      ~source_epoch
      t
      (Target_summary summary)
      request_id
      "The target confirmation was superseded."
  | Some { operation; source_epoch; _ } ->
    let failure_output = failure_output ~source_epoch in
    Hashtbl.remove t.pending key;
    (match (match operation,result with
       | Feed_read operation,Query_result(query,value) ->
         Feed.receive ?session:(Option.map fst origin) t.feed ~ports:(feed_ports t) operation query value
       | Feed_read operation,Read_failed{code;_} ->
         Feed.failed t.feed ~ports:(feed_ports t) operation ~code
       | Feed_read operation,Read_error error ->
         Feed.failed t.feed ~ports:(feed_ports t) operation ~code:(Error.code error)
       | _ -> None) with
     | Some planned -> feed_output ~source:(operation_name operation,request_id) planned
     | _ -> (match result with
     | Query_result (Worker.Favorites _, result) ->
       (match operation with
        | Favorite_read read when Favorites.accepts_list read ->
          Favorites.receive_list t.favorites ~ports:(favorites_ports t) read result
          |> favorites_output |> background_demands t
        | _ -> failure_output t operation request_id "Unexpected favorites response.")
     | (Read_failed _ | Read_error _) as failed ->
       let code,message,error=match failed with
         | Read_failed{code;message}->code,message,None
         | Read_error error->Error.code error,Error.message error,Some error
         | _->assert false in
       (match operation with
        | Target_summary summary when code = Error.Stale_read_cursor ->
          (match Confirmation.retry_stale t.confirmations ~ports:(confirmation_ports t) summary with
           | Some planned -> confirmation_planning planned
           | None -> failure_output ~code ?error t operation request_id message)
        | Delete_mutation command when code = Error.Conflict ->
          request_delete_summary t command.block_id
        | _ -> failure_output ~code ?error t operation request_id message)
     | Changes_resync reason -> failure_output t operation request_id reason
     | Changes_retired -> empty
     | Query_result (Worker.Graph_info, value) ->
       let generation=value.Worker.generation in
       (match operation with
        | Graph_info ->
          if t.change_generation<>Some generation then t.change_cursor<-None;
          t.change_generation<-Some generation;
          let catalog =
            if t.task_catalog_started then [] else [ request_task_catalog t ]
          in
          { requests = catalog; responses = [ response Graph_ready ] }
        | _ -> failure_output t operation request_id "Unexpected graph-info response.")
     | Query_result (Worker.Task_statuses _, catalog) ->
       let property_uuid=catalog.Worker.property_uuid and default_status=catalog.default_status
       and items=catalog.items and next_cursor=catalog.next in
       (match operation with
        | Task_catalog { epoch; _ } when epoch <> t.task_catalog_epoch -> empty
        | Task_catalog { epoch; seen; _ } ->
              t.task_property <- property_uuid;
              t.default_task_status <- default_status;
              let seen =
                List.fold_left
                  (fun seen (definition : Graph.task_status_definition) ->
                     let id = Graph.Uuid.to_string definition.uuid in
                     (match
                        ( Hashtbl.find_opt t.task_catalog_deletions id
                        , Hashtbl.find_opt t.task_definitions id )
                      with
                      | Some deleted, _ when deleted > epoch -> ()
                      | _, Some (previous, _) when previous > epoch -> ()
                      | _ -> Hashtbl.replace t.task_definitions id (epoch, Some definition));
                     Rrbvec.push_back seen id)
                  seen
                  items
              in
              let requests =
                match next_cursor with
                | Some cursor ->
                  [ read
                      t
                      (Task_catalog { epoch; seen; after = Some cursor })
                      ~maximum_items:Worker_pure_data.maximum_page_size (Worker.Task_statuses (Some cursor))
                  ]
                | None ->
                  let seen =
                    Rrbvec.to_seq seen |> Seq.map (fun id -> id, ()) |> Hashtbl.of_seq
                  in
                  Hashtbl.filter_map_inplace
                    (fun id (previous, value) ->
                       if previous <= epoch && not (Hashtbl.mem seen id)
                       then None
                       else Some (previous, value))
                    t.task_definitions;
                  t.task_catalog_complete <- true;
                  t.task_catalog_loading <- false;
                  Hashtbl.clear t.task_catalog_deletions;
                  Hashtbl.filter_map_inplace
                    (fun _ lookup_epoch ->
                       if lookup_epoch < epoch then None else Some lookup_epoch)
                    t.task_lookup_epochs;
                  (match t.default_task_status with
                   | Some uuid
                     when not (Hashtbl.mem t.task_definitions (Graph.Uuid.to_string uuid)) ->
                     t.default_task_status <- None
                   | _ -> ());
                  []
              in
              { requests
              ; responses = (if next_cursor = None then [ task_catalog_response t ] else [])
              }
        | _ -> failure_output t operation request_id "Unexpected status catalog response.")
     | Query_result (Worker.Task_status_definitions _, definitions) ->
       (match operation with
        | Task_definitions ids
          when List.length ids = List.length definitions
               && List.for_all2
                    (fun id ->
                       Option.fold
                         ~none:true
                         ~some:(fun (d : Graph.task_status_definition) ->
                           Graph.Uuid.equal id d.uuid))
                    ids
                    definitions ->
          let changed = ref false in
          let restart_catalog = ref false in
          List.iter2
            (fun uuid definition ->
               let id = Graph.Uuid.to_string uuid in
               if Hashtbl.find_opt t.task_lookup_epochs id = Some source_epoch
               then (
                 Hashtbl.remove t.task_lookup_epochs id;
                 let previous = Hashtbl.find_opt t.task_definitions id in
                 if
                   not
                     (Option.fold
                        ~none:false
                        ~some:(fun (epoch, _) -> epoch > source_epoch)
                        previous)
                 then (
                   if Option.bind previous snd <> definition then changed := true;
                   match definition with
                   | None ->
                     Hashtbl.remove t.task_definitions id;
                     if t.task_catalog_loading
                     then
                       if
                         Hashtbl.length t.task_catalog_deletions < 10000
                         || Hashtbl.mem t.task_catalog_deletions id
                       then Hashtbl.replace t.task_catalog_deletions id source_epoch
                       else restart_catalog := true
                   | Some _ ->
                     Hashtbl.replace t.task_definitions id (source_epoch, definition))))
            ids
            definitions;
          (match t.default_task_status with
           | Some uuid
             when List.exists (Graph.Uuid.equal uuid) ids
                  && not
                       (Option.fold
                          ~none:false
                          ~some:(fun (_, d) -> Option.is_some d)
                          (Hashtbl.find_opt
                             t.task_definitions
                             (Graph.Uuid.to_string uuid))) ->
             t.default_task_status <- None
           | _ -> ());
          let requests = if !restart_catalog then [ request_task_catalog t ] else [] in
          { requests; responses = (if !changed then [ task_catalog_response t ] else []) }
        | _ -> failure_output t operation request_id "Unexpected status lookup response.")
     | Query_result (Worker.Admission, observation) ->
       (match operation with
        | Admission_info request ->
          responses [ response (Admission_inspected { request; observation }) ]
        | _ -> failure_output t operation request_id "Unexpected admission response.")
     | Query_result (Worker.Journals _, journals) ->
       let items=journals.Worker.items in
       List.iter
         (fun (item : Worker_pure_data.journal_item) ->
            Hashtbl.replace t.graph_pages (Graph.Uuid.to_string item.page.uuid) item.page;
            remember_page_revision t item.page.uuid item.revision)
         items;
       (match operation with
        | _ -> failure_output t operation request_id "Unexpected journal response.")
     | Query_result (Worker.Page _, lookup) ->
       (match lookup, operation with
        |Worker_pure_data.V2_present_page{page;revision=page_revision},Changed_point_context{block_id;value;revision;child_count}
          when Graph.Uuid.equal page.uuid value.block.page && not page.recycled->
          remember_page_revision t page.uuid page_revision;
          publish_changed_point t ~block_id ~value ~revision ~child_count ~page
        |_,Changed_point_context _->reject "The changed block page is unavailable."
        | ( (Worker_pure_data.V2_present_page _ | Worker_pure_data.V2_missing_page _)
          , Reference_read ({ lookup = Reference.Page_lookup; _ } as value) ) ->
          Reference.receive_page t.references ~ports:(reference_ports t)
            ~source_epoch value lookup |> reference_output
        | ( Worker_pure_data.V2_present_page { page; revision }
          , Detail_block { generation; block_id; limit; after } )
          when Graph.Uuid.to_string page.uuid = block_id && not page.recycled ->
          remember_page_revision t page.uuid revision;
          Hashtbl.replace t.graph_pages block_id page;
          detail_children t ~generation ~page ~root:(page_root_member page revision) ~limit ~after
        | ( (Worker_pure_data.V2_missing_page _ | Worker_pure_data.V2_present_page _)
          , Detail_block { generation; block_id; _ } ) ->
          responses [response (Detail_failed {request_generation=generation;block_id;
            missing=true;stale_cursor=false;failure=Projection_failure "This page is unavailable."})]
        | Worker_pure_data.V2_present_page {page;revision}, Child_chain_parent{root;round;summary}
          when not page.recycled ->
          remember_page_revision t page.uuid revision;
          Hashtbl.replace t.graph_pages (Graph.Uuid.to_string page.uuid) page;
          finish_child_parent t ~root ~round ~summary (page_root_member page revision)
        | _, Favorite_read value when Favorites.accepts_page t.favorites value ->
          let planned = Favorites.receive_page t.favorites ~ports:(favorites_ports t) value lookup in
          let output = favorites_output planned in
          if planned.background then background_demands t output else output
        | Worker_pure_data.V2_present_page { page; revision }, Changed_detail_page _ when not page.recycled ->
          Hashtbl.replace t.graph_pages (Graph.Uuid.to_string page.uuid) page;
          remember_page_revision t page.uuid revision;
          let reconciled = ref [] in
          Hashtbl.filter_map_inplace
            (fun key (interest : children_interest) ->
               if Graph.Uuid.equal interest.page.uuid page.uuid
               then (
                 let root = if Graph.Uuid.equal interest.root.block.uuid page.uuid
                   then page_root_member page revision else interest.root in
                 let interest = { interest with page; root } in
                 Option.iter
                   (fun children ->
                      match projection_time_context t with
                      | Error _ -> reconciled := response (Projection_unavailable `Detail_calendar) :: !reconciled
                      | Ok time_context ->
                        (match
                           detail_projection
                             t
                             ~page
                             ~time_context
                             ~root:interest.root
                             children
                         with
                         | Ok detail ->
                           reconciled
                           := response (Children_reconciled detail) :: !reconciled
                         | Error message ->
                           let reason =
                             if String.starts_with ~prefix:"local time conversion failed:" message
                                || String.starts_with ~prefix:"creation local " message
                             then `Detail_time else `Detail in
                           reconciled := response (Projection_unavailable reason) :: !reconciled))
                   (Hashtbl.find_opt t.detail_children key);
                 Some interest)
               else Some interest)
            t.children_interests;
          Hashtbl.filter_map_inplace
            (fun _ (old : Graph.page) ->
               Some (if Graph.Uuid.equal old.Graph.uuid page.uuid then page else old))
            t.detail_pages;
          responses (List.rev !reconciled)
        | ( ( Worker_pure_data.V2_missing_page { uuid; _ }
            | Worker_pure_data.V2_present_page { page = { uuid; recycled = true; _ }; _ } )
          , Changed_detail_page _ ) ->
          responses
            (Hashtbl.to_seq_values t.children_interests
             |> Seq.filter_map (fun (interest : children_interest) ->
               if Graph.Uuid.equal interest.page.uuid uuid
               then
                 Some
                   (response
                      (Block_removed
                         { block_id = Graph.Uuid.to_string interest.root.block.uuid }))
               else None)
             |> List.of_seq)
        | ( Worker_pure_data.V2_present_page { page; revision }
          , Detail_page { generation; root; limit; after } ) ->
          remember_page_revision t page.uuid revision;
          if page.recycled
          then failure_output t operation request_id "The block page is unavailable."
          else (
            Hashtbl.replace t.graph_pages (Graph.Uuid.to_string page.uuid) page;
            detail_children t ~generation ~page ~root ~limit ~after)
        | Worker_pure_data.V2_missing_page _, Detail_page { generation; root; _ } ->
          responses
            [ response
                (Detail_failed
                   { request_generation = generation
                   ; block_id = Graph.Uuid.to_string root.block.uuid
                   ; missing = true
                   ; stale_cursor = false
                   ; failure = Projection_failure "This block's page is unavailable."
                   })
            ]
        | _ -> failure_output t operation request_id "Unexpected page response.")
     | Query_result (Worker.Block_summary _, target_summary) ->
       let lookup=target_summary.Worker.lookup and page=target_summary.page
       and items=target_summary.items and scope_revision=target_summary.scope_revision
       and generation=target_summary.generation and projection_revision=target_summary.projection_revision in
       (match operation with
        | Child_canonical{root;round}->
          child_step t root(fun chain->Child.read_child chain ~round target_summary)
        | Target_summary summary ->
          (match Confirmation.receive_summary t.confirmations ~ports:(confirmation_ports t) summary
               ~lookup ~page ~items ~next_cursor:target_summary.next
               ~scope_revision ~generation ~projection_revision with
           | Continue planned -> confirmation_planning planned
           | Failed message -> failure_output t operation request_id message
           | Absent {purpose=Delete_conflict_refresh _;block_id} ->
             responses [response (Subtree_deleted {block_id;deleted_count=Some 0;
               parent=None;timeline_entry_update=None})]
           | Absent _ -> failure_output t operation request_id "Unexpected absent target owner."
           | Confirmed {purpose;block_id;value;revision;page;page_revision;scope_revision;children} ->
                 (match projection_time_context t with
                  | Error message -> failure_output t operation request_id message
                  | Ok time_context ->
                    (match
                       Projection.block_on_page
                         ~page
                         ~revision
                         ~child_count:(Rrbvec.length children)
                         ~time_context
                         value.block
                     with
                     | Error message -> failure_output t operation request_id message
                     | Ok block ->
                       let block =
                         Journal_model.with_tag_titles block ~tag_titles:value.tag_titles
                       in
                       let timeline =
                         match page_of_graph_page page with
                         | Some journal when Graph.Uuid.equal value.block.parent page.uuid
                           ->
                           Projection.timeline_target_entry
                             ~tag_titles:(fun _ -> value.tag_titles)
                             ~page:journal ~time_context
                             ~root:Projection.{block=value.block;revision;depth=0}
                             children
                         | _ -> Ok None
                       in
                       (match timeline with
                        | Error message -> failure_output t operation request_id message
                        | Ok entry ->
                          Hashtbl.replace
                            t.graph_pages
                            (Graph.Uuid.to_string page.uuid)
                            page;
                          Hashtbl.replace
                            t.page_revisions
                            (Graph.Uuid.to_string page.uuid)
                            page_revision;
                          Hashtbl.replace t.block_revisions block_id revision;
                          Hashtbl.replace
                            t.scope_revisions
                            (scope_key (Worker_pure_data.V2_children_scope value.block.uuid))
                            scope_revision;
                          Hashtbl.replace t.tag_titles block_id value.tag_titles;
                          Hashtbl.replace t.projected_blocks block_id block;
                          Option.iter
                            (fun journal ->
                               Hashtbl.replace
                                 t.page_tree_interests
                                 journal.Projection.id
                                 { page = journal; limit = Worker_pure_data.maximum_page_size };
                               remember_block_page t journal block_id;
                               Rrbvec.iter
                                 (fun (item : Worker_pure_data.child_member) ->
                                    remember_block_page
                                      t
                                      journal
                                      (Graph.Uuid.to_string item.value.block.uuid))
                                 children)
                            (page_of_graph_page page);
                          Rrbvec.iter
                            (fun (item : Worker_pure_data.child_member) ->
                               Hashtbl.replace
                                 t.block_revisions
                                 (Graph.Uuid.to_string item.value.block.uuid)
                                 item.revision;
                               Hashtbl.replace
                                 t.tag_titles
                                 (Graph.Uuid.to_string item.value.block.uuid)
                                 item.value.tag_titles)
                            children;
                          (match purpose with
                           | Updated _ ->
                             responses
                               [ response
                                   (Block_updated { block; timeline_entry_update = entry })
                               ]
                           | Update_conflict_refresh _ -> responses [response (Update_conflict {block;timeline_entry_update=entry})]
                           | Delete_conflict_refresh _ -> responses [response (Delete_conflict {block;timeline_entry_update=entry})]))))
          )
        | _ -> failure_output t operation request_id "Unexpected target summary response.")
     | Query_result (Worker.Outline_block _, lookup) ->
       (match lookup with
        | Worker_pure_data.V2_present_block { value; _ } ->
          Hashtbl.replace
            t.tag_titles
            (Graph.Uuid.to_string value.block.uuid)
            value.tag_titles
        | Worker_pure_data.V2_missing_block _ -> ());
       (match lookup, operation with
        | _, Favorite_read value when Favorites.accepts_block t.favorites value ->
          let planned = Favorites.receive_block t.favorites ~ports:(favorites_ports t) value lookup in
          let output = favorites_output planned in
          if planned.background then background_demands t output else output
        | ( Worker_pure_data.V2_present_block { value; revision }
          , Detail_block { generation; limit; after; _ } ) ->
          remember_block_revision t value.block.uuid revision;
          let root = Projection.{ block = value.block; revision } in
          (match
             Hashtbl.find_opt t.graph_pages (Graph.Uuid.to_string value.block.page)
           with
           | Some page -> detail_children t ~generation ~page ~root ~limit ~after
           | None ->
             requests
               [ read
                   t
                   (Detail_page { generation; root; limit; after })
                   (Worker.Page {uuid=value.block.page;revision=None})
               ])
        | ( Worker_pure_data.V2_missing_block { uuid; _ }
          , Detail_block { generation; block_id; limit; after } )
          when Graph.Uuid.to_string uuid = block_id ->
          requests [read t (Detail_block {generation;block_id;limit;after})
            (Worker.Page {uuid=uuid;revision=None})]
        | Worker_pure_data.V2_present_block {value;revision},Child_chain_parent{root;round;summary}->
          remember_block_revision t value.block.uuid revision;
          finish_child_parent t ~root ~round ~summary Projection.{block=value.block;revision}
        | ( (Worker_pure_data.V2_present_block _ | Worker_pure_data.V2_missing_block _)
          , Reference_read ({ lookup = Reference.Outline_lookup; _ } as value) ) ->
          Reference.receive_outline t.references ~ports:(reference_ports t)
            ~source_epoch value lookup |> reference_output
        | Worker_pure_data.V2_present_block { value; revision }, Find_block_result ->
          remember_block_revision t value.block.uuid revision;
          (match page_by_uuid t value.block.page, projection_time_context t with
           | Some page, Ok time_context ->
             (match
                Projection.block ~page ~revision ~child_count:0 ~time_context value.block
              with
              | Ok block ->
                let block =
                  Journal_model.with_tag_titles block ~tag_titles:value.tag_titles
                in
                responses [ response (Block_found (Some block)) ]
              | Error message -> reject message)
           | None, _ -> responses [ response (Block_found None) ]
           | _, Error message -> reject message)
        | Worker_pure_data.V2_missing_block _, Find_block_result ->
          responses [ response (Block_found None) ]
        |Worker_pure_data.V2_present_block{value;revision},(Changed_block{block_id;_}|Changed_detail_block{block_id;_})->
          resolve_changed_point t ~source_epoch ~block_id ~value ~revision
        | Worker_pure_data.V2_missing_block { uuid; revision }, ((Changed_block { block_id; _ }
          | Changed_detail_block { block_id; _ }) as operation) ->
          remember_block_revision t uuid revision;
          t.block_pages
          <- List.filter
               (fun (candidate, _) -> not (String.equal candidate block_id))
               t.block_pages;
          Hashtbl.remove t.projected_blocks block_id;
          Hashtbl.remove t.detail_pages block_id;
          Hashtbl.remove t.children_interests block_id;
          Hashtbl.remove t.detail_children block_id;
          let payload=match operation with
            | Changed_detail_block {observed=true;_}->Block_observed_missing{block_id}
            | _->Block_removed{block_id} in
          responses [response payload]
        | _ -> failure_output t operation request_id "Unexpected block response.")
     | Query_result (Worker.Child_members _, children) ->
       let revision_scope=children.Worker.revision_scope and scope_revision=children.scope_revision
       and items=children.items in
       remember_scope_revision t revision_scope scope_revision;
       List.iter
         (fun (item : Worker_pure_data.child_member) ->
            remember_block_revision t item.value.block.uuid item.revision;
            Hashtbl.replace
              t.tag_titles
              (Graph.Uuid.to_string item.value.block.uuid)
              item.value.tag_titles)
         items;
       (match operation with
        | Detail_children { generation; page; root; limit; _ } ->
          let children = children_result items (Option.map (fun after -> ({Projection.after;maximum_items=limit}:Projection.child_cursor)) children.next) in
          remember_detail_members t ~page ~root children;
          Option.iter
            (fun journal_page ->
               remember_block_page t journal_page (Graph.Uuid.to_string root.block.uuid);
               remember_blocks t journal_page children.items)
            (page_of_graph_page page);
          (match projection_time_context t with
           | Error message ->
             responses
               [ response
                   (Detail_failed
                      { request_generation = generation
                      ; block_id = Graph.Uuid.to_string root.block.uuid
                      ; missing = false
                      ; stale_cursor = false
                      ; failure = Projection_failure message
                      })
               ]
           | Ok time_context ->
             (match detail_projection t ~page ~time_context ~root children with
              | Ok detail ->
                Hashtbl.replace
                  t.projected_blocks
                  (Journal_model.id detail.root)
                  detail.root;
                responses
                  [ response (Detail_loaded { request_generation = generation; detail }) ]
              | Error message ->
                responses
                  [ response
                      (Detail_failed
                         { request_generation = generation
                         ; block_id = Graph.Uuid.to_string root.block.uuid
                         ; missing = false
                         ; stale_cursor = false
                         ; failure = Projection_failure message
                         })
                  ]))
        | Favorite_read value when Favorites.accepts_memberships value ->
          let planned = Favorites.receive_memberships t.favorites ~ports:(favorites_ports t)
              value items children.next in
          let output = favorites_output planned in
          if planned.background then background_demands t output else output
        | Changed_children { page; root; limit } ->
          let children = children_result items (Option.map (fun after -> ({Projection.after;maximum_items=limit}:Projection.child_cursor)) children.next) in
          let interest =
            Hashtbl.find_opt t.children_interests (Graph.Uuid.to_string root.block.uuid)
          in
          let page, root =
            match interest with
            | Some latest -> latest.page, latest.root
            | None -> page, root
          in
          remember_detail_members t ~page ~root children;
          Option.iter
            (fun journal_page ->
               remember_block_page t journal_page (Graph.Uuid.to_string root.block.uuid);
               remember_blocks t journal_page children.items)
            (page_of_graph_page page);
          (match projection_time_context t with
           | Error message -> reject message
           | Ok time_context ->
             (match detail_projection t ~page ~time_context ~root children with
              | Ok detail -> responses [ response (Children_reconciled detail) ]
              | Error message -> reject message))
        | _ -> failure_output t operation request_id "Unexpected children response.")
     | Query_result (Worker.Changes _, batch) ->
       let generation=batch.Worker.generation and through=batch.through
       and windows=batch.windows and next=batch.next in
       (match operation with
        | Pull_changes { request_generation; _ } ->
          report_timeline "runtime-change-window"
            [ "phase", `String "received"; "request", `String (Graph.Uuid.to_string request_id)
            ; "requestGeneration", `String (Int64.to_string request_generation)
            ; "generation", timeline_version generation; "through", timeline_version through
            ; "windowCount", `Int (List.length windows)
            ; "windows", `List (List.take 16 windows |> List.map (fun (w : Worker_pure_data.change_window) ->
                `Assoc ["id", timeline_version w.id; "predecessor", timeline_version w.predecessor;
                  "successor", timeline_version w.successor; "blockCount", `Int (List.length w.block_uuids);
                  "pageCount", `Int (List.length w.page_uuids); "interestCount", `Int (List.length w.structure_interests)]))
            ; "truncated", `Bool (List.length windows > 16)
            ];
          t.change_generation <- Some generation;
          t.latest_change_batch<-Some batch;
          let acknowledgement =
            make_request t (Acknowledge_changes {batch=Some batch;continuation=Option.map(fun _->request_generation)next}) (Query(Acknowledge{batch}))
          in
          let hydration = hydration_for_changes t ~request_generation windows in
          let catalog_requests =
            if not t.task_catalog_started
            then []
            else (
              let ids =
                List.concat_map
                  (fun (w : Worker_pure_data.change_window) -> w.block_uuids @ w.page_uuids)
                  windows
                |> List.sort_uniq Graph.Uuid.compare
              in
              if
                Option.fold
                  ~none:false
                  ~some:(fun property -> List.exists (Graph.Uuid.equal property) ids)
                  t.task_property
              then [ request_task_catalog t ]
              else (
                let rec batches = function
                  | [] -> []
                  | ids ->
                    let batch = List.take Worker_pure_data.maximum_page_size ids in
                    read
                      t
                      (Task_definitions batch)
                      ~maximum_items:(max 1 (List.length batch)) (Worker.Task_status_definitions batch)
                    :: batches (List.drop (List.length batch) ids)
                in
                batches ids))
          in
          { requests = (acknowledgement :: hydration.requests) @ catalog_requests
          ; responses = response (Projection_changes windows) :: hydration.responses
          }
        | _ -> failure_output t operation request_id "Unexpected changes response.")
     | Changes_acknowledged ack ->
       let generation=Worker.change_ack_generation ack and through=Worker.change_ack_through ack in
       (match operation with
        | Acknowledge_changes {continuation;_} ->
          t.change_generation<-Some generation;t.change_cursor<-Some through;
          (match continuation with None->empty|Some request_generation ->
            requests[read t (Pull_changes{request_generation;generation})
              ~maximum_items:Worker_pure_data.maximum_page_size (Worker.Changes{generation;after=Some through})])
        | _ ->
          failure_output t operation request_id "Unexpected acknowledgement response.")
     | Query_result _ -> failure_output t operation request_id "The query has no graph business owner."))
;;

let receive_delivery_body t ~origin ~request_id result =
  let key = Graph.Uuid.to_string request_id in
  let pending = Hashtbl.find_opt t.pending key in
  let owned = match pending with
    | Some { delivery = Dispatched; _ } -> true
    | None | Some _ -> false in
  if not owned then (
    report_timeline "runtime-response"
      ["request", `String (Graph.Uuid.to_string request_id); "reason", `String "discard-not-owned"];
    empty) else match pending with
  |Some({operation=Target_summary _;durable=Some durable;_}as pending)
    when newer_target_point t pending->resample_confirmation t ~finished:request_id durable
  |_->(
  let background = Hashtbl.mem t.hydration_active key in
  Hashtbl.remove t.hydration_active key;
  let root_current = match pending with
    | Some {operation=Feed_read value;_}->Feed.is_current t.feed value
    | Some {operation;source_epoch;_}->changed_point_current t operation source_epoch
    | None->true in
  let output =
    scope_output
      t
      (Option.bind pending (fun pending -> pending.failure_owner))
      (receive_result t ~origin ~request_id result)
  in
  let references =
    match pending, result with
    | _ when not root_current -> empty
    | None, _ | Some { operation = Reference_read _; _ }, _ -> empty
    | Some pending, _ when not (favorite_request_current t pending) -> empty
    | Some { operation = Target_summary summary; _ }, _
      when not (Confirmation.current t.confirmations summary) ->
      empty
    | Some { operation; source_epoch; _ }, result ->
      let block (value : Worker_pure_data.block_record) = Reference.Block value.block in
      let sources =
        match result with
        | Query_result (Worker.Outline_block _, Worker_pure_data.V2_present_block { value; _ }) -> Rrbvec.singleton (block value)
        | Query_result (Worker.Outline_block _, Worker_pure_data.V2_missing_block { uuid; _ }) ->
          Rrbvec.singleton (Reference.Missing_outline uuid)
        | Query_result (Worker.Block_summary _,
            { lookup = Worker_pure_data.V2_present_block { value; _ }; items; next = None; _ })
          when List.exists
                 (fun response -> match response.payload with
                    | Block_captured _ | Block_updated _ | Update_conflict _ | Delete_conflict _ -> true | _ -> false)
                 output.responses ->
          let fragment = match operation with
            | Target_summary summary -> Confirmation.reference_fragment summary ~target:value ~final_children:items
            | _ -> Rrbvec.push_front
                (Rrbvec.of_list items |> Rrbvec.map (fun (item:Worker_pure_data.child_member)->item.value)) value in
          Rrbvec.map block fragment
        | Query_result (Worker.Page _, Worker_pure_data.V2_present_page { page; _ }) ->
          let detail_owner = match operation with
            | Detail_block { block_id; _ } -> block_id = Graph.Uuid.to_string page.uuid
            | Changed_detail_page _ ->
              Hashtbl.mem t.detail_pages (Graph.Uuid.to_string page.uuid)
            | _ -> false in
          Rrbvec.singleton (Reference.Page { page; detail_owner })
        | Query_result (Worker.Page _, Worker_pure_data.V2_missing_page { uuid; _ }) ->
          Rrbvec.singleton (Reference.Missing_page uuid)
        | Query_result (Worker.Timeline_read {query=Worker.Timeline.Roots _;_}, Ok packet) ->
          Rrbvec.map (fun (item:Worker_pure_data.tree_member) -> block item.value) packet.items
        | Query_result (Worker.Timeline_read {query=Worker.Timeline.Preview_children _;_}, Ok packet) ->
          Rrbvec.map (fun (item:Worker_pure_data.child_member) -> block item.value) packet.items
        | Query_result (Worker.Child_members _, { items; _ }) ->
          Rrbvec.of_list items |> Rrbvec.map (fun (item : Worker_pure_data.child_member) -> block item.value)
        | Query_result (Worker.Tree _, { items; _ }) ->
          Rrbvec.of_list items |> Rrbvec.map (fun (item : Worker_pure_data.tree_member) -> block item.value)
        | _ -> Rrbvec.empty
      in
      let changes =
        List.fold_left
          (fun changes response -> match response.payload with
            | Block_removed { block_id } | Block_observed_missing { block_id } | Subtree_deleted { block_id; _ } ->
              Rrbvec.push_back changes Reference.{ id = block_id; text = None; page_kind = false }
            | Favorites_loaded (_, result) ->
              Rrbvec.fold_left
                (fun changes item ->
                  let favorite = Projection.favorite item in
                  let id, page_kind = match favorite.target with
                    | Page id -> id, true | Block id -> id, false in
                  Rrbvec.push_back changes Reference.{ id; text = Some favorite.title; page_kind })
                changes (Rrbvec.of_list result.items)
            | _ -> changes)
          Rrbvec.empty output.responses
      in
      (* Property references are demanded by Detail only. Timeline continues
         reading its bounded tree fragment without property hydration. All
         child titles enter the cache before discovery, avoiding duplicate reads. *)
      let property_blocks =
        match operation, result with
        | ( (Detail_children { root; _ } | Changed_children { root; _ })
          , Query_result (Worker.Child_members _, { items; _ }) ) ->
          Seq.cons
            root.block
            (List.to_seq items
             |> Seq.map (fun (item : Worker_pure_data.child_member) -> item.value.block))
        | ( (Changed_detail_block { block_id; _ } | Changed_block { block_id; _ })
          , Query_result (Worker.Outline_block _, Worker_pure_data.V2_present_block { value; _ }) )
          when Hashtbl.mem t.detail_pages block_id -> Seq.return value.block
        | Changed_detail_page _, Query_result (Worker.Page _, Worker_pure_data.V2_present_page {page;revision})
            when (not page.recycled)
            && Hashtbl.mem t.detail_pages (Graph.Uuid.to_string page.uuid) ->
          Seq.return (page_root_member page revision).block
        | _ -> Seq.empty
      in
      Reference.observe_fragment t.references ~ports:(reference_ports t)
        ~source_epoch ~sources ~changes ~property_blocks |> reference_output
  in
  let output = { output with responses = output.responses @ references.responses } in
  let output = match Option.bind pending (fun pending -> pending.durable) with
    | None -> output
    | Some durable ->
      List.iter (fun (request:Graph.Uuid.t) ->
        let key=Graph.Uuid.to_string request in
        Option.iter (fun next ->
          let source_epoch=match pending,next.operation with
            |Some{operation=Target_summary _;source_epoch;_},Target_summary summary
              when (match Confirmation.worker_query summary with Worker.Block_summary{after=Some _;_}->true|_->false)->source_epoch
            |_->next.source_epoch in
          Hashtbl.replace t.pending key {next with durable=Some durable;source_epoch})
          (Hashtbl.find_opt t.pending key)) output.requests;
      let settled=List.exists(fun response->match response.payload with
        | Block_updated _ | Block_removed _ | Update_conflict _ | Delete_conflict _ | Subtree_deleted _ -> true
        | Mutation_failed _ when not durable.confirm_readback ->true | _ -> false)output.responses in
      let responses=List.map(fun response->match response.payload with
        | Mutation_failed{mutation_id;block_id;failure;_} when durable.confirm_readback ->
          {payload=Mutation_waiting{mutation_id;block_id;message=(match failure with
            | Projection_failure message->message|Worker_failure value->Error.message value.error)}}
        | Delete_conflict{block;timeline_entry_update} when settled && durable.confirm_readback ->
          {payload=Mutation_settled(durable.intent,durable.presentation,Delete_reappeared{block;timeline_entry_update})}
        | (Block_updated _ | Block_removed _ | Update_conflict _ | Mutation_failed _ | Delete_conflict _ | Subtree_deleted _) as payload when settled ->
          {payload=Mutation_settled(durable.intent,durable.presentation,payload)}
        | _->response)output.responses in
      if Graph.Uuid.equal request_id durable.root_request then
        Option.iter(fun pending->Hashtbl.replace t.pending key pending)pending;
      {output with responses} in
  if background then ignore (background_demands t output);
  dispatch_output t { output with requests = output.requests @ references.requests })
;;

let application_for_request t ~request_id =
  match Hashtbl.find_opt t.pending(Graph.Uuid.to_string request_id) with
  | Some {delivery=Dispatched;change_application;_}->change_application
  | _->None
;;
let set_change_application t ~request_id token =
  match Hashtbl.find_opt t.pending(Graph.Uuid.to_string request_id) with
  | Some pending when pending.delivery=Dispatched ->
    pending.change_application<-Some token;t.latest_application<-Some token;true
  | _ -> false
;;
let rec response_application_error response =
  let failure=function Worker_failure failure->Worker.Db_error failure.error
    | Projection_failure message->Worker.Service_failed message in
  match response.payload with
  | Mutation_settled(_,_,payload)->response_application_error {payload}
  | Mutation_waiting{message;_}->Some(Worker.Service_failed message)
  | Rejected source | Feed_failed {failure=source;_} | Day_blocks_failed {failure=source;_}
  | Child_failed {failure=source;_} | Mutation_failed {failure=source;_} -> Some(failure source)
  | Detail_failed {missing=false;failure=source;_}->Some(failure source)
  | Open_failed value->Some(Worker.Db_error value.error)
  | Task_statuses_changed {error=Some message;_}|Favorites_failed(_,_,message)->Some(Worker.Service_failed message)
  | Projection_unavailable _->Some(Worker.Service_failed "The change consumer projection is unavailable")
  | _->None
;;
let retry_failed_change_application t ~view ~request_generation =
  match t.latest_change_batch with
  | Some batch
    when Coordination.owns_change_batch view batch
         && Option.is_some (Coordination.change_application_error view batch)
         && not(Hashtbl.to_seq_values t.pending |> Seq.exists(fun pending->match pending.operation with
           |Pull_changes pending->pending.generation=batch.generation|_->false)) ->
    dispatch_output
      t
      (requests
         [ read
             t
             (Pull_changes { request_generation; generation = batch.generation })
             ~maximum_items:Worker_pure_data.maximum_page_size
             (Worker.Changes {generation=batch.generation;after=batch.from_exclusive})
         ])
  | _ -> empty
;;

(* This table is a business request-to-cause relation, not transport ownership.
   The pure coordinator owns membership, failures, retirement and ACK eligibility. *)
let register_external_read t ~request_id =
  match t.application_context with
  | None -> ()
  | Some (token, _, children) ->
    if Hashtbl.find_opt t.external_reads request_id <> Some token
    then (
      Hashtbl.replace t.external_reads request_id token;
      children := Rrbvec.push_back !children request_id)
;;

let retire_external_read t ~request_id =
  match Hashtbl.find_opt t.external_reads request_id with
  | None -> ()
  | Some token ->
    Hashtbl.remove t.external_reads request_id;
    (* A synchronously pruned queued read must not be introduced later by the
       enclosing expansion. Already registered consumers are explicitly retired. *)
    (match t.application_context with
     | Some (active, _, children) when active = token ->
       children
       := Rrbvec.fold_left
            (fun kept id ->
               if Graph.Uuid.equal id request_id then kept else Rrbvec.push_back kept id)
            Rrbvec.empty
            !children
     | _ -> ());
    t.on_change (Coordination.Change_consumer_retired (token, request_id))
;;

let report_projection_failure t error =
  match t.application_context with
  | None -> ()
  | Some (token, parent, _) ->
    t.on_change (Coordination.Change_consumer_applied (token, parent, Error error))
;;

let with_read_projection t ~request_id ~f =
  match Hashtbl.find_opt t.pending (Graph.Uuid.to_string request_id) with
  | Some ({ change_application = Some token; delivery = Dispatched; _ } as pending) ->
    let previous = t.application_context
    and children = ref pending.external_children in
    t.application_context <- Some (token, request_id, children);
    Fun.protect
      ~finally:(fun () ->
        pending.external_children <- !children;
        t.application_context <- previous)
      f
  | _ -> f ()
;;

let with_external_read t ~request_id ~f =
  match Hashtbl.find_opt t.external_reads request_id with
  | None -> f (), None
  | Some token ->
    Hashtbl.remove t.external_reads request_id;
    let previous = t.application_context
    and children = ref Rrbvec.empty in
    t.application_context <- Some (token, request_id, children);
    let result =
      Fun.protect
        ~finally:(fun () -> t.application_context <- previous)
        (fun () ->
           try Ok (f ()) with
           | error -> Error error)
    in
    t.on_change (Coordination.Change_consumer_expanded (token, request_id, !children));
    (match result with
     | Ok value -> value, Some token
     | Error error ->
       t.on_change
         (Coordination.Change_consumer_applied
            ( token
            , request_id
            , Error (Worker.Service_failed "The external projection consumer failed") ));
       raise error)
;;

let notify_projection_changes t (output : output) =
  List.iter
    (fun response ->
       match response.payload with
       | Projection_changes windows -> t.on_projection_changes windows
       | _ -> ())
    output.responses
;;

let receive_delivery t ~origin ~request_id result =
  let token=application_for_request t ~request_id:request_id in
  match token with
  | None->let output=receive_delivery_body t ~origin ~request_id result in
    notify_projection_changes t output;output
  | Some token ->
    let external_children=match Hashtbl.find_opt t.pending(Graph.Uuid.to_string request_id) with
      | Some pending->pending.external_children|None->Rrbvec.empty in
    let previous=t.application_context and children=ref external_children in
    t.application_context<-Some(token,request_id,children);
    let output=Fun.protect ~finally:(fun()->t.application_context<-previous)
      (fun()->let output=receive_delivery_body t ~origin ~request_id result in
        notify_projection_changes t output;output) in
    t.on_change(Coordination.Change_consumer_expanded(token,request_id,!children));
    let error=match result with
      | Read_failed{code;message}->Some(Worker.Service_failed(Error.code_string code ^ ": " ^ message))
      | Read_error error->Some(Worker.Db_error error)
      | Changes_resync reason->Some(Worker.Resync_required reason)
      | _->List.find_map response_application_error output.responses in
    Option.iter(fun error->t.on_change(Coordination.Change_consumer_applied(token,request_id,Error error))) error;
    output
;;

let receive_worker_read ?resync_generation ?origin t ~request_id result =
  match result with
  | Changes_retired ->
    Hashtbl.remove t.pending(Graph.Uuid.to_string request_id);
    Hashtbl.remove t.hydration_active(Graph.Uuid.to_string request_id);empty
  | Changes_resync reason ->
    let key=Graph.Uuid.to_string request_id in
    (match Hashtbl.find_opt t.pending key,resync_generation with
     | Some {delivery=Dispatched;operation=(Pull_changes _ | Acknowledge_changes _);_},Some request_generation ->
       Hashtbl.remove t.pending key;Hashtbl.remove t.hydration_active key;
       Option.iter(fun token->t.on_change(Coordination.Change_application_retired token)) t.latest_application;
       t.latest_application<-None;t.latest_change_batch<-None;
       let generation=Option.value t.change_generation ~default:"" in
       dispatch_output t (rehydrate_current_interests t ~request_generation ~generation)
     | _ -> responses[response(Rejected(Projection_failure reason))])
  | _ -> receive_delivery t ~origin ~request_id result
;;

let worker_intent t request session =
  match Hashtbl.find_opt t.pending(Graph.Uuid.to_string request) with
  | Some {durable=Some durable;delivery=Dispatched;_}->
    Worker.validate_request session (match durable.intent with
      | Worker.Append_intent intent->Worker.Append intent|Mutation_intent intent->Worker.Mutate intent)
    |> Result.map(fun()->durable.intent)
  | Some {operation=Child_write{root;index;_};delivery=Dispatched;_}->
    (match child_root t root with Some(_,chain,_)->Child.stage_intent session(Child.stage chain index)
     |None->Error(Worker.Invalid_input "The child stage is no longer owned."))
  | Some {planned=Mutation{mutation_id;command};delivery=Dispatched;_}->
    Worker.mutation_intent session ~mutation_id command |> Result.map(fun intent->Worker.Mutation_intent intent)
  | Some {operation=Capture_append command;planned=Append root;delivery=Dispatched;_}->
    (match Child.start_capture ~command ~resolved_status:root.task_status ~root with
     |Error message->Error(Worker.Invalid_input message)
     |Ok(chain,_)->Child.stage_intent session(Child.stage chain 0))
  | _->Error(Worker.Invalid_input "The mutation is no longer owned by its business request.")
;;

let bind_mutation t request ~presentation ~intent =
  let key=Graph.Uuid.to_string request in
  match Hashtbl.find_opt t.pending key with
  | Some ({operation=Capture_append command;delivery=Dispatched;_} as pending) ->
    (match pending.planned with
     | Append root->
       let resolved_status=root.task_status in
       (match Child.start_capture ~command ~resolved_status ~root with
        | Error message->Error (Worker.Invalid_input message)
        | Ok(chain,_)->match Child.bind chain ~index:0 ~round:1L ~intent ~presentation with
          | Error error->Error error
          | Ok chain->Hashtbl.replace t.pending key
            {pending with operation=Capture_chain{chain;projection=None;command};planned=Stage};Ok ())
     | _->Error (Worker.Invalid_input "The capture request does not contain an append plan."))
  | Some ({operation=Child_insert(command,page);delivery=Dispatched;_} as pending) ->
    (match task_status_uuid t command.task_state with
     | Error message->Error (Worker.Invalid_input message)
     | Ok resolved_status->
       (match pending.planned with Mutation{command=insert;_}->
       (match Child.start ~command ~page ~resolved_status ~insert with
        | Error message->Error (Worker.Invalid_input message)
        | Ok(chain,_)->
          (match Child.bind chain ~index:0 ~round:1L ~intent ~presentation with
           | Error error->Error error
           | Ok chain->Hashtbl.replace t.pending key {pending with operation=Child_chain{chain;projection=None};planned=Stage};Ok ()))
       |_->Error (Worker.Invalid_input "The child request does not contain an insertion plan.")))
  | Some {operation=Child_write{root;index;round};delivery=Dispatched;_} ->
    (match child_root t root with
     | None->Error (Worker.Invalid_input "The child chain no longer owns this write request.")
     | Some(_,chain,projection)->
       (match Child.bind chain ~index ~round ~intent ~presentation with
        | Error error->Error error|Ok chain->update_child_root t root chain projection;Ok ()))
  | Some pending when pending.delivery=Dispatched ->
    (match pending.operation with
     |Mutation_refresh{page;_}->Hashtbl.replace t.page_tree_interests page.Projection.id
        {page;limit=Worker_pure_data.maximum_page_size}
     |_->());
    let durable=match pending.durable with
      | Some durable -> {durable with intent;presentation;confirm_readback=true}
      | None -> {intent;presentation;confirm_readback=true;root_request=request;
          submission_recovered=false;acknowledgement_recovered=None;acknowledgement_in_flight=false} in
    let source_epoch=t.next_request in
    t.next_request<-Int64.succ t.next_request;
    Hashtbl.replace t.pending key {pending with durable=Some durable;source_epoch;planned=Stage};Ok ()
  | _->Error (Worker.Invalid_input "The mutation is no longer owned by a dispatched business request.")
;;

let mutation_presentation t (request:Graph.Uuid.t) =
  Option.bind(Hashtbl.find_opt t.pending(Graph.Uuid.to_string request))
    (fun pending->Option.map(fun durable->durable.presentation)pending.durable)
;;

let pending_mutation t ~mutation_id =
  Hashtbl.to_seq_values t.pending |> Seq.find_map(fun pending->
    match pending.durable with
    | Some durable when Graph.Uuid.to_string(Worker.durable_intent_id durable.intent)=mutation_id
        && Graph.Uuid.equal pending.original durable.root_request -> Some durable.root_request
    | _->None)
;;

let acknowledge_mutation t intent =
  match pending_mutation t ~mutation_id:(Graph.Uuid.to_string(Worker.durable_intent_id intent)) with
  | Some request->Hashtbl.remove t.pending(Graph.Uuid.to_string request)
  | None->()
;;

let update_mutation_acknowledgement t intent f =
  match pending_mutation t ~mutation_id:(Graph.Uuid.to_string(Worker.durable_intent_id intent)) with
  |None->false
  |Some request->let key=Graph.Uuid.to_string request in
    match Hashtbl.find_opt t.pending key with
    |Some({durable=Some durable;_}as pending)->
      (match f durable with None->false|Some durable->
        Hashtbl.replace t.pending key {pending with durable=Some durable};true)
    |_->false
;;
let begin_mutation_acknowledgement t intent =
  update_mutation_acknowledgement t intent(fun durable->
    if durable.acknowledgement_in_flight then None else Some{durable with acknowledgement_in_flight=true})
;;
let finish_mutation_acknowledgement t intent =
  ignore(update_mutation_acknowledgement t intent(fun durable->Some{durable with acknowledgement_in_flight=false}))
;;
let claim_mutation_ack_recovery t intent ~presentation =
  match pending_mutation t ~mutation_id:(Graph.Uuid.to_string(Worker.durable_intent_id intent)) with
  | None->false
  | Some request->let key=Graph.Uuid.to_string request in
    (match Hashtbl.find_opt t.pending key with
     | Some({durable=Some durable;_}as pending) when not durable.acknowledgement_in_flight && durable.acknowledgement_recovered<>Some presentation ->
       Hashtbl.replace t.pending key {pending with durable=Some{durable with acknowledgement_recovered=Some presentation}};true
     | _->false)
;;

let mutation_waiting_unissued t (request:Graph.Uuid.t) message =
  match Hashtbl.find_opt t.pending(Graph.Uuid.to_string request) with
  | Some {operation=(Child_chain _|Capture_chain _);_} ->
    child_step t request(fun chain->Child.interrupted chain ~index:0 ~round:1L message)
  | Some {operation=(Child_write{root;index;round}|Child_ack{root;index;round;_});_} ->
    Hashtbl.remove t.pending(Graph.Uuid.to_string request);
    child_step t root(fun chain->Child.interrupted chain ~index ~round message)
  | Some ({durable=Some durable;failure_owner=Some(Mutation_owner _);_}as pending)
    when not durable.submission_recovered ->
    Hashtbl.replace t.pending (Graph.Uuid.to_string request)
      {pending with durable=Some{durable with submission_recovered=true};delivery=Planned};
    requests[durable.root_request]
  | Some {failure_owner=Some(Mutation_owner{mutation_id;block_id;_});_}->
    responses[response(Mutation_waiting{mutation_id;block_id;message})]
  | _->empty
;;

let mutation_waiting t request message =
  dispatch_output t(mutation_waiting_unissued t request message)
;;

let receive_mutation t (request:Graph.Uuid.t) progress =
  let key=Graph.Uuid.to_string request in
  match Hashtbl.find_opt t.pending key with
  | Some {operation=(Child_chain _|Capture_chain _);_} ->
    dispatch_output t (child_step t request (fun chain->Child.receive chain ~index:0 ~round:1L progress))
  | Some {operation=(Child_write{root;index;round}|Child_ack{root;index;round;_});_} ->
    Hashtbl.remove t.pending key;
    dispatch_output t (child_step t root (fun chain->Child.receive chain ~index ~round progress))
  | Some ({durable=Some durable;operation=(Mutation_refresh _ | Delete_mutation _);_} as pending) ->
    if newer_target_point t pending && (match progress with Worker.Confirmed _->true|_->false)
    then resample_confirmation t ~finished:request durable
    else (match progress with
     | Worker.Confirmed confirmation when Worker.confirmation_presentation confirmation=durable.presentation ->
       (match Worker.confirmation_primary confirmation with
        | Worker.Confirmed_block summary ->
          let target=match pending.operation with
            | Mutation_refresh{page;refresh}->Some(request_target_summary t page refresh)
            | Delete_mutation command->Some(request_delete_summary t command.block_id)
            | _->None in
          (match target with
           | None->mutation_waiting t request "The canonical mutation owner is unavailable."
           | Some planned->
          let planned=scope_output t pending.failure_owner planned in
          (match planned.requests with
           | [first]->
             let child=Graph.Uuid.to_string first in
             Option.iter(fun next->Hashtbl.replace t.pending child
               {next with durable=Some durable;source_epoch=pending.source_epoch})
               (Hashtbl.find_opt t.pending child);
             let planned=dispatch_output t planned in
             let query=match Hashtbl.find_opt t.pending child with
               | Some {operation=Target_summary read;_}->Confirmation.worker_query read
               | _->assert false in
             let output=receive_worker_read t ~request_id:first(Query_result(query,summary)) in
             {output with requests=List.filter(fun (value:Graph.Uuid.t)->value<>first)planned.requests @ output.requests}
           | _->mutation_waiting t request "The canonical mutation read could not be planned."))
        | Confirmed_absence{uuid;_}->
          let block_id=Graph.Uuid.to_string uuid in
          let payload=match pending.operation with
            | Delete_mutation _->Subtree_deleted{block_id;deleted_count=None;parent=None;timeline_entry_update=None}
            | _->Block_removed{block_id} in
          responses[response(Mutation_settled(durable.intent,durable.presentation,payload))]
        | Confirmed_page _->mutation_waiting t request "The canonical mutation target is not a block.")
     | Rejected error ->
       let durable={durable with confirm_readback=false} in
       (* The known rejection is terminal evidence; only this branch may report
          that the choice did not apply. *)
       Hashtbl.replace t.pending key {pending with durable=None};
       let failure=match error with
         | Worker.Db_error error->Read_error error
         | Service_failed message | Invalid_input message | Protocol_mismatch message
         | Unsupported_operation message | Stale_read message | Resync_required message->
           Read_failed{code=Error.Invalid_request;message}
         | Revoked_session->Read_failed{code=Error.Closed_session;message="The mutation session was revoked."}
         | Host_change_in_progress->Read_failed{code=Error.Closed_session;message="The graph is closing; the mutation outcome is retained."}
         | Response_budget_exceeded->Read_failed{code=Error.Response_too_large;message="The mutation result exceeded its response budget."} in
       let output=receive_worker_read t ~request_id:request failure in
       Hashtbl.replace t.pending key {pending with durable=Some durable};
       List.iter(fun (request:Graph.Uuid.t)->let key=Graph.Uuid.to_string request in
         Option.iter(fun pending->Hashtbl.replace t.pending key {pending with durable=Some durable})
           (Hashtbl.find_opt t.pending key))output.requests;
       {output with responses=List.map(fun value->{payload=Mutation_settled(durable.intent,durable.presentation,value.payload)})output.responses}
     | Confirmed _ | Outcome_unknown | Committed_pending_presentation _ ->
       mutation_waiting t request "The change is awaiting confirmation.")
  | _->empty
;;

let worker_child_ack t (request:Graph.Uuid.t) =
  match Hashtbl.find_opt t.pending(Graph.Uuid.to_string request) with
  | Some{operation=Child_ack{intent;presentation;_};delivery=Dispatched;_}->Some(intent,presentation)
  | _->None
;;
let rebind_child_ack t (request:Graph.Uuid.t) ~presentation =
  match Hashtbl.find_opt t.pending(Graph.Uuid.to_string request) with
  | Some{operation=Child_ack{root;index;round;intent;_};delivery=Dispatched;_}->
    (match child_root t root with
     | None -> Error (Worker.Invalid_input "The child chain no longer owns this acknowledgement.")
     | Some(_,chain,projection)->
      match Child.rebind_ack chain ~index ~round ~intent ~presentation with
      | Error error -> Error error
      | Ok chain -> update_child_root t root chain projection; Ok ())
  | _ -> Error (Worker.Invalid_input "The child acknowledgement is no longer dispatched.")
;;
let resume_insertion_recovery t ~root recovery =
  dispatch_output t(child_step t root(fun chain->Child.resume_recovery chain recovery))
;;

let receive_child_ack t (request:Graph.Uuid.t) result =
  let key=Graph.Uuid.to_string request in
  match Hashtbl.find_opt t.pending key with
  | Some{operation=Child_ack{root;index;round;_};_}->
    Hashtbl.remove t.pending key;
    dispatch_output t (child_step t root(fun chain->Child.acknowledged chain ~index ~round result))
  | _->empty
;;
let child_projection_applied t ~root ~round ~presentation =
  dispatch_output t (child_step t root(fun chain->Child.applied chain ~round presentation))
;;

let fail_request ?error t (request : Graph.Uuid.t) ~message =
  match Hashtbl.find_opt t.pending(Graph.Uuid.to_string request) with
  | Some{operation=Capture_append command;_}->
    Hashtbl.remove t.pending(Graph.Uuid.to_string request);
    responses[response(Capture_not_admitted{command;message})]
  | Some{operation=Child_insert(command,_);_}->
    Hashtbl.remove t.pending(Graph.Uuid.to_string request);
    responses[response(Child_not_admitted{command;message})]
  | Some{operation=(Child_chain _|Capture_chain _|Child_write _|Child_ack _);_}->mutation_waiting t request message
  | _->receive_worker_read t ~request_id:request
      (match error with Some error->Read_error error
       | None->Read_failed{code=Error.Closed_session;message})
;;

let abandon t (request : Graph.Uuid.t) =
  let key = Graph.Uuid.to_string request in
  (match Hashtbl.find_opt t.pending key with
   | Some { operation = Reference_read value; source_epoch; _ } ->
     Reference.abandon t.references ~source_epoch value
   | Some { operation = Task_catalog { epoch; _ }; _ } when epoch = t.task_catalog_epoch
     ->
     t.task_catalog_loading <- false;
     Hashtbl.clear t.task_catalog_deletions
   | Some { operation = Task_definitions ids; source_epoch; _ } ->
     List.iter
       (fun uuid ->
          let id = Graph.Uuid.to_string uuid in
          if Hashtbl.find_opt t.task_lookup_epochs id = Some source_epoch
          then Hashtbl.remove t.task_lookup_epochs id)
       ids
   | _ -> ());
  Hashtbl.remove t.pending key;
  Hashtbl.remove t.hydration_active key
;;

let reconcile_signal t ~request_generation push =
  (match push with
   | Worker_pure_data.Changes_available { generation; through; _ } ->
     report_timeline "runtime-change-window"
       [ "phase", `String "push"; "generation", timeline_version generation
       ; "through", timeline_version through
       ; "requestGeneration", `String (Int64.to_string request_generation)
       ]
   | Worker_pure_data.Resync_required { generation; _ } ->
     report_timeline "runtime-change-window"
       [ "phase", `String "resync"; "generation", timeline_version generation
       ; "requestGeneration", `String (Int64.to_string request_generation)
       ]);
  let output =
    match push with
    | Worker_pure_data.Changes_available { generation; _ } ->
      let after =
        match t.change_generation with
        | Some current when String.equal current generation -> t.change_cursor
        | None | Some _ -> None
      in
      requests
        [ read
            t
            (Pull_changes { request_generation; generation })
            ~maximum_items:Worker_pure_data.maximum_page_size (Worker.Changes{generation;after})
        ]
    | Worker_pure_data.Resync_required { generation; _ } ->
      rehydrate_current_interests t ~request_generation ~generation
  in
  dispatch_output t output
;;


let worker_read t request =
  match Hashtbl.find_opt t.pending(Graph.Uuid.to_string request) with
  | Some {operation=Target_summary summary;durable=Some durable;delivery=Dispatched;_}
    when durable.confirm_readback && (match Confirmation.worker_query summary with Worker.Block_summary{after=None;_}->true|_->false) ->
      Some(Confirm_readback{intent=durable.intent;presentation=durable.presentation;query=Confirmation.worker_query summary})
  | Some {planned=Query read;delivery=Dispatched;_}->Some read
  | _->None
;;

let detail_observation_input t request =
  match Hashtbl.find_opt t.pending(Graph.Uuid.to_string request) with
  | Some{operation=Detail_block{generation;limit;after=None;_};planned=Query(Read{query=Worker.Outline_block _;_});delivery=Dispatched;_}->Some(generation,limit)
  | _->None
;;
let plan_observed_block t ~root =
  read t (Changed_detail_block{block_id=Graph.Uuid.to_string root;observed=true})
    (Worker.Outline_block {uuid=root;revision=None}) |> issue_request t
;;
let plan_observed_detail t ~generation ~limit ~root =
  (* Ordinary initial reads are superseded; Changes consumers retain their own
     causal obligation until an actual dependent projection settles. *)
  Hashtbl.filter_map_inplace(fun _ pending->match pending.operation,pending.change_application with
    | Detail_children{root=old;_},None when old.block.uuid=root->None
    | _->Some pending)t.pending;
  read t (Detail_block{generation;block_id=Graph.Uuid.to_string root;limit;after=None})
    (Worker.Outline_block {uuid=root;revision=None}) |> issue_request t
;;
let owns_read t (request:Graph.Uuid.t) =
  match Hashtbl.find_opt t.pending(Graph.Uuid.to_string request) with
  | Some pending->pending.delivery=Dispatched
  | None->false
;;
