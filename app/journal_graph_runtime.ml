module Graph = Logseq_db_types.Graph_types
module Protocol = Logseq_db_worker.Protocol
module Error = Logseq_db_worker.Error
module Projection = Journal_graph_projection
module Reference = Journal_graph_reference_plan
module Favorites = Journal_graph_favorites_plan
module Feed = Journal_graph_feed_plan
module Confirmation = Journal_graph_mutation_confirmation
module Child = Journal_graph_mutation_confirmation.Pure_child
module Worker = Journal_worker_coordination.Worker_api
module Coordination = Journal_worker_coordination.Worker_pure_coordinator

type worker_read_result =
  | Child_chain_summary of Worker.block_summary
  | Changes_resync of string
  | Changes_retired
  | Changes_read of Worker.change_batch
  | Changes_acknowledged of Worker.change_ack
  | Root_tree_read of {page:Graph.Uuid.t;value:Protocol.v2_tree_member Worker.slice}
  | Child_members_read of Worker.children
  | Target_summary_read of Worker.block_summary
  | Journals_read of Protocol.v2_journal_item Worker.slice
  | Task_catalog_read of Worker.task_status_catalog
  | Ordinary_read of Protocol.v2_outcome
  | Favorites_read of { first_page:bool; value:Journal_graph_request.favorites_result }

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

let report_capture_evidence ~stage ?result ?page_mutation ~request ~target
    (command : Projection.capture) =
  (* Capture IDs originate at the UI boundary. Never echo malformed input. *)
  try
    let capture_mutation =
      match Graph.Uuid.of_string command.mutation_id with
      | Ok uuid -> Graph.Uuid.to_string uuid
      | Error _ -> "invalid"
    in
    let fields =
      [ "stage", `String stage
      ; "request", `String (Graph.Uuid.to_string request)
      ; "target", `String (Graph.Uuid.to_string target)
      ; "captureMutation", `String capture_mutation
      ; "day", `Int (Journal_time.local_day command.creation_time)
      ]
      @ Option.fold ~none:[] ~some:(fun value -> [ "result", `String value ]) result
      @ Option.fold ~none:[]
          ~some:(fun uuid -> [ "pageMutation", `String (Graph.Uuid.to_string uuid) ])
          page_mutation
    in
    output_string stderr ("journal-capture: " ^ Yojson.Safe.to_string (`Assoc fields) ^ "\n");
    flush stderr
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
  | Source_mutation
  | Status_mutation
  | Delete_subtree_mutation

type payload =
  | Child_projection_ready of
      { root : Graph.Uuid.t; round : int64; command : Projection.create_child;
        presentation : Worker.presentation; result : payload; failure : Worker.error option }
  | Child_waiting of {command:Journal_graph_projection.create_child;message:string}
  | Child_projection_settled of
      { command : Projection.create_child; presentation : Worker.presentation option; result : payload; failure : Worker.error option;
        insert_rejected : bool }
  | Mutation_settled of Journal_worker_coordination.Worker_api.mutation_intent * Journal_worker_coordination.Worker_api.presentation * payload
  | Mutation_waiting of { mutation_id:string; block_id:string; message:string }
  | Projection_changes of Protocol.v2_change_window list
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
      * Journal_graph_request.favorites_result
  | Favorites_failed of Journal_graph_request.favorites_request * bool * string
  | Favorites_invalidated
  | Graph_ready
  | Admission_inspected of
      { request : Journal_graph_request.admission_request
      ; observation : Protocol.v2_admission_inspection
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
  | Rejected of failure_source

type response = { payload : payload }

type refresh = Confirmation.purpose =
  | Captured of { block_id : string }
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
  | Child_write of { root : Graph.Uuid.t; index : int; round : int64 }
  | Child_canonical of { root : Graph.Uuid.t; round : int64 }
  | Child_chain_parent of { root : Graph.Uuid.t; round : int64; summary : Worker.block_summary }
  | Child_ack of { root : Graph.Uuid.t; index : int; round : int64;
      intent : Worker.mutation_intent; presentation : Worker.presentation }
  | Child_insert of Projection.create_child * Graph.page
  | Child_read of Projection.create_child * Graph.page
  | Child_status of Projection.create_child * Graph.page
  | Child_parent of Projection.create_child * Graph.page * Projection.block_member
  | Changed_block of { block_id : string }
  | Changed_detail_block of { block_id : string }
  | Changed_point_context of
      { block_id : string
      ; value : Protocol.v2_block_record
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
  | Capture_page of Projection.capture
  | Capture_format of
      { command : Projection.capture
      ; page_uuid : Graph.page_uuid
      ; page_revision : string
      }
  | Capture_create_page of
      { command : Projection.capture
      ; page_uuid : Graph.page_uuid
      }
  | Capture_children of
      { command : Projection.capture
      ; page : Projection.page
      ; conflict_retries : int
      }
  | Capture_insert of
      { command : Projection.capture
      ; page : Projection.page
      ; conflict_retries : int
      }
  | Capture_block of
      { command : Projection.capture
      ; page : Projection.page
      }
  | Capture_status of
      { command : Projection.capture
      ; page : Projection.page
      }
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

type durable_operation =
  { intent : Worker.mutation_intent
  ; presentation : Worker.presentation
  ; confirm_readback : bool
  ; root_request : Protocol.request
  }

type pending_operation =
  { operation : operation
  ; original : Protocol.request
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
  ; on_projection_changes : Protocol.v2_change_window list -> unit
  ; external_reads : (Graph.Uuid.t,Coordination.change_application) Hashtbl.t
  ; mutable application_context : (Coordination.change_application * Graph.Uuid.t * Graph.Uuid.t Rrbvec.t ref) option
  ; mutable latest_application : Coordination.change_application option
  ; mutable latest_change_batch : Worker.change_batch option
  ; validate_session : Worker.session -> (unit, Worker.error) result
  ; pending : (string, pending_operation) Hashtbl.t
  ; hydration_queue : Protocol.request Queue.t
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
  { requests : Protocol.request list
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
  Feed.reset t.feed ~now:(fun () -> t.next_request)
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

let make_request ?source_epoch ?(background = false) t operation command =
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
  let participates=match command with Protocol.V2_ack_changes _->false|_->true in
  Hashtbl.replace
    t.pending
    (Graph.Uuid.to_string request_id)
    { operation; original = Protocol.{api_version;request_id;command}; durable=None; source_epoch; failure_owner = None; background; delivery = Planned;
      external_children=Rrbvec.empty;change_application=(if participates then Option.map(fun(token,_,_)->token)t.application_context else None) };
  if participates then Option.iter(fun(_,_,children)->children:=Rrbvec.push_back !children request_id)t.application_context;
  Protocol.{ api_version; request_id; command }
;;

let read = make_request
let mutate = make_request
let favorites_ports t =
  Favorites.
    { plan_read = (fun value command -> read t (Favorite_read value) command)
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
        | Rejected (Worker_rejection { operation; request_id; error }) ->
          response (Rejected (Worker_failure { operation; request_id; error })))
      value.responses)
  }
;;

(* Only a public output boundary issues a demand. Internal completions never
   reserve a hydration slot or return an already dispatched request. *)
let issue_request t (request : Protocol.request) =
  let key = Graph.Uuid.to_string request.request_id in
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
    (Protocol.V2_list_task_statuses { limit = Protocol.maximum_page_size; cursor = None })
;;

let start t = issue_request t (read t Graph_info Protocol.V2_graph_info)

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
  | Protocol.V2_children_scope parent -> "children:" ^ Graph.Uuid.to_string parent
;;

let preconditions ?(blocks = []) ?(pages = []) ?(scopes = []) () =
  Protocol.{ blocks; pages; scopes }
;;

let block_preconditions t block =
  match Hashtbl.find_opt t.block_revisions (Graph.Uuid.to_string block) with
  | None -> Error "The block revision is not retained."
  | Some revision -> Ok (preconditions ~blocks:[ block, revision ] ())
;;

let page_preconditions t page =
  match Hashtbl.find_opt t.page_revisions (Graph.Uuid.to_string page) with
  | None -> Error "The page revision is not retained."
  | Some revision -> Ok (page, revision)
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

let journal_title ~format day =
  let pattern = Option.value ~default:Journal_title.default_format format in
  match
    Journal_title.format
      ~pattern
      ~year:(day / 10_000)
      ~month:(day / 100 mod 100)
      ~day:(day mod 100)
  with
  | Some title -> title
  | None ->
    Option.get
      (Journal_title.format
         ~pattern:Journal_title.default_format
         ~year:(day / 10_000)
         ~month:(day / 100 mod 100)
         ~day:(day mod 100))
;;

let reject message = responses [ response (Rejected (Projection_failure message)) ]

(* Admission identity follows only direct continuations of this operation.
   Reference reconciliation and queued background hydration are merged later. *)
let scope_output t owner output =
  match owner with
  | None -> output
  | Some owner ->
    List.iter
      (fun (request : Protocol.request) ->
         let key = Graph.Uuid.to_string request.request_id in
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
    ; plan_read = (fun operation command -> read t (Feed_read operation) command)
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
        | Dates items -> Seq.iter (fun (i:Protocol.v2_journal_item)->
            Hashtbl.replace t.graph_pages (Graph.Uuid.to_string i.page.uuid) i.page;
            Hashtbl.replace t.page_revisions (Graph.Uuid.to_string i.page.uuid) i.revision) items
        | Roots items -> Seq.iter (fun (i:Protocol.v2_tree_member)->
            Hashtbl.replace t.block_revisions (Graph.Uuid.to_string i.value.block.uuid) i.revision;
            Hashtbl.replace t.tag_titles (Graph.Uuid.to_string i.value.block.uuid) i.value.tag_titles) items
        | Preview items -> Seq.iter (fun (i:Protocol.v2_child_member)->
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

let feed_output t (value : Feed.output) =
  let rec settle (value : Feed.output) =
    match value.cached with
    | None -> value
    | Some cached ->
      let next = Feed.resume_cached t.feed ~ports:(feed_ports t) cached in
      settle
        { Feed.requests = Rrbvec.append value.requests next.requests
        ; publications = Rrbvec.append value.publications next.publications
        ; cached = next.cached
        }
  in
  let value = settle value in
  { requests = Rrbvec.to_list value.requests
  ; responses =
      Rrbvec.to_list
        (Rrbvec.map
           (function
             | Feed.Loaded { request_generation; feed; complete } ->
               response (Feed_loaded { request_generation; feed; complete })
             | Reconciled { page; value } ->
               response (Page_tree_reconciled { page; value })
             | Failed { scope; stale_cursor; message } ->
               let failure = Projection_failure message in
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
  | Revoked_session -> "The child graph session changed. Retry in the current graph."
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
  | _ -> None
;;
let child_request_root = function
  | Child_write {root;_} | Child_canonical {root;_} | Child_chain_parent {root;_}
  | Child_ack {root;_} -> Some root
  | _ -> None
;;
let update_child_root t root chain projection =
  Option.iter (fun (pending,_,_) -> Hashtbl.replace t.pending (Graph.Uuid.to_string root)
    {pending with operation=Child_chain {chain;projection}}) (child_root t root)
;;
let child_action t root chain projection action =
  update_child_root t root chain projection;
  let command=Child.command chain in
  match action with
  | Child.Write(index,round,wire) -> requests [mutate t (Child_write{root;index;round}) wire]
  | Read_child round -> requests [read t (Child_canonical{root;round})
      (Protocol.V2_get_outline_block_summary {block=Graph.Uuid.of_string command.block_id |> Result.get_ok;
        limit=Protocol.default_page_size;cursor=None})]
  | Read_parent(round,summary) ->
    let parent=Graph.Uuid.of_string command.parent_block_id |> Result.get_ok in
    let page=Child.page chain in
    requests [read t (Child_chain_parent{root;round;summary})
      (if parent=page.uuid then Protocol.V2_get_page{page=parent;revision=None}
       else V2_get_outline_block{block=parent;revision=None})]
  | Present round ->
    let result=match projection with Some result->result
      | None->(child_failure command (Option.fold ~none:"The child could not be applied."
          ~some:child_error_message (Child.failure chain))).payload in
    (match Child.presentation chain with
     | Some presentation -> responses[response(Child_projection_ready
         {root;round;command;presentation;result;failure=Child.failure chain})]
     | None -> responses[child_failure command "The child result lost its confirming presentation."])
  | Acknowledge(index,round,intent,presentation) ->
    (* A business continuation only; the App dispatches its typed ACK before
       considering legacy protocol delivery. This never replays the wire write. *)
    requests[mutate t (Child_ack{root;index;round;intent;presentation})
      (Child.stage_wire(Child.stage chain index))]
  | Complete ->
    let insert_rejected=Child.insert_rejected chain in
    let result=match projection with Some result->result
      | None->(child_failure command (Option.fold ~none:"The child was not inserted."
          ~some:child_error_message(Child.failure chain))).payload in
    if Child.failure chain=None || insert_rejected then
      Hashtbl.filter_map_inplace (fun key pending ->
        if key=Graph.Uuid.to_string root || child_request_root pending.operation=Some root then None
        else Some pending) t.pending;
    let refresh=if Child.canonical chain=None then [] else
      match page_of_graph_page(Child.page chain) with None->[]|Some page->
        Option.to_list(Feed.reconcile_page t.feed ~ports:(feed_ports t) ~page ~limit:Protocol.maximum_page_size) in
    {requests=refresh;responses=[response(Child_projection_settled
      {command;presentation=Child.presentation chain;result;failure=Child.failure chain;insert_rejected})]}
  | Ignore -> empty
  | Wait message -> responses[response(Child_waiting{command;message})]
;;
let child_step t root transition = match child_root t root with
  | None -> empty
  | Some(_,chain,projection) ->
    let next,action=transition chain in child_action t root next projection action
;;

let submit_unowned t (request : Journal_graph_request.t) =
  match request with
  | Load_task_statuses -> requests [ request_task_catalog t ]
  | Load_favorites request ->
    requests [ Favorites.load ~ports:(favorites_ports t) request ]
  | Inspect_admission request ->
    requests [ read t (Admission_info request) Protocol.V2_inspect_admission ]
  | Load_feed { cursor; root_limit; day_limit; request_generation } ->
    Feed.load_feed t.feed ~ports:(feed_ports t) ~cursor ~root_limit ~day_limit ~request_generation |> feed_output t
  | Load_day_blocks { day; after; limit; request_generation } ->
    (match page_by_day t day with
     | None -> day_failure ~day request_generation "The requested journal page is not retained."
     | Some page ->
       Feed.load_day t.feed ~ports:(feed_ports t) ~page ~after ~limit ~request_generation |> feed_output t)
  | Load_detail { block_id; request_generation; limit; after } ->
    let cursor = Option.bind after (fun cursor -> cursor.Projection.protocol_cursor) in
    let parsed = match cursor with
      | Some (Projection.Root_tree_cursor _) -> Error "A Timeline cursor cannot continue Detail children."
      | Some (Projection.Child_cursor {maximum_items;_}) when maximum_items<=0 || maximum_items>Protocol.maximum_page_size ->
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
         [ read
             t
             (Detail_block
                { generation = request_generation
                ; block_id
                ; limit = (match cursor with Some (Projection.Child_cursor value)->value.maximum_items
                    | _->max 1 (min Protocol.maximum_page_size limit))
                ; after = (match cursor with Some (Projection.Child_cursor value)->Some value | _->None)
                })
             (if Hashtbl.mem t.graph_pages block_id
                ||
                Favorites.is_page_target t.favorites block_id
              then Protocol.V2_get_page { page = block; revision = None }
              else Protocol.V2_get_outline_block { block; revision = None })
         ])
  | Find_block block_id ->
    (match parse_uuid "block UUID" block_id with
     | Error message -> reject message
     | Ok block ->
       requests
         [ read t Find_block_result (Protocol.V2_get_outline_block { block; revision = None }) ])
  | Capture { calendar_generation; command } ->
    (match
       ( calendar_generation_is_current t calendar_generation
       , journal_uuid (Journal_time.local_day command.creation_time) )
     with
     | false, _ -> reject "The local calendar changed before capture admission."
     | true, Error message -> reject message
     | true, Ok page_uuid ->
       (match task_status_uuid t command.task_state with
        | Error message -> reject message
        | Ok _ ->
       requests
         [ read
             t
             (Capture_page command)
             (Protocol.V2_get_page { page = page_uuid; revision = None })
            ]))
  | Update_source command ->
    (match
       mutation_context t command.mutation_id, parse_uuid "block UUID" command.block_id
     with
     | Ok mutation_id, Ok block ->
       (match page_by_block t command.block_id with
        | None -> reject "The block page is not retained."
        | Some page ->
          requests
            [ mutate
                t
                (Mutation_refresh
                   { page; refresh = Updated { block_id = command.block_id } })
                (Protocol.V2_save_block
                   { mutation_id
                   ; block
                   ; title = command.source
                   ; preconditions =
                       preconditions ~blocks:[ block, command.expected_revision ] ()
                   })
            ])
     | Error message, _ | _, Error message -> reject message)
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
              Ok (Protocol.V2_clear_task_status { mutation_id; block; preconditions })
            | Ok (Some status) ->
              Ok
                (Protocol.V2_set_task_status { mutation_id; block; status; preconditions })
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
    let reject message =
      responses
        [ response
            (Child_failed
               { mutation_id = command.mutation_id
               ; block_id = command.block_id
               ; failure = Projection_failure message
               })
        ]
    in
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
           (match scope_precondition t (Protocol.V2_children_scope parent) with
            | Error message -> reject message
            | Ok scope_revision ->
              requests
                [ mutate
                    t
                    (Child_insert (command, page))
                    (Protocol.V2_insert_blocks
                       { mutation_id
                       ; parent
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
                       })
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
             (Protocol.V2_delete_blocks { mutation_id; root = block; preconditions })
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
    | Update_source command ->
      Some
        (Mutation_owner
           { kind = Source_mutation
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
    ; plan_read = (fun ~source_epoch value command ->
        read ~source_epoch t (Target_summary value) command) }
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
  Hashtbl.replace t.page_tree_interests page.Projection.id {page;limit=Protocol.maximum_page_size};
  request_target_summary_without_interest t refresh
;;
let request_delete_summary t block_id =
  let refresh=Delete_conflict_refresh{block_id} in
  match page_by_block t block_id with
  | Some page->request_target_summary t page refresh
  | None->request_target_summary_without_interest t refresh
;;

let capture_tree (command : Projection.capture) =
  let project (child : Projection.capture_child) =
    match parse_uuid "child UUID" child.block_id with
    | Error _ as error -> error
    | Ok uuid -> Ok Protocol.{ uuid; title = child.source; children = [] }
  in
  match parse_uuid "block UUID" command.Projection.block_id with
  | Error _ as error -> error
  | Ok uuid ->
    let rec children reversed = function
      | [] -> Ok (List.rev reversed)
      | child :: rest ->
        (match project child with
         | Error _ as error -> error
         | Ok child -> children (child :: reversed) rest)
    in
    Result.map
      (fun children -> Protocol.{ uuid; title = command.source; children })
      (children [] command.children)
;;

let capture_insert t (command : Projection.capture) page conflict_retries =
  match
    ( capture_tree command
    , mutation_context t command.mutation_id
    , parse_uuid "page UUID" page.Projection.id )
  with
  | Ok tree, Ok mutation_id, Ok page_uuid ->
    let scope = Protocol.V2_children_scope page_uuid in
    (match page_preconditions t page_uuid, scope_precondition t scope with
     | Ok page_revision, Ok scope_revision ->
       requests
         [ mutate
             t
             (Capture_insert { command; page; conflict_retries })
             (Protocol.V2_insert_blocks
                { mutation_id
                ; parent = page_uuid
                ; roots = [ tree ]
                ; preconditions =
                    preconditions ~pages:[ page_revision ] ~scopes:[ scope_revision ] ()
                })
         ]
     | Error message, _ | _, Error message -> reject message)
  | Error message, _, _ | _, Error message, _ | _, _, Error message -> reject message
;;

let capture_children t command page conflict_retries =
  match parse_uuid "page UUID" page.Projection.id with
  | Error message -> reject message
  | Ok parent ->
    requests
      [ read
          t
          (Capture_children { command; page; conflict_retries })
          (Protocol.V2_get_children
             { parent
             ; limit = Protocol.maximum_page_size
             ; cursor = None
             ; revision = None
             })
      ]
;;

let status_mutation_id ~domain ~mutation_id ~revision ~block status =
  (* A persistent sub-operation belongs to its composer intent, not the lifetime
     of the request counter. Resolve Default_status before deriving the identity
     so retrying one choice is stable. The business-owned revision distinguishes
     choosing A again after B from replaying the first A operation. *)
  let intent =
    match status with
    | None -> "clear"
    | Some status -> "set:" ^ Graph.Uuid.to_string status
  in
  let bytes =
    Printf.sprintf
      "logseq-journal:%s-status:v1:%s:%s:%Ld:%s"
      domain
      (String.lowercase_ascii mutation_id)
      (Graph.Uuid.to_string block)
      revision
      intent
    |> Digest.BLAKE128.string
    |> Bytes.of_string
  in
  (* Custom UUID version 8; keep the variant bits and remaining digest bits. *)
  Bytes.set bytes 6 (Char.chr ((Char.code (Bytes.get bytes 6) land 0x0f) lor 0x80));
  Bytes.set bytes 8 (Char.chr ((Char.code (Bytes.get bytes 8) land 0x3f) lor 0x80));
  let hex = Digest.BLAKE128.to_hex (Bytes.to_string bytes) in
  Printf.sprintf "%s-%s-%s-%s-%s"
    (String.sub hex 0 8) (String.sub hex 8 4) (String.sub hex 12 4)
    (String.sub hex 16 4) (String.sub hex 20 12)
  |> Graph.Uuid.of_string
  |> Result.get_ok
;;

let capture_status_mutation_id (command : Projection.capture) ~block status =
  status_mutation_id ~domain:"capture" ~mutation_id:command.mutation_id
    ~revision:command.status_intent_revision ~block status
;;

let capture_status t (command : Projection.capture) page =
  match task_status_uuid t command.task_state with
  | Error message -> reject message
  | Ok None when not command.status_confirmation ->
    request_target_summary t page (Captured { block_id = command.block_id })
  | Ok status ->
    (match parse_uuid "block UUID" command.block_id with
     | Error message -> reject message
     | Ok block ->
       (match block_preconditions t block with
        | Error message -> reject message
        | Ok preconditions ->
          let mutation_id = capture_status_mutation_id command ~block status in
          let command_status =
            match status with
            | None -> Protocol.V2_clear_task_status { mutation_id; block; preconditions }
            | Some status ->
              V2_set_task_status { mutation_id; block; status; preconditions }
          in
          requests [ mutate t (Capture_status { command; page }) command_status ]))
;;

let continue_capture t (command : Projection.capture) page =
  if command.task_state = Journal_model.No_status && not command.status_confirmation
  then capture_status t command page
  else (
    match parse_uuid "block UUID" command.block_id with
     | Error message -> reject message
     | Ok block ->
       requests
         [ read
             t
             (Capture_block { command; page })
             (Protocol.V2_get_outline_block { block; revision = None })
         ])
;;

let append_unique equal value values =
  if List.exists (equal value) values then values else values @ [ value ]
;;

let changed_interests windows =
  List.fold_left
    (fun (blocks, pages, structures) (window : Protocol.v2_change_window) ->
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
      let key = Graph.Uuid.to_string request.Protocol.request_id in
      match Hashtbl.find_opt t.pending key with
      | Some pending when pending.delivery = Queued ->
        if favorite_request_current t pending
        then drain (issue_request t request :: reversed)
        else (
          Option.iter(fun token->t.on_change(Coordination.Change_consumer_retired(token,request.request_id))) pending.change_application;
          Hashtbl.remove t.pending key; drain reversed)
      | None | Some _ -> drain reversed)
  in
  drain []
;;

let background_demands t output =
  List.iter (fun (request : Protocol.request) ->
    match Hashtbl.find_opt t.pending (Graph.Uuid.to_string request.request_id) with
    | Some pending when pending.delivery = Planned -> pending.background <- true
    | None | Some _ -> ()) output.requests;
  output
;;

(* One dispatch per public transition. Delivery state makes queued/active
   ownership exclusive and suppresses repeated demand identities. *)
let dispatch_output t output =
  let foreground = List.filter_map (fun (request : Protocol.request) ->
    match Hashtbl.find_opt t.pending (Graph.Uuid.to_string request.request_id) with
    | Some pending when pending.delivery = Planned ->
      if pending.background then (
        pending.delivery <- Queued;
        Queue.push request t.hydration_queue;
        None)
      else Some (issue_request t request)
    | None | Some _ -> None) output.requests in
  { output with requests = foreground @ drain_hydration t }
;;

let submit t request = dispatch_output t (plan_request t request)

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
    ; plan_read = (fun ~source_epoch value command ->
        read ?source_epoch ~background:true t (Reference_read value) command)
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
             (Protocol.V2_get_page {page=block;revision=None})))
         else (
           match page_by_block t block_id with
         | Some _ ->
           Some
             (read
                t
                (Changed_block { block_id })
                (Protocol.V2_get_outline_block { block; revision = None }))
         | None ->
           Option.map
             (fun _ ->
                read
                  t
                  (Changed_detail_block { block_id })
                  (Protocol.V2_get_outline_block { block; revision = None }))
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
        | Protocol.V2_page_tree_interest page ->
          Option.bind (registered_tree t page) (fun interest ->
            Feed.reconcile_page t.feed ~ports:(feed_ports t)
              ~page:interest.page ~limit:interest.limit)
        | V2_children_interest _ | V2_journal_index_interest -> None)
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
                (Protocol.V2_get_page { page; revision = None }))
         else None)
      pages
  in
  let children_reads =
    List.filter_map
      (function
        | Protocol.V2_children_interest parent ->
          Option.map
            (fun interest ->
               read
                 t
                 (Changed_children interest)
                 (Protocol.V2_get_children
                    { parent; limit = interest.limit; cursor = None; revision = None }))
            (registered_children t parent)
        | V2_page_tree_interest _ | V2_journal_index_interest -> None)
      structures
  in
  let journal_changed =
    List.exists
      (function
        | Protocol.V2_journal_index_interest -> true
        | V2_children_interest _ | V2_page_tree_interest _ -> false)
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
        | Protocol.V2_journal_index_interest -> `Assoc ["kind", `String "journal-index"]
        | V2_children_interest u -> `Assoc ["kind", `String "children"; "target", `String (Graph.Uuid.to_string u)]
        | V2_page_tree_interest u -> `Assoc ["kind", `String "page-tree"; "target", `String (Graph.Uuid.to_string u)]))
    ; "truncated", `Bool (List.length pages > 16 || List.length blocks > 16 || List.length structures > 16)
    ];
  let journal =
    if not journal_changed then empty else
      match Feed.refresh_initial t.feed ~ports:(feed_ports t) ~request_generation with
      | None -> empty
      | Some planned ->
        let output = feed_output t planned in
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
        @ favorites.requests
    ; responses = journal.responses @ favorites.responses
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
  let graph_info = read t Graph_info Protocol.V2_graph_info in
  let journal =
    match Feed.refresh_initial t.feed ~ports:(feed_ports t) ~request_generation with
    | None -> empty
    | Some planned ->
      let output = feed_output t planned in
      {output with responses=response (Feed_refresh_started {request_generation})::output.responses}
  in
  let tree_requests =
    Hashtbl.to_seq_values t.page_tree_interests
    |> List.of_seq
    |> List.filter_map (fun (interest : page_tree_interest) ->
      Feed.reconcile_page t.feed ~ports:(feed_ports t)
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
             (Protocol.V2_get_children
                { parent; limit = interest.limit; cursor = None; revision = None })))
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
        (Changed_detail_block { block_id })
        (Protocol.V2_get_outline_block { block = interest.root.block.uuid; revision = None }))
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
      read t (Changed_detail_page page) (Protocol.V2_get_page { page; revision = None }))
    |> List.of_seq
  in
  background_demands
    t
    { requests =
        (graph_info :: journal.requests)
        @ tree_requests
        @ children_requests
        @ detail_roots
        @ detail_page_requests
        @ reference_requests
    ; responses =
        response Projection_resync :: response Favorites_invalidated :: journal.responses
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
    | Protocol.V2_children_revision parent -> Protocol.V2_children_scope parent
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
        (Protocol.V2_get_children
           { parent = root.block.uuid; limit; cursor = None; revision = None })
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

let read_child t command page =
  requests
    [ read
        t
        (Child_read (command, page))
        (Protocol.V2_get_outline_block
           { block = Graph.Uuid.of_string command.Projection.block_id |> Result.get_ok
           ; revision = None
           })
    ]
;;

let read_child_parent t command page child =
  let parent = Graph.Uuid.of_string command.Projection.parent_block_id |> Result.get_ok in
  requests
    [ read t (Child_parent (command, page, child))
        (if Graph.Uuid.equal parent page.Graph.uuid
         then Protocol.V2_get_page { page = parent; revision = None }
         else Protocol.V2_get_outline_block { block = parent; revision = None }) ]
;;

let complete_child ?parent_child_count ?(child_child_count=0) ?(refresh=true) t (command : Projection.create_child) (page : Graph.page)
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
    let old_count = Hashtbl.find_opt t.projected_blocks command.parent_block_id
        |> Option.map Journal_model.child_count
        |> Option.value ~default:0
      in
      (match
      (Projection.block_on_page ~page ~revision:parent.revision
         ~child_count:(Option.value parent_child_count ~default:(old_count + 1)) ~time_context parent.block,
       Projection.block_on_page ~page ~revision:child.revision ~child_count:child_child_count
         ~time_context child.block) with
    | Ok parent, Ok child ->
      let parent=Journal_model.with_tag_titles parent
        ~tag_titles:(Option.value(Hashtbl.find_opt t.tag_titles command.parent_block_id)~default:[]) in
      let child=Journal_model.with_tag_titles child
        ~tag_titles:(Option.value(Hashtbl.find_opt t.tag_titles command.block_id)~default:[]) in
      Hashtbl.replace t.projected_blocks command.parent_block_id parent;
      let completion = response (Child_created {child;parent;timeline_entry_update=None}) in
      let refresh = if not refresh then empty else match page_by_uuid t page.uuid with
        | None -> empty
        | Some page ->
          (match Feed.reconcile_page t.feed ~ports:(feed_ports t) ~page
            ~limit:Protocol.maximum_page_size with
           | Some request -> requests [request]
           | None -> empty)
      in
      {refresh with responses=completion::refresh.responses}
       | Error message, _ | _, Error message -> reject message))
;;

let finish_child_parent t ~root ~round ~(summary:Worker.block_summary) parent =
  match child_root t root with
  | None -> empty
  | Some(_,chain,_) ->
    let next,action=Child.projection_ready chain ~round in
    (match action,summary.lookup with
     | Child.Present _,Protocol.V2_present_block{value;revision} ->
       remember_block_revision t value.block.uuid revision;
       Hashtbl.replace t.tag_titles (Graph.Uuid.to_string value.block.uuid) value.tag_titles;
       let child=Projection.{block=value.block;revision} in
       (* These counts are lower bounds from the actual child snapshot, never a
          fabricated parent total or an increment of an old projection. *)
       let output=complete_child ~parent_child_count:1
         ~child_child_count:(List.length summary.items + if summary.next=None then 0 else 1)
         ~refresh:false t (Child.command chain) (Child.page chain) child parent in
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
      ~(value : Protocol.v2_block_record)
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
         value.Protocol.block
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
      ~(value : Protocol.v2_block_record)
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
          (Protocol.V2_get_page { page = value.block.page; revision = None })
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
  | Child_write _ -> "mutateChild"
  | Child_canonical _ -> "readCanonicalChild"
  | Child_chain_parent _ -> "readCanonicalChildParent"
  | Child_ack _ -> "acknowledgeChildOutcome"
  | Child_insert _ -> "appendChild"
  | Child_read _ -> "readAppendedChild"
  | Child_status _ -> "setAppendedChildStatus"
  | Child_parent _ -> "readAppendParent"
  | Changed_block _ -> "reconcileChangedBlock"
  | Changed_detail_block _ -> "reconcileChangedDetailBlock"
  | Changed_point_context _ -> "resolveChangedBlockPage"
  | Changed_detail_page _ -> "reconcileChangedDetailPage"
  | Find_block_result -> "findBlock"
  | Detail_children _ -> "loadDetailChildren"
  | Changed_children _ -> "refreshChildren"
  | Capture_page _ -> "findCapturePage"
  | Capture_format _ -> "readJournalTitleFormat"
  | Capture_create_page _ -> "createCapturePage"
  | Capture_children _ -> "refreshCaptureChildren"
  | Capture_insert _ -> "insertCaptureBlock"
  | Capture_block _ -> "readCapturedBlock"
  | Capture_status _ -> "setCaptureStatus"
  | Target_summary _ -> "readMutationTargetSummary"
  | Mutation_refresh _ -> "refreshMutation"
  | Delete_mutation _ -> "deleteSubtree"
;;

let worker_error code request_id message =
  Error.create ~code ~message ~details:[]
  |> Result.fold ~ok:Fun.id ~error:(fun _ ->
    Error.create
      ~code:Unsupported_semantics
      ~message:"The Worker request failed."
      ~details:[]
    |> Result.get_ok)
  |> fun error -> request_id, error
;;

let failure_output
      ~source_epoch
      ?(code = Error.Unsupported_semantics)
      t
      operation
      request_id
      message
  =
  let request_id, error = worker_error code request_id message in
  let worker_failure = { operation = operation_name operation; request_id; error } in
  match operation with
  | Task_catalog { epoch; _ } when epoch <> t.task_catalog_epoch -> empty
  | Task_catalog _ ->
    t.task_catalog_loading <- false;
    Hashtbl.clear t.task_catalog_deletions;
    responses [ task_catalog_response ~error:message t ]
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
    if !current then responses [ task_catalog_response ~error:message t ] else empty
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
  | Admission_info request -> responses [ response (Admission_unavailable request) ]
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
  | Child_chain _ -> child_step t request_id(fun chain->Child.interrupted chain ~index:0 ~round:1L message)
  | Child_write{root;index;round}|Child_ack{root;index;round;_}->
    child_step t root(fun chain->Child.interrupted chain ~index ~round message)
  | Child_canonical{root;round}|Child_chain_parent{root;round;_}->
    child_step t root(fun chain->Child.read_failed chain ~round message)
  | Child_insert (command, _)
  | Child_read (command, _)
  | Child_status (command, _)
  | Child_parent (command, _, _) ->
    responses
      [ response
          (Child_failed
             { mutation_id = command.mutation_id
             ; block_id = command.block_id
             ; failure = Worker_failure worker_failure
             })
      ]
  | Reference_read { block_id; depth; _ } ->
    Reference.read_failed t.references ~ports:(reference_ports t) ~source_epoch ~block_id ~depth
    |> reference_output
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
  | Capture_page _
  | Capture_format _
  | Capture_create_page _
  | Capture_children _
  | Capture_insert _
  | Capture_block _
  | Capture_status _
  | Target_summary _
  | Mutation_refresh _
  | Delete_mutation _ -> responses [ response (Rejected (Worker_failure worker_failure)) ]
;;

let children_result items continuation : Projection.children_page =
  { items =
      List.map
        (fun (item : Protocol.v2_child_member) ->
           Projection.{ block = item.value.block; revision = item.revision })
        items
  ; continuation
  }
;;

let receive_response t ~read_result ~origin (protocol_response : Protocol.response) =
  let favorites = match read_result with Some (Favorites_read {value;_})->Some value | _->None in
  let catalog = match read_result with Some (Task_catalog_read value)->Some value | _->None in
  let journals = match read_result with Some (Journals_read value)->Some value | _->None in
  let target_summary = match read_result with Some (Target_summary_read value)->Some value | _->None in
  let roots = match read_result with Some (Root_tree_read {value;_})->Some value | _->None in
  let children = match read_result with Some (Child_members_read value)->Some value | _->None in
  let (Protocol.V2_response { request_id; outcome; _ }) = protocol_response in
  let key = Graph.Uuid.to_string request_id in
  match Hashtbl.find_opt t.pending key with
  | None -> empty
  | Some {operation=Feed_read operation;_} when not (Feed.is_current t.feed operation) ->
    Hashtbl.remove t.pending key; Feed.superseded t.feed operation |> feed_output t
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
    (match (match operation with Feed_read value -> Feed.receive t.feed ~ports:(feed_ports t) ?journals ?children ?roots ?origin value outcome | _ -> None) with
     | Some planned -> feed_output t planned
     | _ -> (match outcome with
     | Protocol.V2_assets_outcome _ ->
       failure_output t operation request_id "Unexpected asset query response."
     | V2_page_tree_outcome _ ->
       failure_output t operation request_id "Unowned page-tree response."
     | Protocol.V2_favorites_outcome result ->
       (match operation with
        | Favorite_read read when Favorites.accepts_list read ->
          let result=match favorites with
            | Some result->Ok result
            | None when result.next_cursor=None->Ok Journal_graph_request.
                {favorites_page=result.favorites_page;generation=result.generation;
                 projection_revision=result.projection_revision;items=Rrbvec.of_list result.items;next_cursor=None}
            | None->Error "An unsealed Favorites continuation cannot enter the business state." in
          (match result with
           | Ok result->Favorites.receive_list t.favorites ~ports:(favorites_ports t) read result
             |> favorites_output |> background_demands t
           | Error message->failure_output t operation request_id message)
        | _ -> failure_output t operation request_id "Unexpected favorites response.")
     | Protocol.V2_failed { code; message } ->
       (match Error.code_of_string code with
        | None ->
          failure_output
            ~code:Error.Invalid_request
            t
            operation
            request_id
            "The Worker returned an unknown failure code."
        | Some failure_code ->
          (match operation with
           | Target_summary summary when failure_code = Error.Stale_read_cursor ->
             (match Confirmation.retry_stale t.confirmations ~ports:(confirmation_ports t) summary with
              | Some planned -> confirmation_planning planned
              | None -> failure_output ~code:failure_code t operation request_id message)
           | Capture_insert { command; page; conflict_retries }
             when String.equal code (Error.code_string Error.Conflict)
                  && conflict_retries < 2 ->
             capture_children t command page (conflict_retries + 1)
           | Delete_mutation command
             when String.equal code (Error.code_string Error.Conflict) ->
             request_delete_summary t command.block_id
           | _ -> failure_output ~code:failure_code t operation request_id message))
     | V2_resync_required { generation; reason } ->
       (match operation with
        | Pull_changes { request_generation; _ } ->
          rehydrate_current_interests t ~request_generation ~generation
        | _ -> failure_output t operation request_id reason)
     | V2_graph_info_outcome { journal_title_format; generation; _ } ->
       (match operation with
        | Graph_info ->
          if t.change_generation<>Some generation then t.change_cursor<-None;
          t.change_generation<-Some generation;
          let catalog =
            if t.task_catalog_started then [] else [ request_task_catalog t ]
          in
          { requests = catalog; responses = [ response Graph_ready ] }
        | Capture_format { command; page_uuid; page_revision } ->
          let journal_day = Journal_time.local_day command.creation_time in
          let page_mutation = request_uuid t in
          let request = mutate
                t
                (Capture_create_page { command; page_uuid })
                (Protocol.V2_create_journal_page
                   { mutation_id = page_mutation
                   ; page = page_uuid
                   ; journal_day
                   ; title = journal_title ~format:journal_title_format journal_day
                   ; preconditions = preconditions ~pages:[ page_uuid, page_revision ] ()
                   })
          in
          report_capture_evidence ~stage:"create-page" ~page_mutation
            ~request:request.request_id ~target:page_uuid command;
          requests [ request ]
        | _ -> failure_output t operation request_id "Unexpected graph-info response.")
     | V2_task_statuses_outcome { property_uuid; default_status; items; next_cursor } ->
       (match operation with
        | Task_catalog { epoch; _ } when epoch <> t.task_catalog_epoch -> empty
        | Task_catalog { epoch; seen; _ } ->
          let values =
            match catalog with
            | Some value ->
              Ok (value.Worker.property_uuid, value.default_status, value.items, value.next)
            | None when next_cursor = None -> Ok (property_uuid, default_status, items, None)
            | None ->
              Error "An unsealed task catalog continuation cannot enter business state."
          in
          Result.fold
            ~error:(fun message -> failure_output t operation request_id message)
            ~ok:(fun (property_uuid, default_status, items, next_cursor) ->
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
                      (Protocol.V2_list_task_statuses
                         { limit = Protocol.maximum_page_size; cursor = None })
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
              })
            values
        | _ -> failure_output t operation request_id "Unexpected status catalog response.")
     | V2_task_status_definitions_outcome definitions ->
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
     | V2_admission_outcome observation ->
       (match operation with
        | Admission_info request ->
          responses [ response (Admission_inspected { request; observation }) ]
        | _ -> failure_output t operation request_id "Unexpected admission response.")
     | V2_journals_outcome { items; next_cursor = _ } ->
       List.iter
         (fun (item : Protocol.v2_journal_item) ->
            Hashtbl.replace t.graph_pages (Graph.Uuid.to_string item.page.uuid) item.page;
            remember_page_revision t item.page.uuid item.revision)
         items;
       (match operation with
        | _ -> failure_output t operation request_id "Unexpected journal response.")
     | V2_page_outcome lookup ->
       (match lookup, operation with
        |V2_present_page{page;revision=page_revision},Changed_point_context{block_id;value;revision;child_count}
          when Graph.Uuid.equal page.uuid value.block.page && not page.recycled->
          remember_page_revision t page.uuid page_revision;
          publish_changed_point t ~block_id ~value ~revision ~child_count ~page
        |_,Changed_point_context _->reject "The changed block page is unavailable."
        | ( (V2_present_page _ | V2_missing_page _)
          , Reference_read ({ lookup = Reference.Page_lookup; _ } as value) ) ->
          Reference.receive_page t.references ~ports:(reference_ports t)
            ~source_epoch value lookup |> reference_output
        | ( V2_present_page { page; revision }
          , Detail_block { generation; block_id; limit; after } )
          when Graph.Uuid.to_string page.uuid = block_id && not page.recycled ->
          remember_page_revision t page.uuid revision;
          Hashtbl.replace t.graph_pages block_id page;
          detail_children t ~generation ~page ~root:(page_root_member page revision) ~limit ~after
        | ( (V2_missing_page _ | V2_present_page _)
          , Detail_block { generation; block_id; _ } ) ->
          responses [response (Detail_failed {request_generation=generation;block_id;
            missing=true;stale_cursor=false;failure=Projection_failure "This page is unavailable."})]
        | V2_present_page {page;revision}, Child_chain_parent{root;round;summary}
          when not page.recycled ->
          remember_page_revision t page.uuid revision;
          Hashtbl.replace t.graph_pages (Graph.Uuid.to_string page.uuid) page;
          finish_child_parent t ~root ~round ~summary (page_root_member page revision)
        | V2_present_page {page;revision}, Child_parent (command,_,child)
          when Graph.Uuid.to_string page.uuid = command.parent_block_id && not page.recycled ->
          remember_page_revision t page.uuid revision;
          Hashtbl.replace t.graph_pages command.parent_block_id page;
          complete_child t command page child (page_root_member page revision)
        | _, Favorite_read value when Favorites.accepts_page t.favorites value ->
          let planned = Favorites.receive_page t.favorites ~ports:(favorites_ports t) value lookup in
          let output = favorites_output planned in
          if planned.background then background_demands t output else output
        | V2_present_page { page; revision }, Changed_detail_page _ when not page.recycled ->
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
        | ( ( V2_missing_page { uuid; _ }
            | V2_present_page { page = { uuid; recycled = true; _ }; _ } )
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
        | ( V2_present_page { page; revision }
          , Detail_page { generation; root; limit; after } ) ->
          remember_page_revision t page.uuid revision;
          if page.recycled
          then failure_output t operation request_id "The block page is unavailable."
          else (
            Hashtbl.replace t.graph_pages (Graph.Uuid.to_string page.uuid) page;
            detail_children t ~generation ~page ~root ~limit ~after)
        | V2_present_page { page; revision }, Capture_page command ->
          report_capture_evidence ~stage:"page-lookup" ~result:"present"
            ~request:request_id ~target:page.uuid command;
          remember_page_revision t page.uuid revision;
          (match page_of_graph_page page with
           | None -> reject "The target journal page is unavailable."
           | Some page ->
             remember_page t page;
             capture_children t command page 0)
        | V2_missing_page _, Detail_page { generation; root; _ } ->
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
        | V2_missing_page { uuid; revision }, Capture_page command ->
          report_capture_evidence ~stage:"page-lookup" ~result:"missing"
            ~request:request_id ~target:uuid command;
          remember_page_revision t uuid revision;
          requests
            [ read
                t
                (Capture_format { command; page_uuid = uuid; page_revision = revision })
                Protocol.V2_graph_info
            ]
        | _ -> failure_output t operation request_id "Unexpected page response.")
     | V2_block_summary_outcome
         { lookup
         ; page
         ; items
         ; next_cursor
         ; scope_revision
         ; generation
         ; projection_revision
         } ->
       (match operation with
        | Child_canonical{root;round}->
          (match read_result with
           | Some(Child_chain_summary summary)->child_step t root(fun chain->Child.read_child chain ~round summary)
           | _->child_step t root(fun chain->Child.read_failed chain ~round "The typed child snapshot is unavailable."))
        | Target_summary summary ->
          (match (match target_summary,next_cursor with
             | None,Some _ -> Confirmation.Failed "Unsealed target summary continuation"
             | _ -> Confirmation.receive_summary t.confirmations ~ports:(confirmation_ports t) summary
               ~lookup ~page ~items ~next_cursor:(Option.bind target_summary (fun (value:Worker.block_summary)->value.next))
               ~scope_revision ~generation ~projection_revision) with
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
                            (scope_key (Protocol.V2_children_scope value.block.uuid))
                            scope_revision;
                          Hashtbl.replace t.tag_titles block_id value.tag_titles;
                          Hashtbl.replace t.projected_blocks block_id block;
                          Option.iter
                            (fun journal ->
                               Hashtbl.replace
                                 t.page_tree_interests
                                 journal.Projection.id
                                 { page = journal; limit = Protocol.maximum_page_size };
                               remember_block_page t journal block_id;
                               Rrbvec.iter
                                 (fun (item : Protocol.v2_child_member) ->
                                    remember_block_page
                                      t
                                      journal
                                      (Graph.Uuid.to_string item.value.block.uuid))
                                 children)
                            (page_of_graph_page page);
                          Rrbvec.iter
                            (fun (item : Protocol.v2_child_member) ->
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
                           | Captured _ ->
                             responses
                               [ response
                                   (Block_captured
                                      { block; timeline_entry_update = entry })
                               ]
                           | Updated _ ->
                             responses
                               [ response
                                   (Block_updated { block; timeline_entry_update = entry })
                               ]
                           | Update_conflict_refresh _ -> responses [response (Update_conflict {block;timeline_entry_update=entry})]
                           | Delete_conflict_refresh _ -> responses [response (Delete_conflict {block;timeline_entry_update=entry})]))))
          )
        | _ -> failure_output t operation request_id "Unexpected target summary response.")
     | V2_block_outcome lookup ->
       (match lookup with
        | V2_present_block { value; _ } ->
          Hashtbl.replace
            t.tag_titles
            (Graph.Uuid.to_string value.block.uuid)
            value.tag_titles
        | V2_missing_block _ -> ());
       (match lookup, operation with
        | _, Favorite_read value when Favorites.accepts_block t.favorites value ->
          let planned = Favorites.receive_block t.favorites ~ports:(favorites_ports t) value lookup in
          let output = favorites_output planned in
          if planned.background then background_demands t output else output
        | ( V2_present_block { value; revision }
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
                   (Protocol.V2_get_page { page = value.block.page; revision = None })
               ])
        | ( V2_missing_block { uuid; _ }
          , Detail_block { generation; block_id; limit; after } )
          when Graph.Uuid.to_string uuid = block_id ->
          requests [read t (Detail_block {generation;block_id;limit;after})
            (Protocol.V2_get_page {page=uuid;revision=None})]
        | V2_present_block { value; revision }, Child_read (command, page) ->
          remember_block_revision t value.block.uuid revision;
          let child = Projection.{ block = value.block; revision } in
          (match task_status_uuid t command.task_state with
           | Error message -> reject message
           | Ok status
             when value.task_status = status
                  || (status = None && not command.status_confirmation) ->
             read_child_parent t command page child
           | Ok status ->
             let block = value.block.uuid in
             let mutation_id =
               status_mutation_id ~domain:"child" ~mutation_id:command.mutation_id
                 ~revision:command.status_intent_revision ~block status
             in
             let preconditions = preconditions ~blocks:[ block, revision ] () in
             let mutation =
               match status with
               | None ->
                 Protocol.V2_clear_task_status { mutation_id; block; preconditions }
               | Some status ->
                 V2_set_task_status { mutation_id; block; status; preconditions }
             in
             requests [ mutate t (Child_status (command, page)) mutation ])
        | V2_present_block {value;revision},Child_chain_parent{root;round;summary}->
          remember_block_revision t value.block.uuid revision;
          finish_child_parent t ~root ~round ~summary Projection.{block=value.block;revision}
        | V2_present_block { value; revision }, Child_parent (command, page, child) ->
          remember_block_revision t value.block.uuid revision;
          complete_child t command page child Projection.{block=value.block;revision}
        | ( (V2_present_block _ | V2_missing_block _)
          , Reference_read ({ lookup = Reference.Outline_lookup; _ } as value) ) ->
          Reference.receive_outline t.references ~ports:(reference_ports t)
            ~source_epoch value lookup |> reference_output
        | V2_present_block { value; revision }, Find_block_result ->
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
        | V2_missing_block _, Find_block_result ->
          responses [ response (Block_found None) ]
        |V2_present_block{value;revision},(Changed_block{block_id;_}|Changed_detail_block{block_id;_})->
          resolve_changed_point t ~source_epoch ~block_id ~value ~revision
        | V2_missing_block { uuid; revision }, Changed_block { block_id; _ }
        | V2_missing_block { uuid; revision }, Changed_detail_block { block_id; _ } ->
          remember_block_revision t uuid revision;
          t.block_pages
          <- List.filter
               (fun (candidate, _) -> not (String.equal candidate block_id))
               t.block_pages;
          Hashtbl.remove t.projected_blocks block_id;
          Hashtbl.remove t.detail_pages block_id;
          Hashtbl.remove t.children_interests block_id;
          Hashtbl.remove t.detail_children block_id;
          responses [ response (Block_removed { block_id }) ]
        | V2_present_block { value; revision }, Capture_block { command; page } ->
          remember_block_revision t value.block.uuid revision;
          capture_status t command page
        | V2_missing_block _, Capture_block _ ->
          reject "The captured block is unavailable."
        | _ -> failure_output t operation request_id "Unexpected block response.")
     | V2_children_outcome { revision_scope; scope_revision; items; next_cursor; _ } ->
       remember_scope_revision t revision_scope scope_revision;
       List.iter
         (fun (item : Protocol.v2_child_member) ->
            remember_block_revision t item.value.block.uuid item.revision;
            Hashtbl.replace
              t.tag_titles
              (Graph.Uuid.to_string item.value.block.uuid)
              item.value.tag_titles)
         items;
       (match operation with
        | (Detail_children _ | Changed_children _ | Capture_children _)
          when children=None && next_cursor<>None ->
          failure_output t operation request_id "Unsealed child continuation"
        | Detail_children { generation; page; root; limit; _ } ->
          let children = children_result items (Option.bind children (fun (value:Worker.children)->
              Option.map (fun after -> ({Projection.after;maximum_items=limit}:Projection.child_cursor)) value.next)) in
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
          if children = None && next_cursor <> None
          then failure_output t operation request_id "Unsealed Favorite membership continuation"
          else (
            let planned = Favorites.receive_memberships t.favorites ~ports:(favorites_ports t)
                value items (Option.bind children (fun (value:Worker.children) -> value.next)) in
            let output = favorites_output planned in
            if planned.background then background_demands t output else output)
        | Changed_children { page; root; limit } ->
          let children = children_result items (Option.bind children (fun (value:Worker.children)->
              Option.map (fun after -> ({Projection.after;maximum_items=limit}:Projection.child_cursor)) value.next)) in
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
        | Capture_children { command; page; conflict_retries } ->
          let children = children_result items None in
          remember_blocks t page children.items;
          capture_insert t command page conflict_retries
        | _ -> failure_output t operation request_id "Unexpected children response.")
     | V2_mutation_committed _ ->
       (match operation with
        | Child_insert (command, page) | Child_status (command, page) ->
          read_child t command page
        | Capture_create_page { command; page_uuid } ->
          requests
            [ read
                t
                (Capture_page command)
                (Protocol.V2_get_page { page = page_uuid; revision = None })
            ]
        | Capture_insert { command; page; _ } -> continue_capture t command page
        | Capture_status { command; page } ->
          request_target_summary t page (Captured { block_id = command.block_id })
        | Mutation_refresh { page; refresh } -> request_target_summary t page refresh
        | Delete_mutation command ->
          responses
            [ response
                (Subtree_deleted
                   { block_id = command.block_id
                   ; deleted_count = None
                   ; parent = None
                   ; timeline_entry_update = None
                   })
            ]
        | _ -> failure_output t operation request_id "Unexpected mutation response.")
     | V2_changes { generation; through; windows; next; _ } ->
       (match operation with
        | Pull_changes { request_generation; _ } ->
          report_timeline "runtime-change-window"
            [ "phase", `String "received"; "request", `String (Graph.Uuid.to_string request_id)
            ; "requestGeneration", `String (Int64.to_string request_generation)
            ; "generation", timeline_version generation; "through", timeline_version through
            ; "windowCount", `Int (List.length windows)
            ; "windows", `List (List.take 16 windows |> List.map (fun (w : Protocol.v2_change_window) ->
                `Assoc ["id", timeline_version w.id; "predecessor", timeline_version w.predecessor;
                  "successor", timeline_version w.successor; "blockCount", `Int (List.length w.block_uuids);
                  "pageCount", `Int (List.length w.page_uuids); "interestCount", `Int (List.length w.structure_interests)]))
            ; "truncated", `Bool (List.length windows > 16)
            ];
          t.change_generation <- Some generation;
          let batch=match read_result with Some(Changes_read batch)->Some batch|_->None in
          t.latest_change_batch<-batch;
          let acknowledgement =
            read t (Acknowledge_changes {batch;continuation=Option.map(fun _->request_generation)next}) (Protocol.V2_ack_changes { generation; through })
          in
          let hydration = hydration_for_changes t ~request_generation windows in
          let catalog_requests =
            if not t.task_catalog_started
            then []
            else (
              let ids =
                List.concat_map
                  (fun (w : Protocol.v2_change_window) -> w.block_uuids @ w.page_uuids)
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
                    let batch = List.take Protocol.maximum_page_size ids in
                    read
                      t
                      (Task_definitions batch)
                      (Protocol.V2_get_task_status_definitions { statuses = batch })
                    :: batches (List.drop (List.length batch) ids)
                in
                batches ids))
          in
          { requests = (acknowledgement :: hydration.requests) @ catalog_requests
          ; responses = response (Projection_changes windows) :: hydration.responses
          }
        | _ -> failure_output t operation request_id "Unexpected changes response.")
     | V2_changes_acknowledged {generation;through} ->
       (match operation with
        | Acknowledge_changes {continuation;_} ->
          t.change_generation<-Some generation;t.change_cursor<-Some through;
          (match continuation with None->empty|Some request_generation ->
            requests[read t (Pull_changes{request_generation;generation})
              (Protocol.V2_pull_changes{generation;after=Some through;limit=Protocol.maximum_page_size})])
        | _ ->
          failure_output t operation request_id "Unexpected acknowledgement response.")))
;;

let receive_delivery_body t ~read_result ~origin (protocol_response : Protocol.response) =
  let (Protocol.V2_response { request_id; _ }) = protocol_response in
  let key = Graph.Uuid.to_string request_id in
  let pending = Hashtbl.find_opt t.pending key in
  let owned = match pending with
    | Some { delivery = Dispatched; _ } -> true
    | None | Some _ -> false in
  if not owned then (
    report_timeline "runtime-response"
      ["request", `String (Graph.Uuid.to_string request_id); "reason", `String "discard-not-owned"];
    empty) else (
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
      (receive_response t ~read_result ~origin protocol_response)
  in
  let references =
    match pending, protocol_response with
    | _ when not root_current -> empty
    | None, _ | Some { operation = Reference_read _; _ }, _ -> empty
    | Some pending, _ when not (favorite_request_current t pending) -> empty
    | Some { operation = Target_summary summary; _ }, _
      when not (Confirmation.current t.confirmations summary) ->
      empty
    | Some { operation; source_epoch; _ }, Protocol.V2_response { outcome; _ } ->
      let block (value : Protocol.v2_block_record) = Reference.Block value.block in
      let sources =
        match outcome with
        | V2_block_outcome (V2_present_block { value; _ }) -> Rrbvec.singleton (block value)
        | V2_block_outcome (V2_missing_block { uuid; _ }) ->
          Rrbvec.singleton (Reference.Missing_outline uuid)
        | V2_block_summary_outcome
            { lookup = V2_present_block { value; _ }; items; next_cursor = None; _ }
          when List.exists
                 (fun response -> match response.payload with
                    | Block_captured _ | Block_updated _ | Update_conflict _ | Delete_conflict _ -> true | _ -> false)
                 output.responses ->
          let fragment = match operation with
            | Target_summary summary -> Confirmation.reference_fragment summary ~target:value ~final_children:items
            | _ -> Rrbvec.push_front
                (Rrbvec.of_list items |> Rrbvec.map (fun (item:Protocol.v2_child_member)->item.value)) value in
          Rrbvec.map block fragment
        | V2_page_outcome (V2_present_page { page; _ }) ->
          let detail_owner = match operation with
            | Detail_block { block_id; _ } -> block_id = Graph.Uuid.to_string page.uuid
            | Changed_detail_page _ ->
              Hashtbl.mem t.detail_pages (Graph.Uuid.to_string page.uuid)
            | _ -> false in
          Rrbvec.singleton (Reference.Page { page; detail_owner })
        | V2_page_outcome (V2_missing_page { uuid; _ }) ->
          Rrbvec.singleton (Reference.Missing_page uuid)
        | V2_children_outcome { items; _ } ->
          Rrbvec.of_list items |> Rrbvec.map (fun (item : Protocol.v2_child_member) -> block item.value)
        | V2_page_tree_outcome { items; _ } ->
          Rrbvec.of_list items |> Rrbvec.map (fun (item : Protocol.v2_tree_member) -> block item.value)
        | _ -> Rrbvec.empty
      in
      let changes =
        List.fold_left
          (fun changes response -> match response.payload with
            | Block_removed { block_id } | Subtree_deleted { block_id; _ } ->
              Rrbvec.push_back changes Reference.{ id = block_id; text = None; page_kind = false }
            | Favorites_loaded (_, result) ->
              Rrbvec.fold_left
                (fun changes item ->
                  let favorite = Projection.favorite item in
                  let id, page_kind = match favorite.target with
                    | Page id -> id, true | Block id -> id, false in
                  Rrbvec.push_back changes Reference.{ id; text = Some favorite.title; page_kind })
                changes result.items
            | _ -> changes)
          Rrbvec.empty output.responses
      in
      (* Property references are demanded by Detail only. Timeline continues
         reading its bounded tree fragment without property hydration. All
         child titles enter the cache before discovery, avoiding duplicate reads. *)
      let property_blocks =
        match operation, outcome with
        | ( (Detail_children { root; _ } | Changed_children { root; _ })
          , V2_children_outcome { items; _ } ) ->
          Seq.cons
            root.block
            (List.to_seq items
             |> Seq.map (fun (item : Protocol.v2_child_member) -> item.value.block))
        | ( (Changed_detail_block { block_id; _ } | Changed_block { block_id; _ })
          , V2_block_outcome (V2_present_block { value; _ }) )
          when Hashtbl.mem t.detail_pages block_id -> Seq.return value.block
        | Changed_detail_page _, V2_page_outcome (V2_present_page {page;revision})
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
      List.iter (fun (request:Protocol.request) ->
        let key=Graph.Uuid.to_string request.request_id in
        Option.iter (fun pending -> Hashtbl.replace t.pending key {pending with durable=Some durable})
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
      if Graph.Uuid.equal request_id durable.root_request.request_id then
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
         && Option.is_some (Coordination.change_application_error view batch) ->
    dispatch_output
      t
      (requests
         [ read
             t
             (Pull_changes { request_generation; generation = batch.generation })
             (Protocol.V2_pull_changes
                { generation = batch.generation
                ; after = batch.from_exclusive
                ; limit = Protocol.maximum_page_size
                })
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

let receive_delivery t ~read_result ~origin (Protocol.V2_response raw as protocol_response) =
  let token=application_for_request t ~request_id:raw.request_id in
  match token with
  | None->let output=receive_delivery_body t ~read_result ~origin protocol_response in
    notify_projection_changes t output;output
  | Some token ->
    let external_children=match Hashtbl.find_opt t.pending(Graph.Uuid.to_string raw.request_id) with
      | Some pending->pending.external_children|None->Rrbvec.empty in
    let previous=t.application_context and children=ref external_children in
    t.application_context<-Some(token,raw.request_id,children);
    let output=Fun.protect ~finally:(fun()->t.application_context<-previous)
      (fun()->let output=receive_delivery_body t ~read_result ~origin protocol_response in
        notify_projection_changes t output;output) in
    t.on_change(Coordination.Change_consumer_expanded(token,raw.request_id,!children));
    let error=match raw.outcome with
      | Protocol.V2_failed{code;message}->Some(Worker.Service_failed(code^": "^message))
      | V2_resync_required{reason;_}->Some(Worker.Resync_required reason)
      | _->List.find_map response_application_error output.responses in
    Option.iter(fun error->t.on_change(Coordination.Change_consumer_applied(token,raw.request_id,Error error))) error;
    output
;;

(* Route accepted Worker terminal failures through the same owner as protocol
   failures. This removes pending/active markers and drains queued hydration;
   a later completion for the request is then unowned and ignored. *)
let receive t response = receive_delivery t ~read_result:None ~origin:None response

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
  | _ ->
  let outcome =
    match result with
    | Changes_resync _ | Changes_retired -> Protocol.V2_failed
      {code="invalidRequest";message="The change continuation was retired"}
    | Changes_read batch -> Protocol.V2_changes{generation=batch.generation;from_exclusive=batch.from_exclusive;
      through=batch.through;windows=batch.windows;next=batch.next}
    | Changes_acknowledged ack -> Protocol.V2_changes_acknowledged
      {generation=Worker.change_ack_generation ack;through=Worker.change_ack_through ack}
    | Ordinary_read outcome -> outcome
    | Root_tree_read {page;value} -> Protocol.V2_page_tree_outcome
        {page;maximum_depth=0;items=value.items;next_cursor=None}
    | Child_members_read value ->
      Protocol.V2_children_outcome
        { parent = value.parent
        ; revision_scope = value.revision_scope
        ; scope_revision = value.scope_revision
        ; items = value.items
        ; next_cursor = None
        }
    | Journals_read value ->
      Protocol.V2_journals_outcome { items = value.items; next_cursor = None }
    | Child_chain_summary value | Target_summary_read value ->
      Protocol.V2_block_summary_outcome
        { lookup = value.lookup
        ; page = value.page
        ; items = value.items
        ; next_cursor = None
        ; scope_revision = value.scope_revision
        ; generation = value.generation
        ; projection_revision = value.projection_revision
        }
    | Task_catalog_read value ->
      Protocol.V2_task_statuses_outcome
        { property_uuid = value.property_uuid
        ; default_status = value.default_status
        ; items = value.items
        ; next_cursor = None
        }
    | Favorites_read { value; _ } ->
      Protocol.V2_favorites_outcome
        { favorites_page = value.favorites_page
        ; generation = value.generation
        ; projection_revision = value.projection_revision
        ; items = Rrbvec.to_list value.items
        ; next_cursor = None
        }
  in
  receive_delivery
    t
    ~read_result:(Some result)
    ~origin
    (Protocol.V2_response { api_version = Protocol.api_version; request_id; outcome })
;;

let worker_mutation t (request:Protocol.request) =
  match Hashtbl.find_opt t.pending(Graph.Uuid.to_string request.request_id),request.command with
  | Some {operation=Child_insert _;delivery=Dispatched;_},
    Protocol.V2_insert_blocks{mutation_id;parent;roots;preconditions}->
      Some(mutation_id,Worker.Insert_blocks{parent;roots;preconditions})
  | Some {operation=Child_write{root;index;_};delivery=Dispatched;_},_ ->
    Option.map(fun(_,chain,_)->let stage=Child.stage chain index in
      Child.stage_id stage,Child.stage_mutation stage)(child_root t root)
  | Some {operation=Mutation_refresh _;delivery=Dispatched;_},
    Protocol.V2_set_task_status{mutation_id;block;status;preconditions}->
      Some(mutation_id,Worker.Set_task_status{block;status;preconditions})
  | Some {operation=Mutation_refresh _;delivery=Dispatched;_},
    Protocol.V2_clear_task_status{mutation_id;block;preconditions}->
      Some(mutation_id,Worker.Clear_task_status{block;preconditions})
  | Some {operation=Delete_mutation _;delivery=Dispatched;_},
    Protocol.V2_delete_blocks{mutation_id;root;preconditions}->
      Some(mutation_id,Worker.Delete_blocks{root;preconditions})
  | _->None
;;

let bind_mutation t request ~presentation ~intent =
  let key=Graph.Uuid.to_string request.Protocol.request_id in
  match Hashtbl.find_opt t.pending key with
  | Some ({operation=Child_insert(command,page);delivery=Dispatched;_} as pending) ->
    (match task_status_uuid t command.task_state with
     | Error _->false
     | Ok resolved_status->
       (match Child.start ~command ~page ~resolved_status ~insert:request.Protocol.command with
        | Error _->false
        | Ok(chain,_)->
          (match Child.bind chain ~index:0 ~round:1L ~intent ~presentation with
           | None->false
           | Some chain->Hashtbl.replace t.pending key {pending with operation=Child_chain{chain;projection=None}};true)))
  | Some {operation=Child_write{root;index;round};delivery=Dispatched;_} ->
    (match child_root t root with
     | None->false
     | Some(_,chain,projection)->
       (match Child.bind chain ~index ~round ~intent ~presentation with
        | None->false|Some chain->update_child_root t root chain projection;true))
  | Some pending when pending.delivery=Dispatched ->
    Hashtbl.replace t.pending key {pending with durable=Some{intent;presentation;confirm_readback=true;root_request=request}};true
  | _->false
;;

let mutation_presentation t (request:Protocol.request) =
  Option.bind(Hashtbl.find_opt t.pending(Graph.Uuid.to_string request.request_id))
    (fun pending->Option.map(fun durable->durable.presentation)pending.durable)
;;

let pending_mutation t ~mutation_id =
  Hashtbl.to_seq_values t.pending |> Seq.find_map(fun pending->
    match pending.durable with
    | Some durable when Graph.Uuid.to_string(Worker.mutation_intent_id durable.intent)=mutation_id
        && Graph.Uuid.equal pending.original.request_id durable.root_request.request_id -> Some durable.root_request
    | _->None)
;;

let acknowledge_mutation t intent =
  match pending_mutation t ~mutation_id:(Graph.Uuid.to_string(Worker.mutation_intent_id intent)) with
  | Some request->Hashtbl.remove t.pending(Graph.Uuid.to_string request.request_id)
  | None->()
;;

let mutation_waiting t (request:Protocol.request) message =
  match Hashtbl.find_opt t.pending(Graph.Uuid.to_string request.request_id) with
  | Some {operation=Child_chain _;_} ->
    child_step t request.request_id(fun chain->Child.interrupted chain ~index:0 ~round:1L message)
  | Some {operation=(Child_write{root;index;round}|Child_ack{root;index;round;_});_} ->
    child_step t root(fun chain->Child.interrupted chain ~index ~round message)
  | Some {failure_owner=Some(Mutation_owner{mutation_id;block_id;_});_}->
    responses[response(Mutation_waiting{mutation_id;block_id;message})]
  | _->empty
;;

let receive_mutation t (request:Protocol.request) progress =
  let key=Graph.Uuid.to_string request.request_id in
  match Hashtbl.find_opt t.pending key with
  | Some {operation=Child_chain _;_} ->
    dispatch_output t (child_step t request.request_id (fun chain->Child.receive chain ~index:0 ~round:1L progress))
  | Some {operation=(Child_write{root;index;round}|Child_ack{root;index;round;_});_} ->
    Hashtbl.remove t.pending key;
    dispatch_output t (child_step t root (fun chain->Child.receive chain ~index ~round progress))
  | Some ({durable=Some durable;operation=(Mutation_refresh _ | Delete_mutation _);_} as pending) ->
    (match progress with
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
             let child=Graph.Uuid.to_string first.request_id in
             Option.iter(fun pending->Hashtbl.replace t.pending child {pending with durable=Some durable})
               (Hashtbl.find_opt t.pending child);
             let planned=dispatch_output t planned in
             let output=receive_worker_read t ~request_id:first.request_id(Target_summary_read summary) in
             {output with requests=List.filter(fun (value:Protocol.request)->value.request_id<>first.request_id)planned.requests @ output.requests}
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
       let code,message=match error with Worker.Db_error error->Error.code error,Error.message error
         | Service_failed message->Error.Invalid_request,message
         | _->Error.Invalid_request,"The change was rejected." in
       let output=receive t (Protocol.V2_response{api_version=Protocol.api_version;request_id=request.request_id;
         outcome=V2_failed{code=Error.code_string code;message}}) in
       Hashtbl.replace t.pending key {pending with durable=Some durable};
       List.iter(fun (request:Protocol.request)->let key=Graph.Uuid.to_string request.request_id in
         Option.iter(fun pending->Hashtbl.replace t.pending key {pending with durable=Some durable})
           (Hashtbl.find_opt t.pending key))output.requests;
       {output with responses=List.map(fun value->{payload=Mutation_settled(durable.intent,durable.presentation,value.payload)})output.responses}
     | Confirmed _ | Outcome_unknown | Committed_pending_presentation _ ->
       mutation_waiting t request "The change is awaiting confirmation. Retry checks the same change.")
  | _->empty
;;

let worker_child_ack t (request:Protocol.request) =
  match Hashtbl.find_opt t.pending(Graph.Uuid.to_string request.request_id) with
  | Some{operation=Child_ack{intent;presentation;_};delivery=Dispatched;_}->Some(intent,presentation)
  | _->None
;;
let rebind_child_ack t (request:Protocol.request) ~presentation =
  match Hashtbl.find_opt t.pending(Graph.Uuid.to_string request.request_id) with
  | Some{operation=Child_ack{root;index;round;intent;_};delivery=Dispatched;_}->
    (match child_root t root with None->false|Some(_,chain,projection)->
      match Child.rebind_ack chain ~index ~round ~intent ~presentation with
      | None->false|Some chain->update_child_root t root chain projection;true)
  | _->false
;;
let receive_child_ack t (request:Protocol.request) result =
  let key=Graph.Uuid.to_string request.request_id in
  match Hashtbl.find_opt t.pending key with
  | Some{operation=Child_ack{root;index;round;_};_}->
    Hashtbl.remove t.pending key;
    dispatch_output t (child_step t root(fun chain->Child.acknowledged chain ~index ~round result))
  | _->empty
;;
let child_projection_applied t ~root ~round ~presentation =
  dispatch_output t (child_step t root(fun chain->Child.applied chain ~round presentation))
;;

let fail_request t (request : Protocol.request) ~message =
  match Hashtbl.find_opt t.pending(Graph.Uuid.to_string request.request_id) with
  | Some{operation=(Child_chain _|Child_write _|Child_ack _);_}->mutation_waiting t request message
  | _->receive
    t
    (Protocol.V2_response
       { api_version = Protocol.api_version
       ; request_id = request.request_id
       ; outcome =
           Protocol.V2_failed { code = Error.code_string Error.Closed_session; message }
       })
;;

let abandon t (request : Protocol.request) =
  let key = Graph.Uuid.to_string request.request_id in
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

let reconcile_push t ~request_generation push =
  (match push with
   | Protocol.V2_changes_available { generation; through; _ } ->
     report_timeline "runtime-change-window"
       [ "phase", `String "push"; "generation", timeline_version generation
       ; "through", timeline_version through
       ; "requestGeneration", `String (Int64.to_string request_generation)
       ]
   | V2_resync_required_push { generation; _ } ->
     report_timeline "runtime-change-window"
       [ "phase", `String "resync"; "generation", timeline_version generation
       ; "requestGeneration", `String (Int64.to_string request_generation)
       ]);
  let output =
    match push with
    | Protocol.V2_changes_available { generation; _ } ->
      let after =
        match t.change_generation with
        | Some current when String.equal current generation -> t.change_cursor
        | None | Some _ -> None
      in
      requests
        [ read
            t
            (Pull_changes { request_generation; generation })
            (Protocol.V2_pull_changes { generation; after; limit = 256 })
        ]
    | V2_resync_required_push { generation; _ } ->
      rehydrate_current_interests t ~request_generation ~generation
  in
  dispatch_output t output
;;

module Copy = Journal_copy

type worker_read =
  | Confirm_readback of {intent:Worker.mutation_intent;presentation:Worker.presentation}
  | Read :
      { query : 'a Worker.query
      ; maximum_items : int
      ; outcome : 'a -> worker_read_result
      }
      -> worker_read
  | Acknowledge : {batch:Worker.change_batch;outcome:Worker.change_ack -> worker_read_result} -> worker_read
  | Unowned_read of string

let worker_read t (request : Protocol.request) =
  let confirmation=match Hashtbl.find_opt t.pending(Graph.Uuid.to_string request.request_id) with
    | Some {operation=Target_summary summary;durable=Some durable;_}
      when durable.confirm_readback && (match Confirmation.worker_query summary with Worker.Block_summary{after=None;_}->true|_->false) ->
      Some(Confirm_readback{intent=durable.intent;presentation=durable.presentation})
    | _->None in
  match confirmation with Some _->confirmation|None->
  match request.command with
  | V2_pull_changes {generation;after;limit} ->
    (match Hashtbl.find_opt t.pending(Graph.Uuid.to_string request.request_id) with
     | Some{operation=Pull_changes _;delivery=Dispatched;_}->Some(Read
       {query=Worker.Changes{generation;after};maximum_items=limit;outcome=(fun batch->Changes_read batch)})
     | _->Some(Unowned_read "Changefeed pull is no longer owned by its business request"))
  | V2_ack_changes _ ->
    (match Hashtbl.find_opt t.pending(Graph.Uuid.to_string request.request_id) with
     | Some{operation=Acknowledge_changes{batch=Some batch;_};delivery=Dispatched;_}->
       Some(Acknowledge{batch;outcome=(fun ack->Changes_acknowledged ack)})
     | Some{operation=Acknowledge_changes{batch=None;_};delivery=Dispatched;_}->None
     | _->Some(Unowned_read "Changefeed ACK is no longer owned by its delivered batch"))
  | V2_graph_info ->
    Some
      (Read
         { query = Worker.Graph_info
         ; maximum_items = 1
         ; outcome =
             (fun (i : Worker.graph_info) ->
               Ordinary_read
                 (Protocol.V2_graph_info_outcome
                    { graph_uuid = i.graph_uuid
                    ; graph_name = i.graph_name
                    ; schema = i.schema
                    ; admission_facts = i.admission_facts
                    ; journal_title_format = i.journal_title_format
                    ; limits = i.limits
                    ; generation = i.generation
                    ; projection_revision = i.projection_revision
                    }))
         })
  | V2_inspect_admission ->
    Some
      (Read
         { query = Worker.Admission
         ; maximum_items = 1
         ; outcome = (fun value -> Ordinary_read (Protocol.V2_admission_outcome value))
         })
  | V2_get_page { page; revision } ->
    Some
      (Read
         { query = Worker.Page { uuid = page; revision }
         ; maximum_items = 1
         ; outcome = (fun value -> Ordinary_read (Protocol.V2_page_outcome value))
         })
  | V2_get_outline_block { block; revision } ->
    Some
      (Read
         { query = Worker.Outline_block { uuid = block; revision }
         ; maximum_items = 1
         ; outcome = (fun value -> Ordinary_read (Protocol.V2_block_outcome value))
         })
  | V2_get_task_status_definitions { statuses } ->
    Some
      (Read
         { query = Worker.Task_status_definitions statuses
         ; maximum_items = max 1 (List.length statuses)
         ; outcome =
             (fun value ->
               Ordinary_read (Protocol.V2_task_status_definitions_outcome value))
         })
  | V2_get_page_tree _ ->
    (match Hashtbl.find_opt t.pending (Graph.Uuid.to_string request.request_id) with
     | Some { operation = Feed_read read; delivery = Dispatched; _ } ->
       (match Feed.tree_request read with
        | Some business ->
          Some
            (Read
               { query =
                   Worker.Tree
                     { page = business.page
                     ; maximum_depth = 0
                     ; revision = None
                     ; after = business.after
                     }
               ; maximum_items = business.maximum_items
               ; outcome = (fun value -> Root_tree_read { page = business.page; value })
               })
        | None -> Some (Unowned_read "Root tree business operation mismatch"))
     | _ -> Some (Unowned_read "Root tree business request is no longer owned"))
  | V2_get_children _ ->
    (match Hashtbl.find_opt t.pending (Graph.Uuid.to_string request.request_id) with
     | Some { operation = Feed_read read; delivery = Dispatched; _ } ->
       (match Feed.child_request read with
        | Some business ->
          Some
            (Read
               { query =
                   Worker.Child_members
                     { parent = business.parent; revision = None; after = business.after }
               ; maximum_items = business.limit
               ; outcome = (fun value -> Child_members_read value)
               })
        | None -> Some (Unowned_read "Child business operation mismatch"))
     | Some { operation = Favorite_read read; delivery = Dispatched; _ } ->
       (match Favorites.membership_query read with
        | Some query ->
          Some
            (Read
               { query
               ; maximum_items = 200
               ; outcome = (fun value -> Child_members_read value)
               })
        | None -> Some (Unowned_read "Favorite child business operation mismatch"))
     | Some
         { operation = Detail_children { root; after; limit; _ }
         ; delivery = Dispatched
         ; _
         } ->
       Some
         (Read
            { query =
                Worker.Child_members
                  { parent = root.block.uuid
                  ; revision = None
                  ; after =
                      Option.map
                        (fun (value : Projection.child_cursor) -> value.after)
                        after
                  }
            ; maximum_items = limit
            ; outcome = (fun value -> Child_members_read value)
            })
     | Some { operation = Changed_children interest; delivery = Dispatched; _ } ->
       Some
         (Read
            { query =
                Worker.Child_members
                  { parent = interest.root.block.uuid; revision = None; after = None }
            ; maximum_items = interest.limit
            ; outcome = (fun value -> Child_members_read value)
            })
     | Some { operation = Capture_children { page; _ }; delivery = Dispatched; _ } ->
       Some
         (Read
            { query =
                Worker.Child_members
                  { parent = Graph.Uuid.of_string page.id |> Result.get_ok
                  ; revision = None
                  ; after = None
                  }
            ; maximum_items = Protocol.maximum_page_size
            ; outcome = (fun value -> Child_members_read value)
            })
     | Some _ | None -> Some (Unowned_read "Child business request is no longer owned"))
  | V2_get_outline_block_summary _ ->
    (match Hashtbl.find_opt t.pending (Graph.Uuid.to_string request.request_id) with
     | Some {operation=Child_canonical _;delivery=Dispatched;_}->
       (match request.command with
        | V2_get_outline_block_summary{block;limit;_}->Some(Read
            {query=Worker.Block_summary{block;after=None};maximum_items=limit;
             outcome=(fun value->Child_chain_summary value)})
        | _->Some(Unowned_read "The child snapshot command changed"))
     | Some { operation = Target_summary read; delivery = Dispatched; _ } ->
       Some
         (Read
            { query = Confirmation.worker_query read
            ; maximum_items = Protocol.default_page_size
            ; outcome = (fun value -> Target_summary_read value)
            })
     | _ -> Some (Unowned_read "Target summary business request is no longer owned"))
  | V2_list_journals _ ->
    (match Hashtbl.find_opt t.pending (Graph.Uuid.to_string request.request_id) with
     | Some { operation = Feed_read read; delivery = Dispatched; _ } ->
       (match Feed.journal_request read with
        | Some business ->
          Some
            (Read
               { query =
                   Worker.Journals
                     { from_day = business.from_day
                     ; through_day = business.through_day
                     ; revision = None
                     ; after = business.after
                     }
               ; maximum_items = business.limit
               ; outcome = (fun value -> Journals_read value)
               })
        | None -> Some (Unowned_read "Journal business operation mismatch"))
     | _ -> Some (Unowned_read "Journal business request is no longer owned"))
  | V2_list_task_statuses _ ->
    (match Hashtbl.find_opt t.pending (Graph.Uuid.to_string request.request_id) with
     | Some { operation = Task_catalog { after; _ }; delivery = Dispatched; _ } ->
       Some
         (Read
            { query = Worker.Task_statuses after
            ; maximum_items = Protocol.maximum_page_size
            ; outcome = (fun value -> Task_catalog_read value)
            })
     | _ -> Some (Unowned_read "Task catalog business request is no longer owned"))
  | V2_list_favorites _ ->
    (match Hashtbl.find_opt t.pending (Graph.Uuid.to_string request.request_id) with
     | Some { operation = Favorite_read read; delivery = Dispatched; _ } ->
       (match Favorites.list_request read with
        | None -> None
        | Some business ->
          Some
            (Read
               { query = Worker.Favorites business.cursor
               ; maximum_items = business.limit
               ; outcome =
                   (fun (value : Worker.favorites) ->
                     Favorites_read
                       { first_page = business.cursor = None
                       ; value =
                           { favorites_page = value.favorites_page
                           ; generation = value.generation
                           ; projection_revision = value.projection_revision
                           ; items = Rrbvec.of_list value.items
                           ; next_cursor = value.next
                           }
                       })
               }))
     | _ -> Some (Unowned_read "Favorites business request is no longer owned"))
  | _ -> None
;;
