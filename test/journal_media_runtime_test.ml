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

let take_metadata sent =
  let rec take () =
    match Queue.take sent with
    | Some ticket, S.Graph_request ({ command = P.V2_list_assets _; _ } as query) ->
      ticket, query.request_id, query.command
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

let raw_block ?(refs = []) ?(properties = []) n parent : G.block =
  { uuid = uuid n
  ; parent = uuid parent
  ; page = uuid 900
  ; title = "Block"
  ; order = "a"
  ; created_at_ms = 0L
  ; updated_at_ms = 0L
  ; refs
  ; tags = []
  ; properties
  }
;;

let block_response block =
  P.V2_response
    { api_version = 2
    ; request_id = uuid 999
    ; outcome =
        V2_block_outcome
          (V2_present_block
             { value =
                 { block
                 ; task_status = None
                 ; rendered_page_title = "Page"
                 ; tag_titles = []
                 }
             ; revision = "r"
             })
    }
;;

let observe runtime (block : G.block) =
  R.observe_request
    runtime
    { api_version = 2
    ; request_id = uuid 999
    ; command = P.V2_get_block { block = block.G.uuid; revision = None }
    };
  R.observe_response runtime (block_response block)
;;

let raw_page recycled : G.page =
  { uuid = uuid 900
  ; name = "page"
  ; title = "Page"
  ; kind = Ordinary_page
  ; created_at_ms = 0L
  ; updated_at_ms = 0L
  ; tags = []
  ; properties = []
  ; recycled
  }
;;

let reply_page runtime sent recycled =
  let ticket, request = Queue.take sent in
  match ticket, request with
  | Some ticket, S.Graph_request { request_id; command = P.V2_get_page { page; _ }; _ }
    when page = uuid 900 ->
    R.receive
      runtime
      ticket
      (S.Graph_response
         (P.V2_response
            { api_version = 2
            ; request_id
            ; outcome =
                V2_page_outcome
                  (V2_present_page { page = raw_page recycled; revision = "p" })
            }))
  | _ -> failwith "page liveness must use one bounded owned get_page"
;;

let reply_block runtime sent (block : G.block) =
  let ticket, request = Queue.take sent in
  match ticket, request with
  | ( Some ticket
    , S.Graph_request { request_id; command = P.V2_get_block { block = uuid; _ }; _ } )
    when uuid = block.G.uuid ->
    let outcome =
      match block_response block with
      | P.V2_response { outcome; _ } -> outcome
    in
    R.receive
      runtime
      ticket
      (S.Graph_response (P.V2_response { api_version = 2; request_id; outcome }))
  | _ -> failwith "holder/liveness must use its owned bounded get_block"
;;

let window ?(structures = []) blocks : P.v2_change_window =
  { id = "change"
  ; predecessor = "before"
  ; successor = "after"
  ; block_uuids = List.map uuid blocks
  ; page_uuids = []
  ; structure_interests = structures
  }
;;

let change runtime blocks = R.changes runtime [ window blocks ]

let seed runtime sent n items =
  observe runtime (raw_block n 900);
  loaded runtime sent (G.Uuid.to_string (uuid n)) items
;;

let membership_change runtime n target =
  observe runtime (raw_block ~refs:[ uuid target ] n 900);
  change runtime [ n ]
;;

let reply_missing runtime sent n =
  let ticket, request = Queue.take sent in
  match ticket, request with
  | Some ticket, S.Graph_request { request_id; command = P.V2_get_block { block; _ }; _ }
    when block = uuid n ->
    R.receive
      runtime
      ticket
      (S.Graph_response
         (P.V2_response
            { api_version = 2
            ; request_id
            ; outcome =
                V2_block_outcome (V2_missing_block { uuid = block; revision = "deleted" })
            }))
  | _ -> failwith "deletion must complete its owned bounded block lookup"
;;

let list_reads sent =
  Queue.to_seq sent
  |> Seq.filter (function
    | _, S.Graph_request { command = P.V2_list_assets _; _ } -> true
    | _ -> false)
  |> Seq.length
;;

let file_commands sent =
  Queue.to_seq sent
  |> Seq.filter (function
    | _, (S.Asset_command _ | Acquire_asset_file _ | Release_asset_file _) -> true
    | _ -> false)
  |> Seq.length
;;

let run_cases cases =
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
    cases;
  check (!failed = 0) (Printf.sprintf "%d media dependency cases failed" !failed)
;;

let () =
  run_cases
    [ ( "stale initial holder facts refill without poisoning the root"
      , fun () ->
          let r, q, v, _ = fixture () in
          let root = G.Uuid.to_string (uuid 1) in
          loaded r q root [];
          change r [ 1 ];
          change r [ 1 ];
          reply_block r q (raw_block 1 900);
          check
            (Option.is_none (Hashtbl.find v root).error)
            "stale successful first facts are superseded, not a failed load";
          reply_block r q (raw_block ~refs:[ uuid 70 ] 1 900);
          check (list_reads q = 1) "fresh initial holder facts reveal new membership" )
    ; ( "stale pending holder facts refill once without accepting old edges"
      , fun () ->
          let r, q, _, _ = fixture () in
          seed r q 1 [];
          change r [ 1 ];
          change r [ 1 ];
          reply_block r q (raw_block 1 900);
          check
            (list_reads q = 0)
            "stale holder completion cannot enumerate old membership";
          check
            (not (Queue.is_empty q))
            "retired stale Facts must refill the latest holder query";
          reply_block r q (raw_block ~refs:[ uuid 70 ] 1 900);
          check (list_reads q = 1) "latest holder facts reveal the new asset reference" )
    ; ( "hidden rejected point reads retire when another enqueue prunes them"
      , fun () ->
          let r, q, _, accepted = fixture () in
          seed r q 1 [];
          change r [ 1 ];
          reply_block r q (raw_block 1 900);
          accepted := false;
          change r [ 1 ];
          R.root_visible r ~root:(G.Uuid.to_string (uuid 1)) false;
          accepted := true;
          seed r q 2 [];
          R.root_visible r ~root:(G.Uuid.to_string (uuid 1)) true;
          change r [ 1 ];
          check
            (not (Queue.is_empty q))
            "hidden unaccepted Facts cannot retain its request slot forever";
          reply_block r q (raw_block ~refs:[ uuid 70 ] 1 900);
          check (list_reads q = 1) "reactivated holder can refill pruned Facts" )
    ; ( "holder title-only change cannot enumerate assets"
      , fun () ->
          let r, q, _, _ = fixture () in
          seed r q 1 [];
          change r [ 1 ];
          check
            (list_reads q = 0)
            "holder notification first checks raw membership signature";
          reply_block r q { (raw_block 1 900) with title = "New title" };
          check
            (list_reads q = 0)
            "title-only holder point response performs no asset enumeration" )
    ; ( "truncated property observation cannot prove unchanged membership"
      , fun () ->
          let r, q, _, _ = fixture () in
          let property : G.property_summary =
            { ident = "fixture/asset"
            ; uuid = uuid 71
            ; title = "Asset"
            ; schema =
                { property_type = Asset
                ; cardinality = Many
                ; hidden = false
                ; public = true
                }
            ; values = []
            ; values_truncated = true
            }
          in
          let block = raw_block ~properties:[ property ] 1 900 in
          observe r block;
          loaded r q (G.Uuid.to_string (uuid 1)) [];
          change r [ 1 ];
          if list_reads q = 0 then reply_block r q block;
          check (list_reads q = 1) "truncated values require a bounded membership read" )
    ; ( "page liveness is distinct from sibling growth"
      , fun () ->
          let r, q, _, _ = fixture () in
          seed r q 1 [];
          seed r q 2 [];
          let change = { (window [ 80 ]) with page_uuids = [ uuid 900 ] } in
          R.changes r [ change ];
          reply_page r q false;
          check (list_reads q = 0) "unchanged owning page cannot rescan sibling roots";
          R.changes r [ change ];
          reply_page r q true;
          check
            (list_reads q = 2)
            "page recycling refreshes only its retained member roots" )
    ; ( "successful asset root itself performs zero metadata reads"
      , fun () ->
          let r, q, v, _ = fixture () in
          let asset =
            A.create
              ~uuid:(uuid 1)
              ~source:
                (Managed
                   (Some
                      (A.version ~checksum:(String.make 64 'a') ~file_type:"png"
                       |> Result.get_ok)))
              ~current_checksum:None
              ~size:None
              ~dimensions:None
            |> Result.get_ok
          in
          let root = G.Uuid.to_string (uuid 1) in
          seed r q 1 [ asset ];
          let token = (List.hd (Hashtbl.find v root).items).token in
          R.asset_visible r ~root ~asset:token true;
          Queue.clear q;
          let scope : S.asset_scope =
            { account =
                { managed_sync_origin = Uri.of_string "https://sync.example"
                ; user_id = "u"
                ; account_generation = 1
                ; presentation_generation = 1
                ; lifecycle_generation = 1L
                }
            ; graph_id = uuid 900
            ; graph_generation = 1
            }
          in
          R.notice
            r
            scope
            (Asset_availability
               { consumer = token; asset = asset.uuid; availability = Ready "cached" });
          let ticket, _ = Queue.take q in
          R.receive r (Option.get ticket) (Asset_file (Some ("held", "/cache/held")));
          change r [ 1 ];
          check
            (Queue.is_empty q)
            "successful asset-as-root UUID metadata window performs zero IO";
          observe r (raw_block ~refs:[ uuid 70 ] 1 900);
          change r [ 1 ];
          check
            (list_reads q = 1)
            "positive holder membership change still refreshes an asset root" )
    ; ( "real Capture window leaves 55 sibling roots alone"
      , fun () ->
          let r, q, _, _ = fixture () in
          for n = 1 to 55 do
            seed r q n []
          done;
          observe r (raw_block 80 900);
          let change =
            { (window
                 ~structures:
                   [ P.V2_children_interest (uuid 900); V2_page_tree_interest (uuid 900) ]
                 [ 80 ])
              with
              page_uuids = [ uuid 900 ]
            }
          in
          R.changes r [ change ];
          check
            (list_reads q = 0)
            "actual Capture page/structure footprint must not reread siblings";
          reply_page r q false;
          check (list_reads q = 0) "live page confirmation must not enumerate 55 siblings"
      )
    ; ( "fact cache capacity fails visibly without retrying"
      , fun () ->
          let r, q, v, _ = fixture () in
          for n = 10000 to 14095 do
            observe r (raw_block n 900)
          done;
          let root = G.Uuid.to_string (uuid 1) in
          loaded r q root [];
          observe r (raw_block 1 900);
          check
            (Option.is_some (Hashtbl.find v root).error)
            "full raw fact cache must report capacity failure to its affected root";
          for _ = 1 to 32 do
            R.pump r
          done;
          R.root_visible r ~root true;
          R.next r ~root;
          check
            (Queue.is_empty q)
            "capacity failure cannot automatically look up the same missing fact or \
             re-read on appearance" )
    ; ( "unrelated long-lived changes preserve current query registration"
      , fun () ->
          let r, q, _, _ = fixture () in
          seed r q 1 [];
          R.observe_request
            r
            { P.api_version = 2
            ; request_id = uuid 998
            ; command = P.V2_get_block { block = uuid 1; revision = None }
            };
          for n = 10000 to 14100 do
            change r [ n ]
          done;
          let answer =
            match block_response (raw_block ~refs:[ uuid 70 ] 1 900) with
            | P.V2_response response ->
              P.V2_response { response with request_id = uuid 998 }
          in
          R.observe_response r answer;
          change r [ 70 ];
          check
            (list_reads q = 1)
            "unrelated capacity pressure cannot clear current-scope query registrations"
      )
    ; ( "moved root refreshes raw parent before later ancestor change"
      , fun () ->
          let r, q, _, _ = fixture () in
          seed r q 1 [];
          observe r (raw_block 60 900);
          change r [ 1 ];
          reply_block r q (raw_block 1 60);
          reply r (take_metadata q) [];
          change r [ 60 ];
          reply_missing r q 60;
          check (list_reads q = 1) "new parent deletion still selects moved root" )
    ; ( "dependency failure stays visible until explicit Retry"
      , fun () ->
          let r, q, v, _ = fixture () in
          observe r (raw_block 1 60);
          loaded r q (G.Uuid.to_string (uuid 1)) [];
          change r [ 80 ];
          let ticket, request = Queue.take q in
          (match ticket, request with
           | Some ticket, S.Graph_request { command = P.V2_get_block { block; _ }; _ }
             when block = uuid 60 -> R.reject r ticket
           | _ -> failwith "missing ancestor must have one owned fact read");
          let root = G.Uuid.to_string (uuid 1) in
          check
            (Option.is_some (Hashtbl.find v root).error)
            "failed dependency lookup is visible";
          R.pump r;
          change r [ 81 ];
          check
            (Queue.is_empty q)
            "unrelated changes cannot automatically retry failed dependency lookup";
          R.retry r ~root ~asset:"";
          check (not (Queue.is_empty q)) "explicit Retry can retry the dependency lookup"
      )
    ; ( "late owned raw response cannot revert reference facts"
      , fun () ->
          let r, q, _, _ = fixture () in
          seed r q 1 [];
          let request id =
            { P.api_version = 2
            ; request_id = uuid id
            ; command = P.V2_get_block { block = uuid 1; revision = None }
            }
          in
          let answer id refs =
            match block_response (raw_block ~refs 1 900) with
            | P.V2_response response ->
              P.V2_response { response with request_id = uuid id }
          in
          R.observe_request r (request 997);
          R.observe_request r (request 998);
          R.observe_response r (answer 998 [ uuid 71 ]);
          R.observe_response r (answer 997 [ uuid 70 ]);
          change r [ 70 ];
          check (list_reads q = 0) "older owned response cannot restore removed ref";
          change r [ 71 ];
          check (list_reads q = 1) "newest observed ref still selects membership" )
    ; ( "unregistered raw response cannot inject dependencies"
      , fun () ->
          let r, q, _, _ = fixture () in
          seed r q 1 [];
          R.observe_response r (block_response (raw_block ~refs:[ uuid 70 ] 1 900));
          change r [ 70 ];
          check (list_reads q = 0) "only registered current-scope facts are accepted" )
    ; ( "unrelated change does not stale in-flight root facts"
      , fun () ->
          let r, q, _, _ = fixture () in
          seed r q 1 [];
          R.observe_request
            r
            { P.api_version = 2
            ; request_id = uuid 998
            ; command = P.V2_get_block { block = uuid 1; revision = None }
            };
          change r [ 80 ];
          let answer =
            match block_response (raw_block ~refs:[ uuid 70 ] 1 900) with
            | P.V2_response response ->
              P.V2_response { response with request_id = uuid 998 }
          in
          R.observe_response r answer;
          change r [ 70 ];
          check
            (list_reads q = 1)
            "unrelated Capture cannot invalidate root fact issuance" )
    ; ( "unrelated Capture leaves 55 roots alone"
      , fun () ->
          let r, q, _, _ = fixture () in
          for n = 1 to 55 do
            seed r q n []
          done;
          observe r (raw_block 80 900);
          change r [ 80 ];
          check (list_reads q = 0) "unrelated Capture cannot enumerate 55 active roots" )
    ; ( "changed holder reveals new membership"
      , fun () ->
          let r, q, v, _ = fixture () in
          seed r q 1 [];
          observe r (raw_block ~refs:[ uuid 2 ] 1 900);
          change r [ 1 ];
          check (list_reads q = 1) "changed holder must read membership once";
          reply r (take_metadata q) [ media_asset 2 ];
          check
            (List.length (Hashtbl.find v (G.Uuid.to_string (uuid 1))).items = 1)
            "new member is displayed" )
    ; ( "known foreign ref changes select holder only"
      , fun () ->
          let r, q, _, _ = fixture () in
          observe r (raw_block ~refs:[ uuid 70 ] 1 900);
          loaded r q (G.Uuid.to_string (uuid 1)) [];
          seed r q 2 [];
          change r [ 70 ];
          check (list_reads q = 1) "foreign ref changes only its dependent holder" )
    ; ( "typed property reference is a dependency"
      , fun () ->
          let r, q, _, _ = fixture () in
          let property : G.property_summary =
            { ident = "fixture/asset"
            ; uuid = uuid 71
            ; title = "Asset"
            ; schema =
                { property_type = Asset
                ; cardinality = One
                ; hidden = false
                ; public = true
                }
            ; values = [ Asset_value (uuid 70) ]
            ; values_truncated = false
            }
          in
          observe r (raw_block ~properties:[ property ] 1 900);
          loaded r q (G.Uuid.to_string (uuid 1)) [];
          change r [ 70 ];
          check (list_reads q = 1) "typed asset property establishes dependency" )
    ; ( "removed foreign asset retains dependency until membership rebuild"
      , fun () ->
          let r, q, v, _ = fixture () in
          observe r (raw_block ~refs:[ uuid 70 ] 1 900);
          loaded r q (G.Uuid.to_string (uuid 1)) [ media_asset 70 ];
          change r [ 70 ];
          check (list_reads q = 1) "asset deletion reads its holder";
          reply r (take_metadata q) [];
          check
            ((Hashtbl.find v (G.Uuid.to_string (uuid 1))).items = [])
            "deleted membership disappears" )
    ; ( "known ancestor liveness change selects descendants"
      , fun () ->
          let r, q, _, _ = fixture () in
          observe r (raw_block 60 900);
          observe r (raw_block 1 60);
          loaded r q (G.Uuid.to_string (uuid 1)) [];
          seed r q 2 [];
          change r [ 60 ];
          reply_missing r q 60;
          check (list_reads q = 1) "ancestor tombstone refreshes its dependent only" )
    ; ( "unknown ancestor is filled through bounded get_block"
      , fun () ->
          let r, q, _, _ = fixture () in
          observe r (raw_block 1 60);
          loaded r q (G.Uuid.to_string (uuid 1)) [];
          (* Drain only dependency lookups, never manufacture a list-assets answer. *)
          let answer () =
            let ticket, request = Queue.take q in
            match ticket, request with
            | ( Some ticket
              , S.Graph_request { request_id; command = P.V2_get_block { block; _ }; _ } )
              when block = uuid 60 ->
              let value =
                match block_response (raw_block 60 61) with
                | P.V2_response { outcome; _ } -> outcome
              in
              R.receive
                r
                ticket
                (S.Graph_response
                   (P.V2_response { api_version = 2; request_id; outcome = value }))
            | _ -> failwith "unknown ancestor requires a public bounded get_block"
          in
          if Queue.is_empty q then change r [ 61 ];
          answer ();
          reply_missing r q 61;
          check (list_reads q = 1) "newly discovered ancestor selects the holder" )
    ; ( "membership move and parent structure select existing root"
      , fun () ->
          let r, q, _, _ = fixture () in
          seed r q 1 [];
          observe r (raw_block 1 60);
          R.changes
            r
            [ window
                ~structures:
                  [ P.V2_children_interest (uuid 900); V2_children_interest (uuid 60) ]
                [ 1 ]
            ];
          check (list_reads q = 1) "move rebuilds one matching root" )
    ; ( "changes coalesce while membership request is pending"
      , fun () ->
          let r, q, _, _ = fixture () in
          seed r q 1 [];
          membership_change r 1 70;
          let old = take_metadata q in
          for n = 1 to 32 do
            membership_change r 1 (70 + n)
          done;
          check (list_reads q = 0) "pending membership request cannot duplicate";
          reply r old [];
          check (list_reads q = 1) "merged changed membership has one followup" )
    ; ( "queued hidden query is retired before admission"
      , fun () ->
          let r, q, _, a = fixture () in
          a := false;
          for n = 1 to 64 do
            R.root_visible r ~root:(G.Uuid.to_string (uuid n)) true
          done;
          for n = 1 to 64 do
            R.root_visible r ~root:(G.Uuid.to_string (uuid n)) false
          done;
          a := true;
          R.pump r;
          check (list_reads q = 0) "last owner hide retires requests never admitted";
          R.root_visible r ~root:(G.Uuid.to_string (uuid 1)) true;
          check (list_reads q = 1) "reactivation starts exactly one first page" )
    ; ( "metadata failure requires explicit Retry"
      , fun () ->
          let r, q, v, _ = fixture () in
          seed r q 1 [];
          membership_change r 1 70;
          let ticket, _, _ = take_metadata q in
          R.reject r ticket;
          let root = G.Uuid.to_string (uuid 1) in
          R.root_visible r ~root true;
          R.pump r;
          check
            (list_reads q = 0 && Option.is_some (Hashtbl.find v root).error)
            "failed membership stays failed without automatic retry";
          R.retry r ~root ~asset:"";
          check (list_reads q = 1) "explicit Retry starts one metadata read" )
    ; ( "scope reset rejects late membership"
      , fun () ->
          let r, q, v, _ = fixture () in
          seed r q 1 [];
          membership_change r 1 70;
          let old = take_metadata q in
          R.reset r ~graph_generation:(Some 2);
          R.root_visible r ~root:(G.Uuid.to_string (uuid 1)) true;
          let fresh = take_metadata q in
          reply r old [ media_asset 2 ];
          reply r fresh [ media_asset 3 ];
          check
            ((List.hd (Hashtbl.find v (G.Uuid.to_string (uuid 1))).items).asset.uuid
             = uuid 3)
            "scope reset rejects old membership" )
    ; ( "successful File survives descriptor and resync"
      , fun () ->
          let r, q, v, _ = fixture () in
          let descriptor c =
            A.create
              ~uuid:(uuid 2)
              ~source:
                (Managed
                   (Some
                      (A.version ~checksum:(String.make 64 c) ~file_type:"png"
                       |> Result.get_ok)))
              ~current_checksum:None
              ~size:None
              ~dimensions:None
            |> Result.get_ok
          in
          let asset = descriptor 'a'
          and root = G.Uuid.to_string (uuid 1) in
          seed r q 1 [ asset ];
          let token = (List.hd (Hashtbl.find v root).items).token in
          R.asset_visible r ~root ~asset:token true;
          Queue.clear q;
          let scope : S.asset_scope =
            { account =
                { managed_sync_origin = Uri.of_string "https://sync.example"
                ; user_id = "u"
                ; account_generation = 1
                ; presentation_generation = 1
                ; lifecycle_generation = 1L
                }
            ; graph_id = uuid 900
            ; graph_generation = 1
            }
          in
          R.notice
            r
            scope
            (Asset_availability
               { consumer = token; asset = asset.uuid; availability = Ready "cached" });
          let ticket, _ = Queue.take q in
          R.receive r (Option.get ticket) (Asset_file (Some ("held", "/cache/held")));
          observe r (raw_block ~refs:[ asset.uuid ] 1 900);
          change r [ 2 ];
          check
            (Queue.is_empty q)
            "successful asset UUID notification performs no metadata or point read";
          change r [ 1 ];
          reply r (take_metadata q) [ descriptor 'b' ];
          let item = List.hd (Hashtbl.find v root).items in
          check
            (item.token = token
             && item.presentation = Journal_media.File "/cache/held"
             && item.asset = descriptor 'b')
            "same UUID retains successful lease while publishing updated metadata";
          check (file_commands q = 0) "metadata cannot reacquire/drop the successful File";
          R.resync r;
          check (list_reads q = 1) "real resync rebuilds membership";
          reply r (take_metadata q) [ descriptor 'c' ];
          check
            ((List.hd (Hashtbl.find v root).items).presentation
             = Journal_media.File "/cache/held")
            "resync preserves successful same-UUID File";
          check (file_commands q = 0) "resync cannot reacquire/drop a same-UUID lease";
          observe r (raw_block ~refs:[] 1 900);
          change r [ 1 ];
          reply r (take_metadata q) [];
          check
            ((Hashtbl.find v root).items = [])
            "holder ref removal removes successful membership";
          check
            (Queue.to_seq q
             |> Seq.exists (fun (_, request) ->
               match request with
               | S.Release_asset_file { handle = "held"; _ } -> true
               | _ -> false))
            "real membership removal releases the retained File lease" )
    ]
;;
