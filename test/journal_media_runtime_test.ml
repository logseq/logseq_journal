module R = Journal_media_runtime
module S = Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service
module A = Logseq_db_types.Asset_descriptor
module G = Logseq_db_types.Graph_types
module P = Logseq_db_worker.Protocol

let check condition message = if not condition then failwith message

let uuid n =
  G.Uuid.of_string (Printf.sprintf "89000000-0000-4000-8000-%012d" n) |> Result.get_ok
;;

let () =
  let sent = Queue.create () in
  let views = Hashtbl.create 2 in
  let runtime =
    R.create
      ~send:(fun ticket request ->
        Queue.add (ticket, request) sent;
        true)
      ~changed:(Hashtbl.replace views)
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
  R.imported runtime ~current:true receipt;
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
    "late import receipt releases its lease";
  Queue.clear sent;
  R.reset runtime ~graph_generation:(Some 1);
  R.root_visible runtime ~root true;
  ignore (Queue.take sent);
  R.begin_reuse runtime ~root;
  let token, request = Queue.take sent in
  let reference_query =
    match request with
    | S.Graph_request
        ({ command =
             P.V2_get_block { block; revision = None }
         ; _
         } as query)
      when block = uuid 1 -> query
    | _ -> failwith "reuse must read the attachment holder first"
  in
  check
    (Option.is_some (Hashtbl.find views root).picker)
    "reuse opens the candidate picker while loading";
  let holder : G.block =
    { uuid = uuid 1
    ; title = "entry"
    ; parent = uuid 0
    ; page = uuid 9
    ; order = "a"
    ; created_at_ms = 0L
    ; updated_at_ms = 0L
    ; refs = []
    ; tags = []
    ; properties =
        [ G.
            { ident = "logseq.property/asset"
            ; uuid = uuid 10
            ; title = "asset"
            ; schema =
                { property_type = G.Asset
                ; cardinality = G.One
                ; hidden = true
                ; public = false
                }
            ; values = [ G.Asset_value (uuid 2) ]
            ; values_truncated = false
            }
        ]
    }
  in
  R.receive
    runtime
    (Option.get token)
    (Graph_response
       (P.V2_response
          { api_version = 2
          ; request_id = reference_query.request_id
          ; outcome =
              V2_block_outcome
                (V2_present_block
                   { value =
                       { block = holder
                       ; task_status = None
                       ; rendered_page_title = "page"
                       }
                   ; revision = "r7"
                   })
          }));
  let token, request = Queue.take sent in
  let picker_query =
    match request with
    | S.Graph_request
        ({ command =
             P.V2_list_assets
               { recursive = true; roots = [ u ]; limit = 16; cursor = None }
         ; _
         } as query)
      when u = uuid 9 -> query
    | _ -> failwith "reuse candidates enumerate the holder page subtree"
  in
  let candidate_asset =
    A.create
      ~uuid:(uuid 5)
      ~source:
        (Managed
           (Some
              (A.version ~checksum:(String.make 64 'b') ~file_type:"pdf"
               |> Result.get_ok)))
      ~current_checksum:None
      ~size:None
      ~dimensions:None
    |> Result.get_ok
  in
  R.receive
    runtime
    (Option.get token)
    (Graph_response
       (P.V2_response
          { api_version = 2
          ; request_id = picker_query.request_id
          ; outcome =
              V2_assets_outcome
                { generation = "g"
                ; projection_revision = "p"
                ; items = [ asset; candidate_asset ]
                ; next_cursor = None
                }
          }));
  let picker = (Hashtbl.find views root).picker |> Option.get in
  check (List.length picker.candidates = 2) "managed assets become candidates";
  let chosen =
    List.find
      (fun (item : R.item) -> item.asset.uuid = candidate_asset.uuid)
      picker.candidates
  in
  R.reuse_select runtime ~root ~asset:chosen.token;
  let _, request = Queue.take sent in
  (match request with
   | S.Graph_request
       { command =
           P.V2_set_asset_reference
             { block
             ; previous = Some previous
             ; asset = chosen
             ; preconditions
             ; _
             }
       ; _
       }
     when block = uuid 1
          && previous = uuid 2
          && chosen = uuid 5
          && preconditions.P.blocks = [ uuid 1, "r7" ] -> ()
   | _ -> failwith "reuse must repoint the holder reference atomically");
  R.end_reuse runtime ~root;
  check
    ((Hashtbl.find views root).picker = None)
    "closing the picker clears candidate state"
;;
