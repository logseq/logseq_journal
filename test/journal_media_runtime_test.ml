module R = Journal_media_runtime
module S = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module A = Logseq_db_types.Asset_descriptor
module G = Logseq_db_types.Graph_types
module P = Logseq_db_worker.Protocol

let check condition message = if not condition then failwith message

let uuid n =
  G.Uuid.of_string (Printf.sprintf "89000000-0000-4000-8000-%012d" n) |> Result.get_ok
;;

let test_equal_media_notices_keep_effects () =
  let sent = Queue.create () in
  let changes = ref [] in
  let runtime =
    R.create
      ~send:(fun ticket request ->
        Queue.add (ticket, request) sent;
        true)
      ~changed:(fun root view -> changes := (root, view) :: !changes)
  in
  R.reset runtime ~graph_generation:(Some 1);
  let root = G.Uuid.to_string (uuid 1) in
  R.root_visible runtime ~root true;
  let ticket, request = Queue.take sent in
  let request_id =
    match request with
    | S.Graph_request query -> query.request_id
    | _ -> failwith "visible root must send its initial metadata query"
  in
  R.receive
    runtime
    (Option.get ticket)
    (Graph_response
       (P.V2_response
          { api_version = 2
          ; request_id
          ; outcome =
              V2_assets_outcome
                { generation = "g"
                ; projection_revision = "p"
                ; items = []
                ; next_cursor = None
                }
          }));
  changes := [];
  for _ = 1 to 10 do
    R.root_visible runtime ~root true
  done;
  check (!changes = []) "duplicate visible roots must not republish an equal view";
  check (Queue.is_empty sent) "duplicate visibility must not query metadata";
  R.root_visible runtime ~root false;
  changes := [];
  R.root_visible runtime ~root false;
  check (!changes = []) "duplicate hidden roots must not republish an equal view";
  R.reset runtime ~graph_generation:(Some 2);
  check
    (List.exists (fun (actual, _) -> actual = root) !changes)
    "graph reset must clear the old root presentation even when it was empty"
;;

let () = test_equal_media_notices_keep_effects ()

let () =
  let sent = Queue.create () in
  let views = Hashtbl.create 2 in
  let changes = ref 0 in
  let runtime =
    R.create
      ~send:(fun ticket request ->
        Queue.add (ticket, request) sent;
        true)
      ~changed:(fun root view ->
        incr changes;
        Hashtbl.replace views root view)
  in
  R.reset runtime ~graph_generation:(Some 1);
  let root = G.Uuid.to_string (uuid 1) in
  R.root_visible runtime ~root true;
  check (not (Queue.is_empty sent)) "visible root must query its rendered assets";
  let token, request = Queue.take sent in
  let query =
    match request with
    | S.Graph_request
        ({ command =
             P.V2_list_assets
               { recursive = false; roots = [ u ]; limit = 16; cursor = None }
         ; _
         } as query)
      when u = uuid 1 -> query
    | _ -> failwith "media query must be direct and bounded"
  in
  let asset =
    A.create
      ~uuid:(uuid 2)
      ~source:
        (Managed
           (Some
              (A.version ~checksum:(String.make 64 'a') ~file_type:"png" |> Result.get_ok)))
      ~current_checksum:None
      ~size:None
      ~dimensions:(Some (100, 50))
    |> Result.get_ok
  in
  R.receive
    runtime
    (Option.get token)
    (Graph_response
       (P.V2_response
          { api_version = 2
          ; request_id = query.request_id
          ; outcome =
              V2_assets_outcome
                { generation = "g"
                ; projection_revision = "p"
                ; items = [ asset ]
                ; next_cursor = None
                }
          }));
  check (Queue.is_empty sent) "metadata alone cannot request binary download";
  check
    (List.length (Hashtbl.find views root).items = 1)
    "metadata reaches native presentation";
  R.asset_visible
    runtime
    ~root
    ~asset:(List.hd (Hashtbl.find views root).items).token
    true;
  let _, request = Queue.take sent in
  let consumer =
    match request with
    | S.Asset_command
        { command =
            Replace_asset_demand { consumer; priority = Foreground; assets = [ _ ] }
        ; _
        } -> consumer
    | _ -> failwith "visible media demand must be foreground"
  in
  let scope : S.asset_scope =
    { account =
        { managed_sync_origin = Uri.of_string "https://sync.example"
        ; user_id = "u"
        ; account_generation = 1
        ; presentation_generation = 1
        ; lifecycle_generation = 1L
        }
    ; graph_id = uuid 3
    ; graph_generation = 1
    }
  in
  let before_waiting = !changes in
  R.notice
    runtime
    scope
    (Asset_availability { consumer; asset = asset.uuid; availability = Queued });
  check
    (!changes = before_waiting)
    "equal waiting availability must not republish the pending presentation";
  R.notice
    runtime
    scope
    (Asset_availability { consumer; asset = asset.uuid; availability = Ready "cached" });
  let token, request = Queue.take sent in
  check
    (match request with
     | S.Acquire_asset_file { handle = "cached"; _ } -> true
     | _ -> false)
    "readiness retains the file";
  R.receive
    runtime
    (Option.get token)
    (Asset_file (Some ("retained", "/cache/image.png")));
  check
    ((List.hd (Hashtbl.find views root).items).presentation
     = Journal_media.File "/cache/image.png")
    "native view receives retained path";
  let before_ready_duplicate = !changes in
  R.notice
    runtime
    scope
    (Asset_availability { consumer; asset = asset.uuid; availability = Ready "cached" });
  check
    (!changes = before_ready_duplicate)
    "duplicate readiness must not republish a retained file";
  check (Queue.is_empty sent) "duplicate readiness must not reacquire the retained file";
  R.reset runtime ~graph_generation:None;
  let requests = Queue.to_seq sent |> List.of_seq |> List.map snd in
  check
    (List.exists
       (function
         | S.Release_asset_file { handle = "retained"; _ } -> true
         | _ -> false)
       requests)
    "navigation reset releases file";
  Queue.clear sent;
  R.reset runtime ~graph_generation:(Some 1);
  let receipt : Logseq_db_worker.import_receipt =
    { operation = uuid 8
    ; graph_generation = 1
    ; scope
    ; target = uuid 1
    ; asset
    ; file_type = "png"
    ; preview = Some ("local-lease", "/staged/import.bin")
    }
  in
  R.imported runtime ~current:true receipt;
  check (Queue.is_empty sent) "explicit import must not query or download";
  check
    (List.exists
       (fun (item : R.item) ->
          item.presentation = Journal_media.File "/staged/import.bin")
       (Hashtbl.find views root).items)
    "imported file appears immediately";
  let before_duplicate = !changes in
  R.imported runtime ~current:true receipt;
  check
    (!changes = before_duplicate)
    "duplicate import must not republish the same file presentation";
  check (Queue.is_empty sent) "duplicate receipt must not release its live lease";
  R.reset runtime ~graph_generation:None;
  check
    (List.exists
       (function
         | _, S.Release_asset_file { handle = "local-lease"; _ } -> true
         | _ -> false)
       (Queue.to_seq sent |> List.of_seq))
    "reset releases staged preview";
  Queue.clear sent;
  R.imported
    runtime
    ~current:false
    { receipt with preview = Some ("late-lease", "/staged/late.bin") };
  check
    (List.exists
       (function
         | _, S.Release_asset_file { handle = "late-lease"; _ } -> true
         | _ -> false)
       (Queue.to_seq sent |> List.of_seq))
    "late import receipt releases its lease"
;;

(* The pure media reducer has no queue admission input; it correctly keeps an
   existing selection. Runtime owns whether a new reference can join that file. *)
let test_preview_reference_when_requests_are_full () =
  let sent = Queue.create () in
  let full = ref false in
  let views = Hashtbl.create 2 in
  let runtime =
    R.create
      ~send:(fun ticket request ->
        if !full
        then false
        else (
          Queue.add (ticket, request) sent;
          true))
      ~changed:(fun root view -> Hashtbl.replace views root view)
  in
  let asset =
    A.create
      ~uuid:(uuid 2)
      ~source:
        (Managed
           (Some
              (A.version ~checksum:(String.make 64 'a') ~file_type:"png" |> Result.get_ok)))
      ~current_checksum:None
      ~size:None
      ~dimensions:None
    |> Result.get_ok
  in
  let scope : S.asset_scope =
    { account =
        { managed_sync_origin = Uri.of_string "https://sync.example"
        ; user_id = "u"
        ; account_generation = 1
        ; presentation_generation = 1
        ; lifecycle_generation = 1L
        }
    ; graph_id = uuid 3
    ; graph_generation = 1
    }
  in
  R.reset runtime ~graph_generation:(Some 1);
  let metadata root =
    R.root_visible ~owner:"row" runtime ~root true;
    let ticket, request = Queue.take sent in
    let request_id =
      match request with
      | S.Graph_request query -> query.request_id
      | _ -> assert false
    in
    R.receive
      runtime
      (Option.get ticket)
      (Graph_response
         (P.V2_response
            { api_version = 2
            ; request_id
            ; outcome =
                V2_assets_outcome
                  { generation = "g"
                  ; projection_revision = "p"
                  ; items = [ asset ]
                  ; next_cursor = None
                  }
            }));
    (List.hd (Hashtbl.find views root).items).token
  in
  let root = G.Uuid.to_string (uuid 1) in
  let token = metadata root in
  R.asset_visible ~owner:"row" runtime ~root ~asset:token true;
  Queue.clear sent;
  R.notice
    runtime
    scope
    (Asset_availability
       { consumer = token; asset = asset.uuid; availability = Ready "cached" });
  let ticket, _ = Queue.take sent in
  R.receive
    runtime
    (Option.get ticket)
    (Asset_file (Some ("preview-file", "/cache/image.png")));
  let pressure_root = G.Uuid.to_string (uuid 4) in
  let pressure_token = metadata pressure_root in
  full := true;
  for _ = 1 to 1100 do
    R.asset_visible runtime ~root:pressure_root ~asset:pressure_token true;
    R.asset_visible runtime ~root:pressure_root ~asset:pressure_token false
  done;
  R.preview_visible runtime ~owner:"row" ~slot:root ~root ~asset:token true;
  R.root_visible ~owner:"row" runtime ~root false;
  check
    ((List.hd (Hashtbl.find views root).items).presentation
     = Journal_media.File "/cache/image.png")
    "a full request queue cannot reject a preview reference to an already acquired file";
  full := false;
  R.pump runtime;
  let release_count () =
    Queue.to_seq sent
    |> Seq.filter (function
      | _, S.Release_asset_file { handle = "preview-file"; _ } -> true
      | _ -> false)
    |> Seq.length
  in
  check (release_count () = 0) "draining pressure must keep the preview file";
  R.preview_visible runtime ~owner:"row" ~slot:root ~root ~asset:token false;
  check (release_count () = 1) "closing the preview releases its file once after pressure";
  R.preview_visible runtime ~owner:"row" ~slot:root ~root ~asset:token false;
  check (release_count () = 1) "duplicate pressure cleanup cannot release again"
;;

let () = test_preview_reference_when_requests_are_full ()
