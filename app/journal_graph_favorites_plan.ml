module Graph = Logseq_db_types.Graph_types
module Protocol = Logseq_db_worker.Protocol
module Error = Logseq_db_worker.Error

type read =
  | List_favorites of Journal_graph_request.favorites_request
  | Favorite_dependency of
      { epoch : int64
      ; uuid : Graph.Uuid.t
      ; seen : string list
      ; page : bool
      }
  | Favorite_page_candidate of Graph.Uuid.t
  | Favorite_memberships of
      { epoch : int64
      ; page : Graph.Uuid.t
      ; consumed : int
      ; seen : string list
      }

type rejection =
  | Projection_rejection of string
  | Worker_rejection of
      { operation : string; request_id : Graph.Uuid.t; error : Error.t }
type event =
  | Favorites_loaded of Journal_graph_request.favorites_request * Protocol.v2_favorites_result
  | Favorites_failed of Journal_graph_request.favorites_request * bool * string
  | Favorites_invalidated
  | Rejected of rejection
type output =
  { requests : Protocol.request Rrbvec.t
  ; responses : event Rrbvec.t
  ; background : bool
  }
type ports =
  { plan_read : read -> Protocol.command -> Protocol.request
  ; remember_page : Graph.page -> unit
  }
type t =
  { mutable favorite_epoch : int64
  ; mutable favorites_initialized : bool
  ; mutable favorites_page : Graph.Uuid.t option
  ; favorite_dependencies : (string, unit) Hashtbl.t
  ; favorite_members : (string, unit) Hashtbl.t
  ; favorite_targets : (string, Protocol.v2_favorite_target) Hashtbl.t
  ; favorite_blocks : (string, Protocol.v2_block_record) Hashtbl.t
  ; favorite_pages : (string, Graph.page) Hashtbl.t
  ; favorite_dirty : (string, unit) Hashtbl.t
  ; favorite_pending : (string, unit) Hashtbl.t
  ; favorite_resolved : (string, unit) Hashtbl.t
  ; favorite_loading_changes : (string, unit) Hashtbl.t
  ; mutable favorite_changes_overflow : bool
  }
let empty = { requests = Rrbvec.empty; responses = Rrbvec.empty; background = false }
let response value = value
let responses values = { empty with responses = Rrbvec.of_list values }
let reject message = responses [ Rejected (Projection_rejection message) ]
let background_demands output = { output with background = true }
let create () =
  { favorite_epoch = 0L
  ; favorites_initialized = false
  ; favorites_page = None
  ; favorite_dependencies = Hashtbl.create 32
  ; favorite_members = Hashtbl.create 32
  ; favorite_targets = Hashtbl.create 32
  ; favorite_blocks = Hashtbl.create 32
  ; favorite_pages = Hashtbl.create 32
  ; favorite_dirty = Hashtbl.create 32
  ; favorite_pending = Hashtbl.create 32
  ; favorite_resolved = Hashtbl.create 32
  ; favorite_loading_changes = Hashtbl.create 32
  ; favorite_changes_overflow = false
  }
let reset t =
  t.favorite_epoch <- Int64.succ t.favorite_epoch;
  t.favorites_initialized <- false;
  t.favorites_page <- None;
  Hashtbl.clear t.favorite_dependencies;
  Hashtbl.clear t.favorite_members;
  Hashtbl.clear t.favorite_targets;
  Hashtbl.clear t.favorite_blocks;
  Hashtbl.clear t.favorite_pages;
  Hashtbl.clear t.favorite_pending;
  Hashtbl.clear t.favorite_dirty;
  Hashtbl.clear t.favorite_resolved;
  Hashtbl.clear t.favorite_loading_changes;
  t.favorite_changes_overflow <- false
;;
let current t = function
  | Favorite_dependency { epoch; _ } | Favorite_memberships { epoch; _ } -> epoch = t.favorite_epoch
  | List_favorites _ | Favorite_page_candidate _ -> true
;;
let is_page_target t id =
  match Hashtbl.find_opt t.favorite_targets id with
  | Some (Protocol.V2_favorite_page _) -> true | _ -> false
;;
let operation_name = function
  | List_favorites _ -> "listFavorites"
  | Favorite_dependency _ -> "readFavoriteDependency"
  | Favorite_page_candidate _ -> "findFavoritePage"
  | Favorite_memberships _ -> "readFavoriteMemberships"
;;
let load ~ports (request : Journal_graph_request.favorites_request) =
  ports.plan_read (List_favorites request)
    (Protocol.V2_list_favorites { limit = request.limit; cursor = request.cursor })
;;
let maximum_reference_targets = 4096
let register_favorite_dependency t uuid =
  let key = Graph.Uuid.to_string uuid in
  if
    (not (Hashtbl.mem t.favorite_dependencies key))
    && Hashtbl.length t.favorite_dependencies >= maximum_reference_targets
  then invalid_arg "Favorite dependencies exceed the bounded read limit.";
  Hashtbl.replace t.favorite_dependencies key ()
;;

let favorite_dependency_read ?(refresh = false) t ~ports ~page ~seen uuid =
  let key = Graph.Uuid.to_string uuid in
  register_favorite_dependency t uuid;
  if Hashtbl.mem t.favorite_pending key
  then (
    if refresh then Hashtbl.replace t.favorite_dirty key ();
    None)
  else if (not refresh) && Hashtbl.mem t.favorite_resolved key
  then None
  else (
    if Hashtbl.length t.favorite_pending >= maximum_reference_targets
    then invalid_arg "Favorite pending reads exceed the bounded read limit.";
    Hashtbl.replace t.favorite_pending key ();
    Some
      (ports.plan_read
         (Favorite_dependency { epoch = t.favorite_epoch; uuid; seen; page })
         (if page
          then Protocol.V2_get_page { page = uuid; revision = None }
          else Protocol.V2_get_outline_block { block = uuid; revision = None })))
;;

let recheck_dirty_favorite_dependency t ~ports ~uuid ~seen ~page =
  let key = Graph.Uuid.to_string uuid in
  Hashtbl.remove t.favorite_dirty key;
  Hashtbl.remove t.favorite_pending key;
  (* The held response predates an owned change. Retire its single slot and
     replace it with a current point read before considering its old snapshot. *)
  background_demands
    { requests =
        (match favorite_dependency_read ~refresh:true t ~ports ~page ~seen uuid with
         | None -> Rrbvec.empty | Some request -> Rrbvec.singleton request)
    ; responses = Rrbvec.empty; background = false
    }
;;

let favorite_deleted (block : Graph.block) =
  List.to_seq block.properties
  |> Seq.filter
    (fun (property : Graph.property_summary) ->
       String.equal property.ident "logseq.property/deleted-at")
  |> Rrbvec.of_seq
;;

let favorite_block_changed
      t
      key
      (before : Protocol.v2_block_record)
      (after : Protocol.v2_block_record)
  =
  before.block.parent <> after.block.parent
  || before.block.page <> after.block.page
  || not (Seq.equal ( = ) (Rrbvec.to_seq (favorite_deleted before.block))
            (Rrbvec.to_seq (favorite_deleted after.block)))
  || (Hashtbl.mem t.favorite_targets key
      && (before.block.title <> after.block.title
          || before.task_status <> after.task_status))
;;

let favorite_dependency_changed t uuid =
  Hashtbl.mem t.favorite_loading_changes (Graph.Uuid.to_string uuid)
;;

let complete_favorite_dependency_key t key output =
  Hashtbl.remove t.favorite_pending key;
  Hashtbl.remove t.favorite_dirty key;
  Hashtbl.replace t.favorite_resolved key ();
  if Hashtbl.length t.favorite_pending = 0
  then (
    Hashtbl.clear t.favorite_loading_changes;
    let overflow = t.favorite_changes_overflow in
    t.favorite_changes_overflow <- false;
    if overflow
    then { output with responses = Rrbvec.push_front output.responses (response Favorites_invalidated) }
    else output)
  else output
;;

let complete_favorite_dependency t uuid output =
  complete_favorite_dependency_key t (Graph.Uuid.to_string uuid) output
;;

let favorite_membership_key uuid = "memberships:" ^ Graph.Uuid.to_string uuid

let changes t ~ports ~blocks ~pages ~structures =
  let membership uuid = Hashtbl.mem t.favorite_members (Graph.Uuid.to_string uuid) in
  let favorites_scope uuid =
    Option.fold ~none:false ~some:(Graph.Uuid.equal uuid) t.favorites_page
  in
  let changed =
    Rrbvec.exists membership blocks
    || Rrbvec.exists favorites_scope pages
    || Rrbvec.exists
         (function
           | Protocol.V2_children_interest parent | V2_page_tree_interest parent ->
             favorites_scope parent
           | V2_journal_index_interest -> false)
         structures
  in
  let rechecks =
    Rrbvec.filter_map
      (fun (uuid, page) ->
         if
           Hashtbl.mem t.favorite_dependencies (Graph.Uuid.to_string uuid)
           && (not (membership uuid))
           && not (favorites_scope uuid)
         then favorite_dependency_read ~refresh:true t ~ports ~page ~seen:[] uuid
         else None)
      (Rrbvec.append (Rrbvec.map (fun uuid -> uuid, false) blocks)
         (Rrbvec.map (fun uuid -> uuid, true) pages))
  in
  if Hashtbl.length t.favorite_pending > 0
  then
    Rrbvec.iter
      (fun uuid ->
         let key = Graph.Uuid.to_string uuid in
         if Hashtbl.length t.favorite_loading_changes < maximum_reference_targets
         then Hashtbl.replace t.favorite_loading_changes key ()
         else t.favorite_changes_overflow <- true)
      (Rrbvec.append blocks pages);
  let candidates =
    if t.favorites_initialized && t.favorites_page = None
    then
      Rrbvec.map
        (fun page ->
           ports.plan_read
         (Favorite_page_candidate page)
             (Protocol.V2_get_page { page; revision = None }))
        pages
    else Rrbvec.empty
  in
  { background = false; requests = Rrbvec.append rechecks candidates
  ; responses = (if changed then Rrbvec.singleton (response Favorites_invalidated) else Rrbvec.empty)
  }
;;


let receive_list t ~ports (request : Journal_graph_request.favorites_request) (result : Protocol.v2_favorites_result) =
          (try
             if request.cursor = None
             then (
               t.favorite_epoch <- Int64.succ t.favorite_epoch;
               Hashtbl.clear t.favorite_dependencies;
               Hashtbl.clear t.favorite_members;
               Hashtbl.clear t.favorite_targets;
               Hashtbl.clear t.favorite_blocks;
               Hashtbl.clear t.favorite_pages;
               Hashtbl.clear t.favorite_pending;
               Hashtbl.clear t.favorite_dirty;
               Hashtbl.clear t.favorite_resolved;
               Hashtbl.clear t.favorite_loading_changes;
               t.favorite_changes_overflow <- false);
             t.favorites_initialized <- true;
             t.favorites_page <- result.favorites_page;
             Option.iter
               (fun uuid -> register_favorite_dependency t uuid)
               result.favorites_page;
             (* Register the complete page before creating any pending reads. A
                limit failure must not leave unscheduled request constructors. *)
             let items = Rrbvec.of_list result.items in
             Rrbvec.iter
               (fun (item : Protocol.v2_favorite_item) ->
                  register_favorite_dependency t item.membership_uuid;
                  match item.target with
                  | V2_favorite_page { uuid; _ } | V2_favorite_block { uuid; _ } ->
                    register_favorite_dependency t uuid)
               items;
             let dependencies =
               Rrbvec.filter_map
                 (fun (item : Protocol.v2_favorite_item) ->
                    register_favorite_dependency t item.membership_uuid;
                    Hashtbl.replace
                      t.favorite_members
                      (Graph.Uuid.to_string item.membership_uuid)
                      ();
                    match item.target with
                    | V2_favorite_page { uuid; _ } ->
                      Hashtbl.replace
                        t.favorite_targets
                        (Graph.Uuid.to_string uuid)
                        item.target;
                      favorite_dependency_read t ~ports
                  ~page:true ~seen:[] uuid
                    | V2_favorite_block { uuid; _ } ->
                      Hashtbl.replace
                        t.favorite_targets
                        (Graph.Uuid.to_string uuid)
                        item.target;
                      favorite_dependency_read t ~ports
                  ~page:false ~seen:[] uuid)
                 items
             in
             let memberships =
               match request.cursor, result.favorites_page with
               | None, Some page ->
                 Hashtbl.replace t.favorite_pending (favorite_membership_key page) ();
                 Rrbvec.singleton (ports.plan_read
                    (Favorite_memberships
                        { epoch = t.favorite_epoch; page; consumed = 0; seen = [] })
                     (Protocol.V2_get_children
                        { parent = page; limit = 200; cursor = None; revision = None })
                 )
               | _ -> Rrbvec.empty
             in
             background_demands
                { background = false; requests = Rrbvec.append dependencies memberships
               ; responses = Rrbvec.singleton (response (Favorites_loaded (request, result)))
               }
           with
           | Invalid_argument message ->
             responses [ response (Favorites_failed (request, false, message)) ])
;;

let receive_page t ~ports operation (lookup : Protocol.v2_page_lookup) =
  match lookup, operation with
        | _, Favorite_dependency { epoch; _ } when epoch <> t.favorite_epoch -> empty
        | _, Favorite_dependency { uuid; seen; page; _ }
          when Hashtbl.mem t.favorite_dirty (Graph.Uuid.to_string uuid) ->
          recheck_dirty_favorite_dependency t ~ports ~uuid ~seen ~page
        | V2_present_page { page; _ }, Favorite_dependency { uuid; page = true; _ } ->
          let key = Graph.Uuid.to_string uuid in
          let changed =
            match Hashtbl.find_opt t.favorite_pages key with
            | Some before ->
              before.recycled <> page.recycled
              || (Hashtbl.mem t.favorite_targets key && before.title <> page.title)
            | None ->
              page.recycled
              ||
                (match Hashtbl.find_opt t.favorite_targets key with
                | Some (V2_favorite_page target) -> target.title <> page.title
                | _ -> false)
          in
          Hashtbl.replace t.favorite_pages key page;
          ports.remember_page page;
          complete_favorite_dependency
            t
            uuid
            (if changed then responses [ response Favorites_invalidated ] else empty)
        | V2_missing_page _, Favorite_dependency { uuid; page = true; _ } ->
          complete_favorite_dependency
            t
            uuid
            (responses [ response Favorites_invalidated ])
        | V2_present_page { page; _ }, Favorite_page_candidate _ ->
          if String.equal page.name "$$$favorites" && not page.recycled
          then responses [ response Favorites_invalidated ]
          else empty
        | V2_missing_page _, Favorite_page_candidate _ -> empty
  | _ -> empty
;;
let accepts_page t = function
  | Favorite_dependency { epoch; page; uuid; _ } ->
    epoch <> t.favorite_epoch || Hashtbl.mem t.favorite_dirty (Graph.Uuid.to_string uuid) || page
  | Favorite_page_candidate _ -> true
  | _ -> false
;;

let receive_block t ~ports operation (lookup : Protocol.v2_block_lookup) =
  match lookup, operation with
        | _, Favorite_dependency { epoch; _ } when epoch <> t.favorite_epoch -> empty
        | _, Favorite_dependency { uuid; seen; page; _ }
          when Hashtbl.mem t.favorite_dirty (Graph.Uuid.to_string uuid) ->
          recheck_dirty_favorite_dependency t ~ports ~uuid ~seen ~page
        | ( V2_present_block { value; _ }
          , Favorite_dependency { uuid; seen; page = false; _ } ) ->
          let key = Graph.Uuid.to_string uuid in
          let parent = value.block.parent in
          if
            (not (Graph.Uuid.equal value.block.uuid uuid))
            || List.length seen >= 256
            || List.mem key seen
            || List.mem (Graph.Uuid.to_string parent) (key :: seen)
          then
            complete_favorite_dependency
              t
              uuid
              (reject "Favorite ancestry is cyclic or exceeds the read limit.")
          else (
            let changed =
              match Hashtbl.find_opt t.favorite_blocks key with
              | Some before -> favorite_block_changed t key before value
              | None ->
                not (Rrbvec.is_empty (favorite_deleted value.block))
                ||
                  (match Hashtbl.find_opt t.favorite_targets key with
                  | Some (V2_favorite_block target) ->
                    target.title <> value.block.title
                    || target.task_status <> value.task_status
                  | _ -> false)
            in
            Hashtbl.replace t.favorite_blocks key value;
            try
              let request =
                favorite_dependency_read t ~ports
                  ~page:(Graph.Uuid.equal parent value.block.page)
                  ~seen:(key :: seen)
                  parent
              in
              let output =
                background_demands
                { background = false; requests = (match request with None -> Rrbvec.empty | Some request -> Rrbvec.singleton request)
                  ; responses =
                      (if changed then Rrbvec.singleton (response Favorites_invalidated) else Rrbvec.empty)
                  }
              in
              complete_favorite_dependency t uuid output
            with
            | Invalid_argument message ->
              complete_favorite_dependency t uuid (reject message))
        | V2_missing_block _, Favorite_dependency { uuid; page = false; _ } ->
          complete_favorite_dependency
            t
            uuid
            (responses [ response Favorites_invalidated ])
  | _ -> empty
;;
let accepts_block t = function
  | Favorite_dependency { epoch; page; uuid; _ } ->
    epoch <> t.favorite_epoch || Hashtbl.mem t.favorite_dirty (Graph.Uuid.to_string uuid) || not page
  | _ -> false
;;

let receive_memberships t ~ports operation items next_cursor =
  let items = Rrbvec.of_list items in
  match operation with
        | Favorite_memberships { epoch; _ } when epoch <> t.favorite_epoch -> empty
        | Favorite_memberships { epoch; page; consumed; seen } ->
          if Rrbvec.length items > 200 || consumed + Rrbvec.length items > 10_000
          then
            complete_favorite_dependency_key
              t
              (favorite_membership_key page)
              (reject "Favorite memberships exceed the bounded read limit.")
          else (
            try
              Rrbvec.iter
                (fun (item : Protocol.v2_child_member) ->
                   register_favorite_dependency t item.value.block.uuid;
                   Hashtbl.replace
                     t.favorite_members
                     (Graph.Uuid.to_string item.value.block.uuid)
                     ())
                items;
              let changed =
                Rrbvec.exists
                  (fun (item : Protocol.v2_child_member) ->
                     favorite_dependency_changed t item.value.block.uuid)
                  items
              in
              let output =
                if changed then responses [ response Favorites_invalidated ] else empty
              in
              match next_cursor with
              | None ->
                complete_favorite_dependency_key t (favorite_membership_key page) output
              | Some cursor ->
                let key = Graph.Cursor.to_string cursor in
                if
                  List.mem key seen
                  || List.length seen >= 128
                  || consumed + Rrbvec.length items >= 10_000
                then
                  complete_favorite_dependency_key
                    t
                    (favorite_membership_key page)
                    (reject "Favorite membership cursor exceeds the bounded read limit.")
                else
                  background_demands
                { output with
                      requests =
                        Rrbvec.singleton (ports.plan_read
                    (Favorite_memberships
                               { epoch
                               ; page
                               ; consumed = consumed + Rrbvec.length items
                               ; seen = key :: seen
                               })
                            (Protocol.V2_get_children
                               { parent = page
                               ; limit = 200
                               ; cursor = Some cursor
                               ; revision = None
                               })
                        )
                    }
            with
            | Invalid_argument message ->
              complete_favorite_dependency_key
                t
                (favorite_membership_key page)
                (reject message))
  | _ -> empty
;;
let accepts_memberships = function Favorite_memberships _ -> true | _ -> false
let accepts_list = function List_favorites _ -> true | _ -> false
let receive_list t ~ports operation result =
  match operation with List_favorites request -> receive_list t ~ports request result | _ -> empty
let fail t operation ~request_id ~code ~message ~error =
  let rejected () = responses [ Rejected (Worker_rejection
    { operation = operation_name operation; request_id; error }) ] in
  match operation with
  | List_favorites request -> responses [Favorites_failed (request, code = Error.Stale_read_cursor, message)]
  | Favorite_dependency {epoch;uuid;_} ->
    if epoch <> t.favorite_epoch then empty else complete_favorite_dependency t uuid (rejected ())
  | Favorite_memberships {epoch;page;_} ->
    if epoch <> t.favorite_epoch then empty else
      complete_favorite_dependency_key t (favorite_membership_key page) (rejected ())
  | Favorite_page_candidate _ -> rejected ()
;;
