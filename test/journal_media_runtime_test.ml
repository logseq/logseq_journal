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

(* Runtime owns metadata query admission, cursor lifetime, and presentation
   references; the pure file reducer cannot reproduce these transitions. *)
let fixture () =
  let sent = Queue.create () in
  let views = Hashtbl.create 64 in
  let admitted = ref true in
  let runtime =
    R.create
      ~send:(fun ticket request ->
        if !admitted
        then (
          Queue.add (ticket, request) sent;
          true)
        else false)
      ~changed:(fun root view -> Hashtbl.replace views root view)
  in
  R.reset runtime ~graph_generation:(Some 1);
  runtime, sent, views, admitted
;;

let metadata_requests sent =
  Queue.to_seq sent
  |> List.of_seq
  |> List.filter (function
    | _, S.Graph_request _ -> true
    | _ -> false)
;;

let take_metadata sent =
  let rec take () =
    match Queue.take sent with
    | Some ticket, S.Graph_request query -> ticket, query.request_id, query.command
    | _ -> take ()
  in
  take ()
;;

let reply runtime (ticket, request_id, _) ?next_cursor items =
  R.receive
    runtime
    ticket
    (S.Graph_response
       (P.V2_response
          { api_version = 2
          ; request_id
          ; outcome =
              V2_assets_outcome
                { generation = "g"; projection_revision = "p"; items; next_cursor }
          }))
;;

let media_asset n =
  A.create
    ~uuid:(uuid n)
    ~source:(Managed None)
    ~current_checksum:None
    ~size:None
    ~dimensions:None
  |> Result.get_ok
;;

let loaded runtime sent root items =
  R.root_visible runtime ~root true;
  reply runtime (take_metadata sent) items
;;

let first_page = function
  | P.V2_list_assets { cursor = None; recursive = false; limit = 16; _ } -> true
  | _ -> false
;;

let scale_hidden () =
  let runtime, sent, _, _ = fixture () in
  for n = 1 to 64 do
    let root = G.Uuid.to_string (uuid n) in
    loaded runtime sent root [];
    if n > 2 then R.root_visible runtime ~root false
  done;
  Queue.clear sent;
  R.refresh runtime;
  Printf.printf
    "COUNT F2 media retained=64 active=2 invalidation_reads=%d\n%!"
    (List.length (metadata_requests sent));
  check
    (List.length (metadata_requests sent) = 2)
    "64 retained empty roots with two active must produce two reads, not 64";
  for _ = 1 to 32 do
    R.refresh runtime
  done;
  Printf.printf
    "COUNT F2 media 32 additional invalidations pending_reads=%d\n%!"
    (List.length (metadata_requests sent));
  check
    (List.length (metadata_requests sent) = 2)
    "32 refreshes cannot replace two in-flight metadata owners"
;;

let pending_followup terminal () =
  let runtime, sent, views, _ = fixture () in
  let root = G.Uuid.to_string (uuid 1) in
  loaded runtime sent root [ media_asset 2 ];
  Queue.clear sent;
  R.refresh runtime;
  let old = take_metadata sent in
  for _ = 1 to 32 do
    R.refresh runtime
  done;
  check (Queue.is_empty sent) "dirty refresh must coalesce behind the current read";
  if terminal
  then reply runtime old [ media_asset 3 ]
  else
    R.reject
      runtime
      (let t, _, _ = old in
       t);
  check
    ((List.hd (Hashtbl.find views root).items).asset.uuid = uuid 2)
    "superseded success/failure must preserve the last accepted view";
  check
    (List.length (metadata_requests sent) = 1)
    "one terminal response must release the owner and issue one fresh follow-up";
  let fresh = take_metadata sent in
  let _, _, command = fresh in
  check (first_page command) "follow-up must clear projection-bound cursor";
  reply runtime fresh [ media_asset 4 ];
  R.reject
    runtime
    (let t, _, _ = old in
     t);
  check
    ((List.hd (Hashtbl.find views root).items).asset.uuid = uuid 4)
    "duplicate old terminal cannot reject a newer accepted view";
  check (Queue.is_empty sent) "duplicate terminal cannot cause a retry loop"
;;

let hidden_dirty activation () =
  let runtime, sent, views, _ = fixture () in
  let root = G.Uuid.to_string (uuid 1) in
  let next = G.Cursor.of_string "projection-bound" |> Result.get_ok in
  R.root_visible runtime ~root true;
  reply runtime (take_metadata sent) ~next_cursor:next [ media_asset 2 ];
  let token = (List.hd (Hashtbl.find views root).items).token in
  R.root_visible runtime ~root false;
  Queue.clear sent;
  R.refresh runtime;
  check (Queue.is_empty sent) "hidden dirty root must not read metadata";
  (match activation with
   | `Root -> R.root_visible runtime ~root true
   | `Asset -> R.asset_visible runtime ~root ~asset:token true
   | `Next -> R.next runtime ~root);
  let _, _, command = take_metadata sent in
  check (first_page command) "activation/next must restart dirty metadata at first page"
;;

let hidden_pending () =
  let runtime, sent, _, _ = fixture () in
  let root = G.Uuid.to_string (uuid 1) in
  R.root_visible runtime ~root true;
  let old = take_metadata sent in
  R.root_visible runtime ~root false;
  R.refresh runtime;
  check (Queue.is_empty sent) "hidden pending group cannot receive another read";
  reply runtime old [];
  check (Queue.is_empty sent) "hidden old terminal cannot restart enumeration";
  R.root_visible runtime ~root true;
  check
    (List.length (metadata_requests sent) = 1)
    "reactivation must release the hidden pending owner and refresh exactly once"
;;

let blocked_pending () =
  let runtime, sent, _, admitted = fixture () in
  admitted := false;
  for n = 1 to 32 do
    R.root_visible runtime ~root:(G.Uuid.to_string (uuid n)) true
  done;
  for _ = 1 to 32 do
    R.refresh runtime
  done;
  admitted := true;
  R.pump runtime;
  check
    (List.length (metadata_requests sent) = 32)
    "32 blocked root owners must keep one queued read each";
  let old = take_metadata sent in
  reply runtime old [];
  check
    (List.length (metadata_requests sent) = 32)
    "dirty queued completion yields one follow-up after admission"
;;

let preview_dirty () =
  let runtime, sent, views, _ = fixture () in
  let root = G.Uuid.to_string (uuid 1) in
  let asset = media_asset 2 in
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
  R.refresh runtime;
  check (Queue.is_empty sent) "hidden local preview must remain lazy";
  let token = (List.hd (Hashtbl.find views root).items).token in
  R.preview_visible runtime ~owner:"detail" ~slot:"attachment" ~root ~asset:token true;
  check
    (List.length (metadata_requests sent) = 1)
    "preview-only activation must refresh dirty root";
  check
    ((List.hd (Hashtbl.find views root).items).presentation
     = Journal_media.File "/staged/import.bin")
    "invalidation cannot release the local preview lease";
  R.refresh runtime;
  check (List.length (metadata_requests sent) = 1) "preview owner remains single-flight"
;;

let bounded_failure () =
  let runtime, sent, views, _ = fixture () in
  let root = G.Uuid.to_string (uuid 1) in
  R.root_visible runtime ~root true;
  R.reject
    runtime
    (let t, _, _ = take_metadata sent in
     t);
  check (Queue.is_empty sent) "ordinary first-page failure cannot retry indefinitely";
  check
    (Option.is_some (Hashtbl.find views root).error)
    "ordinary failure remains observable";
  R.reset runtime ~graph_generation:(Some 2);
  R.root_visible runtime ~root true;
  let old = take_metadata sent in
  R.reset runtime ~graph_generation:(Some 3);
  R.root_visible runtime ~root true;
  let fresh = take_metadata sent in
  reply runtime old [ media_asset 3 ];
  reply runtime fresh [ media_asset 4 ];
  check
    ((List.hd (Hashtbl.find views root).items).asset.uuid = uuid 4)
    "graph reset fences old metadata owners"
;;

let empty_to_asset () =
  let runtime, sent, views, _ = fixture () in
  let root = G.Uuid.to_string (uuid 1) in
  loaded runtime sent root [];
  R.refresh runtime;
  reply runtime (take_metadata sent) [ media_asset 7 ];
  check
    ((List.hd (Hashtbl.find views root).items).asset.uuid = uuid 7)
    "empty result is an unknown dependency, so active invalidation must reveal newly \
     eligible asset"
;;

let descriptor_lease changed_descriptor () =
  let runtime, sent, views, _ = fixture () in
  let root = G.Uuid.to_string (uuid 1) in
  let descriptor checksum =
    A.create
      ~uuid:(uuid 2)
      ~source:
        (Managed
           (Some
              (A.version ~checksum:(String.make 64 checksum) ~file_type:"png"
               |> Result.get_ok)))
      ~current_checksum:None
      ~size:None
      ~dimensions:None
    |> Result.get_ok
  in
  let original = descriptor 'a' in
  loaded runtime sent root [ original ];
  let token = (List.hd (Hashtbl.find views root).items).token in
  R.asset_visible runtime ~root ~asset:token true;
  Queue.clear sent;
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
  R.notice
    runtime
    scope
    (Asset_availability
       { consumer = token; asset = original.uuid; availability = Ready "cached" });
  let ticket, _ = Queue.take sent in
  R.receive
    runtime
    (Option.get ticket)
    (Asset_file (Some ("kept-file", "/cache/old.png")));
  R.preview_visible runtime ~owner:"detail" ~slot:"attachment" ~root ~asset:token true;
  Queue.clear sent;
  R.refresh runtime;
  let old = take_metadata sent in
  let expected = if changed_descriptor then descriptor 'b' else original in
  if changed_descriptor
  then (
    R.refresh runtime;
    reply runtime old [ expected ];
    check
      ((List.hd (Hashtbl.find views root).items).presentation
       = Journal_media.File "/cache/old.png")
      "superseded same-UUID metadata must not replace the preview's retained file";
    reply runtime (take_metadata sent) [ expected ])
  else reply runtime old [ expected ];
  let item = List.hd (Hashtbl.find views root).items in
  check
    (item.asset = expected)
    "same asset UUID must publish the newly accepted descriptor";
  let releases =
    Queue.to_seq sent
    |> Seq.filter (function
      | _, S.Release_asset_file { handle = "kept-file"; _ } -> true
      | _ -> false)
    |> Seq.length
  in
  if changed_descriptor
  then
    check
      (releases = 1 && item.token <> token)
      "new source version retires the old controller lease exactly once"
  else
    check
      (releases = 0
       && item.token = token
       && item.presentation = Journal_media.File "/cache/old.png")
      "unchanged descriptor refresh must preserve preview controller and lease"
;;

let stale_continuation hidden () =
  let runtime, sent, views, _ = fixture () in
  let root = G.Uuid.to_string (uuid 1) in
  let cursor = G.Cursor.of_string "old-projection" |> Result.get_ok in
  R.root_visible runtime ~root true;
  reply runtime (take_metadata sent) ~next_cursor:cursor [];
  R.next runtime ~root;
  let old = take_metadata sent in
  if hidden then R.root_visible runtime ~root false;
  let stale (ticket, request_id, _) =
    R.receive
      runtime
      ticket
      (S.Graph_response
         (P.V2_response
            { api_version = 2
            ; request_id
            ; outcome =
                V2_failed { code = "staleReadCursor"; message = "projection changed" }
            }))
  in
  stale old;
  if hidden
  then (
    check (Queue.is_empty sent) "stale hidden continuation must stay lazy";
    R.root_visible runtime ~root true);
  check
    (List.length (metadata_requests sent) = 1)
    "clean stale continuation must retry exactly once at first page";
  let fresh = take_metadata sent in
  let _, _, command = fresh in
  check (first_page command) "stale recovery must discard the global projection cursor";
  stale fresh;
  check
    (Queue.is_empty sent && Option.is_some (Hashtbl.find views root).error)
    "fresh first-page stale failure stops and reports an error";
  R.root_visible runtime ~root true;
  check
    (Queue.is_empty sent)
    "same appearance cannot loop after a first-page stale failure"
;;

let () =
  let failed = ref 0 in
  List.iter
    (fun (name, test) ->
       try
         test ();
         Printf.printf "PASS %s\n%!" name
       with
       | exn ->
         incr failed;
         Printf.printf "FAIL %s: %s\n%!" name (Printexc.to_string exn))
    [ "F2 64 roots active-only/burst", scale_hidden
    ; "F2 superseded metadata success", pending_followup true
    ; "F2 superseded metadata reject", pending_followup false
    ; "F2 hidden root activation", hidden_dirty `Root
    ; "F2 child-before-root activation", hidden_dirty `Asset
    ; "F2 dirty next clears cursor", hidden_dirty `Next
    ; "F2 hidden pending completion", hidden_pending
    ; "F2 32 blocked pending owners", blocked_pending
    ; "F2 preview-only/local lease", preview_dirty
    ; "F2 failure/reset fences", bounded_failure
    ; "F2 empty-to-asset unknown reference", empty_to_asset
    ; "F2 same-UUID changed descriptor lease", descriptor_lease true
    ; "F2 equal descriptor preview lease", descriptor_lease false
    ; "F2 active clean stale cursor bounded", stale_continuation false
    ; "F2 hidden clean stale cursor lazy", stale_continuation true
    ];
  check (!failed = 0) (Printf.sprintf "%d F2 metadata cases failed" !failed)
;;
