module Dsl = Sync_dsl.Core
module Graph = Logseq_db_types.Managed_graph
module Uuid = Logseq_db_types.Graph_types.Uuid
module Http_client = Logseq_sync_transport.Http_client
module Http = Logseq_sync_native_transport.Http
module Native = Logseq_sync_native_transport.Http_eio

let ( let* ) = Result.bind

type account =
  { origin : string
  ; account : string
  ; root : string
  }

type service =
  { set_network : Dsl.network_gate -> (unit, Dsl.error) result
  ; close : unit -> (unit, Dsl.error) result
  }

let service ~set_network ~close = { set_network; close }

let protect callback =
  try callback () with
  | Eio.Cancel.Cancelled _ as error -> raise error
  | _ -> Error (Dsl.Unexpected_failure "Account lifecycle callback failed")
;;

let of_core core =
  service ~set_network:(Core.set_network core) ~close:(fun () ->
    try
      Core.close core;
      Ok ()
    with
    | Core.Service.Close_failed { error = Some error; _ } -> Error error
    | Core.Service.Close_failed { error = None; _ } ->
      Error (Dsl.Unexpected_failure "Graph service retirement failed")
    | error -> protect (fun () -> raise error))
;;

type catalog =
  account:account
  -> check_current:(unit -> (unit, Dsl.error) result)
  -> gate:(unit -> Dsl.network_gate)
  -> (Graph.t list, Dsl.error) result

let decode_catalog source =
  let open Yojson.Safe.Util in
  let schema = function
    | `Null -> { Graph.major = 0; minor = 0; exact = false }
    | `String value ->
      let component value =
        match int_of_string_opt value with
        | Some value when value >= 0 -> value
        | _ -> failwith "schema"
      in
      (match String.split_on_char '.' value with
       | [ major ] -> { Graph.major = component major; minor = 0; exact = false }
       | [ major; minor ] ->
         { Graph.major = component major; minor = component minor; exact = true }
       | _ -> failwith "schema")
    | _ -> failwith "schema"
  in
  try
    let rows = Yojson.Safe.from_string source |> member "graphs" |> to_list in
    if List.length rows > 10000 then failwith "catalog capacity";
    let graphs =
      List.filter_map
        (fun row ->
           match member "graph-ready-for-use?" row with
           | `Null | `Bool false -> None
           | `Bool true ->
             let graph_id =
               member "graph-id" row |> to_string |> Uuid.of_string |> Result.get_ok
             in
             let name = member "graph-name" row |> to_string in
             if
               String.length name = 0
               || String.length name > 512
               || (not (String.is_valid_utf_8 name))
               || String.contains name '\000'
             then failwith "name";
             let encrypted =
               match member "graph-e2ee?" row with
               | `Null -> true
               | `Bool value -> value
               | _ -> failwith "encryption"
             in
             Some
               { Graph.graph_id
               ; name
               ; schema = schema (member "schema-version" row)
               ; encrypted
               }
           | _ -> failwith "readiness")
        rows
    in
    Ok graphs
  with
  | _ -> Error (Dsl.Protocol_failure "Invalid graph catalog")
;;

let http_catalog ~backend ~token =
  fun ~account ~check_current ~gate ->
  let* () =
    Http.validate_base_url (Uri.of_string account.origin)
    |> Result.map_error (fun message -> Dsl.Invalid_input message)
  in
  let* epoch =
    match gate () with
    | Dsl.Closed -> Error Dsl.Network_closed
    | Dsl.Open { authorization_epoch } -> Ok authorization_epoch
  in
  let client = Http_client.create ~backend ~token:(token ~account) in
  let admit_network () =
    let* () = check_current () in
    match gate () with
    | Dsl.Open { authorization_epoch } when authorization_epoch = epoch -> Ok ()
    | Dsl.Open _ | Dsl.Closed -> Error Dsl.Network_closed
  in
  let scope = { Http_client.check_current; admit_network } in
  let sent_request = ref None in
  let* response =
    Http_client.perform client ~scope ~epoch ~authenticated:true (fun token ->
      let request =
        Http.catalog
          ~base_url:(Uri.of_string account.origin)
          ~token:(Option.value token ~default:"")
      in
      sent_request := Some request;
      request)
  in
  let* () = admit_network () in
  if response.Native.status = 404
  then Error (Dsl.Protocol_failure "Graph catalog not found")
  else
    let* () =
      Http.validate_response_content_type (Option.get !sent_request) response.headers
      |> Result.map_error (fun message -> Dsl.Protocol_failure message)
    in
    decode_catalog response.body
;;

let native_catalog ~sw ~clock ~network ~authenticator ~deadlines ~token =
  let backend =
    Http_client.native_backend ~sw ~clock ~network ~authenticator ~deadlines
  in
  http_catalog ~backend ~token
;;

type entry =
  { graph : Graph.t
  ; service : service
  ; live : bool ref
  }

type owner =
  { account : account
  ; generation : int64
  ; database : Sqlite3.db
  ; upload_store : Logseq_sync_worker_owner.Core.store
  ; mutable active : bool
  ; mutable entries : entry list
  }

type t =
  { maximum_services : int
  ; fetch : catalog
  ; start :
      account:account
      -> account_generation:int64
      -> graph_generation:int64
      -> graph:Graph.t
      -> upload_store:Logseq_sync_worker_owner.Core.store
      -> network:Dsl.network_gate
      -> on_change:(Core.Service.status -> unit)
      -> (service, Dsl.error) result
  ; remove : account:account -> graph:Graph.t -> (unit, Dsl.error) result
  ; on_change : Graph.t -> Core.Service.status -> unit
  ; mutable owner : owner option
  ; mutable generation : int64
  ; mutable next_graph : int64
  ; mutable request : int64
  ; mutable network_revision : int64
  ; mutable network : Dsl.network_gate
  ; mutable graphs : Graph.t list
  ; mutable selected : Uuid.t option
  ; mutable busy : bool
  }

let create ~maximum_services ~catalog ~start ~delete_local ~on_change =
  if maximum_services <= 0
  then Error (Dsl.Invalid_input "Service capacity must be positive")
  else
    Ok
      { maximum_services
      ; fetch = catalog
      ; start
      ; remove = delete_local
      ; on_change
      ; owner = None
      ; generation = 0L
      ; next_graph = 0L
      ; request = 0L
      ; network_revision = 0L
      ; network = Dsl.Closed
      ; graphs = []
      ; selected = None
      ; busy = false
      }
;;

let mutate t callback =
  if t.busy
  then Error (Dsl.Capacity_exceeded "Account lifecycle mutation in progress")
  else (
    t.busy <- true;
    Fun.protect ~finally:(fun () -> t.busy <- false) (fun () -> protect callback))
;;

let current t =
  match t.owner with
  | Some owner when owner.active -> Ok owner
  | Some _ | None -> Error Dsl.Stale_context
;;

let close_entry entry =
  entry.live := false;
  protect entry.service.close
;;

let retire t =
  t.generation <- Int64.succ t.generation;
  t.request <- Int64.succ t.request;
  t.graphs <- [];
  t.selected <- None;
  match t.owner with
  | None -> Ok ()
  | Some owner ->
    owner.active <- false;
    List.iter (fun entry -> entry.live := false) owner.entries;
    let rec close = function
      | [] -> Ok ()
      | entry :: rest ->
        let* () = close_entry entry in
        owner.entries <- rest;
        close rest
    in
    let* () = close owner.entries in
    if Sqlite3.db_close owner.database
    then (
      t.owner <- None;
      Ok ())
    else Error (Dsl.Storage_failure "Upload store is still busy")
;;

let logout t = mutate t (fun () -> retire t)

let replace t account =
  mutate t (fun () ->
    let* _ =
      Dsl.identity
        ~origin:account.origin
        ~account:account.account
        ~graph:"account"
        ~account_generation:0L
        ~graph_generation:0L
    in
    if Filename.is_relative account.root || not (Sys.is_directory account.root)
    then Error (Dsl.Invalid_input "Account root must be an existing absolute directory")
    else
      let* () = retire t in
      let database =
        Sqlite3.db_open (Filename.concat account.root "asset-upload-intents.sqlite")
      in
      match Logseq_db_storage.Asset_upload_store.initialize_database database with
      | Error message ->
        ignore (Sqlite3.db_close database);
        Error (Dsl.Storage_failure message)
      | Ok () ->
        t.network <- Dsl.Closed;
        t.owner
        <- Some
             { account
             ; generation = t.generation
             ; database
             ; upload_store = Logseq_sync_worker_owner.Core.store database
             ; active = true
             ; entries = []
             };
        Ok ())
;;

let catalog t = t.graphs
let selected t = t.selected

let service_count t =
  match t.owner with
  | None -> 0
  | Some owner -> List.length owner.entries
;;

let refresh t =
  let* owner = current t in
  t.request <- Int64.succ t.request;
  let request = t.request in
  let network_revision = t.network_revision in
  let check_current () =
    if
      owner.active
      && t.generation = owner.generation
      && t.request = request
      && t.network_revision = network_revision
    then Ok ()
    else Error Dsl.Stale_context
  in
  let result =
    protect (fun () ->
      t.fetch ~account:owner.account ~check_current ~gate:(fun () -> t.network))
  in
  let* () = check_current () in
  let* () = if t.busy then Error Dsl.Stale_context else Ok () in
  let* graphs = result in
  let ids = List.map (fun graph -> graph.Graph.graph_id) graphs in
  if List.length (List.sort_uniq compare ids) <> List.length ids
  then Error (Dsl.Protocol_failure "Duplicate catalog graph")
  else (
    t.graphs <- graphs;
    if not (Option.fold ~none:true ~some:(fun id -> List.mem id ids) t.selected)
    then t.selected <- None;
    Ok graphs)
;;

let restore_catalog t graphs =
  mutate t (fun () ->
    let* _ = current t in
    let ids = List.map (fun graph -> graph.Graph.graph_id) graphs in
    if List.length ids > 10000 || List.length (List.sort_uniq compare ids) <> List.length ids
    then Error (Dsl.Protocol_failure "Invalid local catalog")
    else (t.graphs <- graphs; Ok ()))
;;

let release_graph t id =
  mutate t (fun () ->
    let* owner = current t in
    match List.find_opt (fun entry -> entry.graph.Graph.graph_id = id) owner.entries with
    | None -> Ok ()
    | Some entry ->
      let* () = close_entry entry in
      owner.entries <- List.filter (fun current -> current != entry) owner.entries;
      if t.selected = Some id then t.selected <- None;
      Ok ())
;;

let find_graph t id =
  match List.find_opt (fun graph -> graph.Graph.graph_id = id) t.graphs with
  | None -> Error (Dsl.Invalid_input "Graph is not in the current catalog")
  | Some graph -> Ok graph
;;

let select t id =
  mutate t (fun () ->
    let* owner = current t in
    let* graph = find_graph t id in
    match List.find_opt (fun entry -> entry.graph.Graph.graph_id = id) owner.entries with
    | Some entry when !(entry.live) ->
      t.selected <- Some id;
      Ok ()
    | Some _ -> Error Dsl.Stale_context
    | None ->
      let* () =
        if List.length owner.entries < t.maximum_services
        then Ok ()
        else (
          let oldest = List.hd (List.rev owner.entries) in
          if t.selected = Some oldest.graph.Graph.graph_id then t.selected <- None;
          let* () = close_entry oldest in
          owner.entries <- List.filter (fun entry -> entry != oldest) owner.entries;
          Ok ())
      in
      let live = ref true in
      let admitted = ref false in
      let pending = ref None in
      let on_change status =
        if !live && owner.active && t.generation = owner.generation
        then
          if not !admitted
          then pending := Some status
          else if t.selected = Some id
          then t.on_change graph status
      in
      t.next_graph <- Int64.succ t.next_graph;
      let result =
        protect (fun () ->
          t.start
            ~account:owner.account
            ~account_generation:owner.generation
            ~graph_generation:t.next_graph
            ~graph
            ~upload_store:owner.upload_store
            ~network:t.network
            ~on_change)
      in
      let* service =
        match result with
        | Ok service -> Ok service
        | Error _ as error ->
          live := false;
          error
      in
      owner.entries <- { graph; service; live } :: owner.entries;
      t.selected <- Some id;
      admitted := true;
      Option.iter on_change !pending;
      Ok ())
;;

let deselect t =
  mutate t (fun () ->
    t.selected <- None;
    Ok ())
;;

let set_network t network =
  mutate t (fun () ->
    let* owner = current t in
    t.network <- network;
    t.network_revision <- Int64.succ t.network_revision;
    let results =
      List.map
        (fun entry ->
           if !(entry.live)
           then protect (fun () -> entry.service.set_network network)
           else Ok ())
        owner.entries
    in
    List.fold_left
      (fun result next ->
         match result with
         | Error _ -> result
         | Ok () -> next)
      (Ok ())
      results)
;;

let delete_local t id =
  mutate t (fun () ->
    let* owner = current t in
    let* graph = find_graph t id in
    if t.selected = Some id then t.selected <- None;
    t.request <- Int64.succ t.request;
    let* () =
      match
        List.find_opt (fun entry -> entry.graph.Graph.graph_id = id) owner.entries
      with
      | None -> Ok ()
      | Some entry ->
        let* () = close_entry entry in
        owner.entries
        <- List.filter (fun entry -> entry.graph.Graph.graph_id <> id) owner.entries;
        Ok ()
    in
    let* () = t.remove ~account:owner.account ~graph in
    t.graphs <- List.filter (fun graph -> graph.Graph.graph_id <> id) t.graphs;
    Ok ())
;;
