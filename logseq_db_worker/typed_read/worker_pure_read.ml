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

type packed_query = Read_query : read_budget * 'a query -> packed_query

type answer = Query_answer : read_budget * 'a query * ('a,error) result -> answer

type (_, _) equality = Refl : ('a, 'a) equality

let query_result_equality : type a b. a query -> b query -> (a, b) equality option =
  fun a b ->
  match a, b with
  | Graph_info, Graph_info -> Some Refl
  | Admission, Admission -> Some Refl
  | Journal _, Journal _ -> Some Refl
  | Journals _, Journals _ -> Some Refl
  | Page _, Page _ -> Some Refl
  | Outline_block _, Outline_block _ -> Some Refl
  | Block_summary _, Block_summary _ -> Some Refl
  | Children _, Children _ -> Some Refl
  | Child_members _, Child_members _ -> Some Refl
  | Tree _, Tree _ -> Some Refl
  | Favorites _, Favorites _ -> Some Refl
  | Task_statuses _, Task_statuses _ -> Some Refl
  | Task_status_definitions _, Task_status_definitions _ -> Some Refl
  | Asset_descriptors _, Asset_descriptors _ -> Some Refl
  | Assets _, Assets _ -> Some Refl
  | Changes _, Changes _ -> Some Refl
  | _ -> None
;;

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
  let pack_query budget query = Read_query(budget,query)
  let answer budget query value = Query_answer(budget,query,value)
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

(* These are encoded query identities and byte accounting, never another
   business command representation. The original typed query reaches its owner. *)
let query_json : type a. read_budget -> a query -> Graph.Cursor.t option -> Yojson.Safe.t =
  fun budget query cursor ->
  let optional encode = function None->`Null|Some value->encode value in
  let text value=`String value and integer value=`Int value in
  let ids values=`List(List.map Uuid.to_yojson values) in
  let revision value=optional text value in
  let cursor=optional Graph.Cursor.to_yojson cursor in
  let page fields=("maximum_items",integer budget.maximum_items)::("cursor",cursor)::fields in
  let kind,fields=match query with
    |Graph_info->"Graph_info",[]
    |Admission->"Admission",[]
    |Journal day->"Journal",["day",integer day]
    |Journals{from_day;through_day;revision=version;_}->"Journals",page["from_day",integer from_day;"through_day",integer through_day;"revision",revision version]
    |Page{uuid;revision=version}->"Page",["uuid",Uuid.to_yojson uuid;"revision",revision version]
    |Outline_block{uuid;revision=version}->"Outline_block",["uuid",Uuid.to_yojson uuid;"revision",revision version]
    |Block_summary{block;_}->"Block_summary",page["block",Uuid.to_yojson block]
    |Children{parent;_}->"Children",page["parent",Uuid.to_yojson parent]
    |Child_members{parent;revision=version;_}->"Child_members",page["parent",Uuid.to_yojson parent;"revision",revision version]
    |Tree{page=root;maximum_depth;revision=version;_}->"Tree",page["page",Uuid.to_yojson root;"maximum_depth",integer maximum_depth;"revision",revision version]
    |Favorites _->"Favorites",page[]
    |Task_statuses _->"Task_statuses",page[]
    |Task_status_definitions statuses->"Task_status_definitions",["statuses",ids statuses]
    |Asset_descriptors assets->"Asset_descriptors",["assets",ids assets]
    |Assets{recursive;roots;_}->"Assets",page["recursive",`Bool recursive;"roots",ids roots]
    |Changes{generation;after}->"Changes",["generation",text generation;"after",revision after;"maximum_items",integer budget.maximum_items]
  in
  `Assoc["query",`List[`String kind;`Assoc fields];"maximum_bytes",integer budget.maximum_bytes]
;;

let query_key budget query = Yojson.Safe.to_string(query_json budget query None)

let query_cursor : type a. session -> read_budget -> a query -> (Graph.Cursor.t option,error)result =
  fun session budget query ->
  let check = function
    |None->Ok None
    |Some next when equal_session session next.owner && next.key=query_key budget query
        && next.budget.maximum_items=budget.maximum_items && next.budget.maximum_bytes=budget.maximum_bytes->Ok(Some next.cursor)
    |Some _->Error(Invalid_input "Continuation does not belong to this query, session and budget") in
  if not(equal_session session budget.owner) then Error Revoked_session else
  match query with
  |Journals{after;_}->check after
  |Block_summary{after;_}->check after
  |Children{after;_}->check after
  |Child_members{after;_}->check after
  |Tree{after;_}->check after
  |Favorites after->check after
  |Task_statuses after->check after
  |Assets{after;_}->check after
  |_->Ok None
;;

let checked_query : type a. session -> read_budget -> a query -> (Graph.Cursor.t option,error)result =
  fun session budget query ->
  let invalid message=Error(Db_error(Logseq_db_worker_contract.Error.create
    ~code:Invalid_request ~message ~details:[] |> Result.get_ok)) in
  let count=match query with Task_status_definitions ids|Asset_descriptors ids->List.length ids|_->1 in
  if not(equal_session session budget.owner) then Error Revoked_session
  else if count>budget.maximum_items then Error(Invalid_input "Lookup exceeds item budget") else
  let valid=match query with
    |Assets{roots;_}->List.compare_length_with roots Data.maximum_filter_values<=0
    |Tree{maximum_depth;_}->maximum_depth>=0 && maximum_depth<=Data.maximum_tree_depth
    |_->true in
  if not valid then invalid "request exceeds domain bounds" else
  Result.bind(query_cursor session budget query)(fun cursor->
    let json=query_json budget query cursor in
    match Logseq_db_types.Json_codec.validate json with
    |Error message->invalid message
    |Ok()->if String.length(Yojson.Safe.to_string json)>Data.maximum_request_bytes
      then invalid "JSON exceeds byte budget" else Ok cursor)
;;

let observable : type a. a query -> bool = function
  |Graph_info|Journal _|Asset_descriptors _|Task_status_definitions _->true
  |Journals{after=None;revision=None;_}|Page{revision=None;_}|Outline_block{revision=None;_}
  |Block_summary{after=None;_}|Children{after=None;_}|Child_members{after=None;revision=None;_}
  |Tree{after=None;revision=None;_}|Favorites None|Task_statuses None|Assets{after=None;_}->true
  |_->false
;;

let validate_query session budget query = Result.map (fun _->()) (checked_query session budget query)

let json_optional encode = function None->`Null|Some value->encode value
let json_list encode values = `List(List.map encode values)
let continuation_json next = json_optional(fun next->Graph.Cursor.to_yojson next.cursor)next
let page_json (value:page)=`Assoc["data",Graph.page_to_yojson value.data;"revision",`String value.revision]
let block_json (value:block)=`Assoc["data",Data.block_record_to_yojson value.data;"revision",`String value.revision]
let slice_json encode (value:'a slice)=`Assoc["items",json_list encode value.items;"next",continuation_json value.next]
let asset_listing_json (value:asset_listing)=`Assoc[
  "generation",`String value.generation;"projection_revision",`String value.projection_revision;
  "items",json_list Logseq_db_types.Asset_descriptor.to_yojson value.items;"next",continuation_json value.next]
let value_json : type a. a query -> a -> Yojson.Safe.t = fun query value->
  match query with
  |Graph_info->`Assoc[
    "graph_uuid",Uuid.to_yojson value.graph_uuid;"graph_name",`String value.graph_name;
    "schema",Graph.schema_version_to_yojson value.schema;"admission_facts",json_list Graph.admission_fact_to_yojson value.admission_facts;
    "journal_title_format",json_optional(fun text->`String text)value.journal_title_format;
    "limits",Data.capability_limits_to_yojson value.limits;"generation",`String value.generation;"projection_revision",`String value.projection_revision]
  |Admission->Data.admission_inspection_to_yojson value
  |Journal _->json_optional page_json value
  |Journals _->slice_json Data.journal_item_to_yojson value
  |Page _->Data.page_lookup_to_yojson value
  |Outline_block _->Data.block_lookup_to_yojson value
  |Block_summary _->`Assoc[
    "lookup",Data.block_lookup_to_yojson value.lookup;"page",json_optional Data.page_lookup_to_yojson value.page;
    "items",json_list Data.child_member_to_yojson value.items;"next",continuation_json value.next;
    "scope_revision",`String value.scope_revision;"generation",`String value.generation;"projection_revision",`String value.projection_revision]
  |Children _->slice_json block_json value
  |Child_members _->`Assoc[
    "parent",Uuid.to_yojson value.parent;"revision_scope",Data.revision_scope_to_yojson value.revision_scope;
    "scope_revision",`String value.scope_revision;"items",json_list Data.child_member_to_yojson value.items;"next",continuation_json value.next]
  |Tree _->slice_json Data.tree_member_to_yojson value
  |Favorites _->`Assoc[
    "favorites_page",json_optional Uuid.to_yojson value.favorites_page;"generation",`String value.generation;
    "projection_revision",`String value.projection_revision;"items",json_list Data.favorite_item_to_yojson value.items;"next",continuation_json value.next]
  |Task_statuses _->`Assoc[
    "property_uuid",json_optional Uuid.to_yojson value.property_uuid;"default_status",json_optional Uuid.to_yojson value.default_status;
    "items",json_list Graph.task_status_definition_to_yojson value.items;"next",continuation_json value.next]
  |Task_status_definitions _->json_list(json_optional Graph.task_status_definition_to_yojson)value
  |Asset_descriptors _->asset_listing_json value
  |Assets _->asset_listing_json value
  |Changes _->`Assoc[
    "generation",`String value.generation;"from_exclusive",json_optional(fun text->`String text)value.from_exclusive;
    "through",`String value.through;"windows",json_list Data.change_window_to_yojson value.windows;"next",json_optional(fun text->`String text)value.next]
;;
let encoded_value_bytes query value = String.length(Yojson.Safe.to_string(value_json query value))

let validate_value : type a. session -> read_budget -> a query -> a -> (unit,error) result =
  fun session budget query value ->
  let count=match query with
    |Journals _->List.length value.items
    |Block_summary _->List.length value.items
    |Children _->List.length value.items
    |Child_members _->List.length value.items
    |Tree _->List.length value.items
    |Favorites _->List.length value.items
    |Task_statuses _->List.length value.items
    |Task_status_definitions _->List.length value
    |Asset_descriptors _->List.length value.items
    |Assets _->List.length value.items
    |Changes _->List.length value.windows
    |_->1 in
  let block_matches uuid = function Data.V2_present_block{value;_}->Uuid.equal uuid value.block.uuid|V2_missing_block{uuid=actual;_}->Uuid.equal uuid actual in
  let page_matches uuid = function Data.V2_present_page{page;_}->Uuid.equal uuid page.uuid|V2_missing_page{uuid=actual;_}->Uuid.equal uuid actual in
  let matches=match query with
    |Graph_info->Uuid.equal session.graph value.graph_uuid
    |Page{uuid;_}->page_matches uuid value
    |Outline_block{uuid;_}->block_matches uuid value
    |Block_summary{block;_}->block_matches block value.lookup
    |Child_members{parent;_}->Uuid.equal parent value.parent && value.revision_scope=Data.V2_children_revision parent
    |Task_status_definitions ids->List.length ids=List.length value
    |Changes{generation;after}->
      let module Seen=Set.Make(String) in
      let rec chain seen previous = function
        |[]->true
        |(window:Data.change_window)::rest->window.id<>"" && window.predecessor<>"" && window.successor<>""
          && not(Seen.mem window.id seen)
          && Option.fold ~none:true ~some:(String.equal window.predecessor) previous
          && chain (Seen.add window.id seen) (Some window.successor) rest in
      let through=match List.rev value.windows with
        |last::_->value.through=last.Data.id
        |[]->Option.fold ~none:(value.through<>"") ~some:(String.equal value.through) after in
      equal_session session value.change_owner && generation<>"" && generation=value.generation
      && after=value.from_exclusive && through && chain Seen.empty None value.windows
      && (match value.next with None->true|Some next->next=value.through && value.windows<>[])
    |_->true in
  if not(equal_session session budget.owner) then Error Revoked_session
  else if count>budget.maximum_items then Error Response_budget_exceeded
  else if not matches then Error(Protocol_mismatch "Response does not match the typed query")
  else let json=value_json query value in
    match Logseq_db_types.Json_codec.validate json with
    |Error _->Error(Protocol_mismatch "The typed query result is not valid JSON data")
    |Ok()->if String.length(Yojson.Safe.to_string json)>budget.maximum_bytes
      then Error Response_budget_exceeded else Ok()
;;

let equal_packed_query left right =
  left==right || match left,right with Read_query(lb,lq),Read_query(rb,rq)->
    equal_session lb.owner rb.owner && lb.maximum_items=rb.maximum_items && lb.maximum_bytes=rb.maximum_bytes
    && match query_cursor lb.owner lb lq,query_cursor rb.owner rb rq with
      |Ok lc,Ok rc->query_json lb lq lc=query_json rb rq rc
      |_->false
;;
