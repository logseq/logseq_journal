module W = Journal_worker_coordination.Worker_api
module C = Journal_worker_coordination.Worker_pure_coordinator
module R = Journal_worker_coordination.Worker_effect_runner
module Mailbox = Logseq_db_worker_lui.Journal_worker
module Runtime = Logseq_db_worker_lui.Journal_worker_runtime
module Id = Logseq_db_worker_lui.Journal_worker_ids
module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module P = Logseq_db_worker.Protocol
module T = Logseq_db_worker_test_support.Test_support
module Sync = Logseq_sync_pure_reducer.Core
module SR = Logseq_sync_effect_runner.Effect_runner

let require condition message = if not condition then failwith message
let uuid value = W.Uuid.of_string value |> Result.get_ok
let second_graph = uuid "9c000000-0000-4000-8000-000000000003"
let client_id = uuid "9c000000-0000-4000-8000-000000000001"

let crypto =
  SR.crypto
    ~encrypt_aes_gcm:(fun ~key:_ ~plaintext:_ -> Error "unused")
    ~decrypt_aes_gcm:(fun ~key:_ ~iv:_ ~ciphertext:_ -> Error "unused")
  |> Result.get_ok
;;

let secrets =
  SR.secrets
    ~unlock_private_key:
      (fun
        ~managed_sync_origin:_ ~user_id:_ ~password:_ ~private_key_package:_ ->
      Error "unused")
    ~unlock_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~encrypted_graph_key:_ ->
      Error "unused")
    ~load_wrapped_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ->
      Error (SR.Wrapped_graph_key_unavailable "unused"))
    ~verify_and_save_wrapped_graph_key:
      (fun
        ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ~encrypted_graph_key:_ ->
      Error "unused")
    ~delete_account_secrets:(fun ~managed_sync_origin:_ ~user_id:_ -> Ok ())
  |> Result.get_ok
;;

let favorite_page_id = uuid "9c000000-0000-4000-8000-000000000100"
let favorite_member n = uuid (Printf.sprintf "9c000000-0000-4000-8000-%012d" (100 + n))

let preview_root = uuid "9c000000-0000-4000-8000-000000000400"
let preview_child n = uuid (Printf.sprintf "9c000000-0000-4000-8000-%012d" (400+n))
let summary_child n = uuid (Printf.sprintf "9c000000-0000-4000-8000-%012d" (300+n))
let journal_page n = uuid (Printf.sprintf "9c000000-0000-4000-8000-%012d" (200+n))

let seed_coordination_read_data path =
  let module Storage = Logseq_db_storage.Logseq_sqlite_storage in
  let module Session = Logseq_db_storage.Storage_session in
  let connection = Storage.open_database path |> Result.get_ok in
  let storage = Storage.datascript_storage connection in
  let database = Storage.restore_database connection |> Result.get_ok in
  let session =
    Session.create
      ~tail:(Datascript.Storage.restore_tail_groups storage)
      ~callbacks:(Storage.connection_callbacks connection)
  in
  Fun.protect
    ~finally:(fun () -> ignore (Session.close session))
    (fun () ->
       let page = Datascript.Temp_id "synthetic-favorites-page" in
       let lookup id =
         Datascript.Lookup_ref ("block/uuid", Datascript.Uuid (W.Uuid.to_string id))
       in
       let member n target =
         let node = Datascript.Temp_id ("synthetic-favorite-" ^ string_of_int n) in
         Datascript.
           [ Add (node, "block/uuid", Uuid (W.Uuid.to_string (favorite_member n)))
           ; Add (node, "block/title", String "")
           ; Add (node, "block/parent", Ref_to page)
           ; Add (node, "block/page", Ref_to page)
           ; Add (node, "block/order", String ("a" ^ string_of_int n))
           ; Add (node, "block/link", Ref_to (lookup target))
           ]
       in
       (* The imported synthetic storage fixture already has a Favorites index.
       Retire only that index name in this isolated copy, preserving its data. *)
       let previous =
         match
           Datascript.find_datom
             database
             Datascript.Avet
             ~a:"block/name"
             ~v:(Datascript.String "$$$favorites")
             ()
         with
         | None -> []
         | Some existing ->
           Datascript.
             [ Retract (Entity_id existing.e, "block/name", Some (String "$$$favorites"))
             ]
       in
       let ops =
         previous
         @ Datascript.
             [ Add (page, "block/uuid", Uuid (W.Uuid.to_string favorite_page_id))
             ; Add (page, "block/title", String "Favorites")
             ; Add (page, "block/name", String "$$$favorites")
             ]
         @ member 1 Test_support.authoritative_block_uuid
         @ member 2 Test_support.page_uuid
         @ List.concat_map (fun n ->
           let node = Datascript.Temp_id ("synthetic-journal-" ^ string_of_int n) in
           Datascript.[
             Add (node,"block/uuid",Uuid (W.Uuid.to_string (journal_page n)));
             Add (node,"block/name",String ("synthetic-journal-" ^ string_of_int n));
             Add (node,"block/title",String "Synthetic journal");
             Add (node,"block/journal-day",Int64 20260830L);
             Add (node,"logseq.property/public?",Bool true)]) [1;2]
       in
       let ops = ops @ List.concat_map (fun n ->
         let node=Datascript.Temp_id ("synthetic-summary-child-" ^ string_of_int n) in
         Datascript.[
           Add (node,"block/uuid",Uuid (W.Uuid.to_string (summary_child n)));
           Add (node,"block/title",String "Synthetic summary child");
           Add (node,"block/order",String ("a" ^ string_of_int n));
           Add (node,"block/parent",Ref_to (lookup Test_support.authoritative_block_uuid));
           Add (node,"block/page",Ref_to (lookup Test_support.page_uuid))]) [1;2] in
       let node=Datascript.Temp_id "synthetic-preview-root" in
       let preview = Datascript.[
         Add (node,"block/uuid",Uuid (W.Uuid.to_string preview_root));
         Add (node,"block/title",String "Synthetic preview root");
         Add (node,"block/order",String "a");
         Add (node,"block/parent",Ref_to (lookup (journal_page 2)));
         Add (node,"block/page",Ref_to (lookup (journal_page 2)))] in
       let ops=ops @ preview @ List.concat_map (fun n ->
         let child=Datascript.Temp_id ("synthetic-preview-child-" ^ string_of_int n) in
         Datascript.[
           Add (child,"block/uuid",Uuid (W.Uuid.to_string (preview_child n)));
           Add (child,"block/title",String ("Preview child " ^ string_of_int n));
           Add (child,"block/order",String ("a" ^ string_of_int n));
           Add (child,"block/parent",Ref_to node);
           Add (child,"block/page",Ref_to (lookup (journal_page 2)))]) [1;2] in
       let staged =
         Session.stage_transact session ~authoritative_before:database ops
         |> Result.get_ok
       in
       let seeded = Session.staged_db_after staged in
       let page =
         Datascript.find_datom
           seeded
           Datascript.Avet
           ~a:"block/name"
           ~v:(Datascript.String "$$$favorites")
           ()
         |> Option.get
       in
       let count =
         Datascript.datoms
           seeded
           Datascript.Avet
           ~a:"block/parent"
           ~v:(Datascript.Ref page.e)
           ()
         |> Seq.length
       in
       require
         (count = 2)
         "synthetic Favorites index must contain exactly two memberships";
       Session.commit_staged session staged |> Result.get_ok)
;;

let seed_status_catalog support =
  let module D = Logseq_overlay_db.Database in
  Eio_main.run (fun _ ->
    Eio.Switch.run (fun sw ->
      let inspection =
        D.inspect_mirror
          ~application_support_directory:support
          ~graph_id:Test_support.graph_uuid
        |> Result.get_ok
      in
      let database =
        D.open_
          ~sw
          (Test_support.dependencies ~behavior:"synthetic status catalog")
          inspection
          ~graph_name:"synthetic status catalog"
        |> Result.get_ok
      in
      Fun.protect
        ~finally:(fun () -> ignore (D.close database))
        (fun () -> Test_support.seed_task_statuses database)))
;;

let with_client
      ?(epoch_ms = fun () -> 1_700_000_000_000L)
      ?(favorites = false)
      ?(statuses = false)
      f
  =
  T.with_managed (fun fixture ->
    let root = fixture.config.application_support_directory in
    let first_path = Test_support.seed_mirror root in
    if favorites then seed_coordination_read_data first_path;
    ignore (Test_support.seed_mirror ~graph_id:second_graph root);
    if statuses then seed_status_catalog root;
    let graph : Sync.graph =
      { graph_id = Test_support.graph_uuid
      ; name = "Coordination synthetic"
      ; encrypted = false
      ; schema = { major = 65; minor = 33; exact = true }
      }
    in
    let catalogs = Filename.concat root "logseq-db-worker/sync-catalogs" in
    Unix.mkdir catalogs 0o700;
    let key =
      Digestif.SHA256.digest_string "user-1\000https://api.logseq.io"
      |> Digestif.SHA256.to_hex
    in
    Out_channel.with_open_bin
      (Filename.concat catalogs (key ^ ".json"))
      (fun output ->
         output_string
           output
           (Sync.catalog_cache
              ~user_id:"user-1"
              ~graphs:
                [ graph
                ; { graph with
                    graph_id = second_graph
                  ; name = "Second coordination synthetic"
                  }
                ]
              ~selected_graph:(Some graph.graph_id)
            |> Sync.encode_catalog_cache));
    let deps =
      Service.dependencies
        ~overlay:
          (Logseq_overlay_db.Database.dependencies
             ~epoch_ms
             ~monotonic_ns:(fun () -> 1L)
             ~limits:(Logseq_overlay_db.Database.dependency_limits fixture.overlay)
           |> Result.get_ok)
        ~crypto
        ~secrets
        ~tls_authenticator:(SR.system_tls_authenticator () |> Result.get_ok)
    in
    let client =
      Runtime.start
        ~runtime_epoch:(Id.Runtime.Epoch.of_int64 9000L)
        (Service.create ~dependencies:deps)
        fixture.config
      |> Result.get_ok
    in
    Fun.protect ~finally:(fun () -> Runtime.stop client) (fun () -> f client))
;;

let test_client_to_typed_read () =
  with_client ~favorites:true ~statuses:true (fun client ->
    let events = Queue.create ()
    and state = ref (C.initial ~client_id) in
    let published = ref 0
    and deliveries = ref [] in
    let runner =
      R.create
        ~client
        ~managed_origin:"https://api.logseq.io"
        ~user_id:"user-1"
        ~post:(fun event -> Queue.add event events)
        ~publish:(fun _ -> incr published)
      |> Result.get_ok
    in
    let apply transition =
      state := transition.C.next;
      List.iter (R.submit runner) transition.instructions
    in
    Mailbox.on_event client (fun event ->
      let delivery = R.on_event runner event in
      deliveries := (event, delivery.R.disposition) :: !deliveries);
    let pump () =
      Mailbox.Private.deliver client ~max_events:64;
      let remaining = Queue.length events in
      for _ = 1 to remaining do
        apply (C.step !state (Queue.take events))
      done
    in
    let wait predicate =
      let deadline = Unix.gettimeofday () +. 4. in
      while (not (predicate ())) && Unix.gettimeofday () < deadline do
        pump ();
        Thread.delay 0.001
      done;
      require (predicate ()) "coordination did not reach expected runtime state"
    in
    wait (fun () ->
      match C.bootstrap (C.view !state) with
      | W.Bootstrap_not_ready _ -> true
      | _ -> false);
    let owner : Service.timeline_scope =
      { startup = { account_generation = 1; presentation_generation = 1 }
      ; graph_id = Test_support.graph_uuid
      ; graph_generation = 1
      }
    in
    let queued, transition =
      C.plan_query
        !state
        ~owner
        ~maximum_items:1
        ~maximum_bytes:P.maximum_response_bytes
        W.Graph_info
      |> Result.get_ok
    in
    apply transition;
    ignore
      (Mailbox.send
         client
         (Service.Client_command (Restore_local_account { user_id = "user-1" })));
    let current_session () =
      Option.bind
        (C.projection (C.view !state))
        (fun projection ->
           List.find_map
             (fun resident ->
                if resident.W.phase = W.Open then Some resident.session else None)
             (W.residents projection))
    in
    wait (fun () -> Option.is_some (current_session ()));
    let session = Option.get (current_session ()) in
    wait (fun () -> Option.is_some (C.reply (C.view !state) queued));
    (match C.reply (C.view !state) queued with
     | Some (W.Answered (Ok info)) ->
       require
         (W.Uuid.equal info.graph_uuid Test_support.graph_uuid)
         "queued real read lost graph identity"
     | _ -> failwith "queued real read did not execute after restoration");
    apply (C.step !state (C.Forget queued));
    let budget =
      W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
    in
    let request operation =
      let ticket, transition = C.request !state session operation |> Result.get_ok in
      apply transition;
      wait (fun () -> Option.is_some (C.reply (C.view !state) ticket));
      ticket, C.reply (C.view !state) ticket |> Option.get
    in
    let info_ticket, info = request (W.Query (budget, W.Graph_info)) in
    (match info with
     | W.Answered (Ok info) ->
       require
         (W.Uuid.equal info.graph_uuid Test_support.graph_uuid)
         "typed graph identity mismatch"
     | _ -> failwith "graph info failed");
    let _, admission = request (W.Query (budget, W.Admission)) in
    (match admission with
     | W.Answered (Ok value) ->
       require (value.maximum_records > 0) "typed admission inspection lost limits"
     | _ -> failwith "admission inspection failed");
    let _, definitions =
      request (W.Query (budget, W.Task_status_definitions [ second_graph ]))
    in
    require
      (definitions = W.Answered (Ok [ None ]))
      "missing status definition lost ordered slot";
    let business = Journal_graph_runtime.create () in
    let original = Journal_graph_runtime.start business in
    require
      (Option.is_some
         (Journal_graph_runtime.worker_read
            business
            { original with command = P.V2_list_favorites { limit = 50; cursor = None } }))
      "a migrated Favorites request without business ownership fell back to legacy send";
    (match Journal_graph_runtime.worker_read business original with
     | Some (Journal_graph_runtime.Read read) ->
       let _, reply = request (W.Query (budget, read.query)) in
       (match reply with
        | W.Answered (Ok value) ->
          let output =
            Journal_graph_runtime.receive_worker_read
              business
              ~request_id:original.request_id
              (read.outcome value)
          in
          require
            (List.exists
               (fun response ->
                  response.Journal_graph_runtime.payload
                  = Journal_graph_runtime.Graph_ready)
               output.responses)
            "typed graph info did not reach actual business projection"
        | _ -> failwith "typed business graph-info read failed")
     | Some (Journal_graph_runtime.Unowned_read message) -> failwith message
     | None -> failwith "business graph-info path was not migrated");
    let _, page =
      request
        (W.Query (budget, W.Page { uuid = Test_support.page_uuid; revision = None }))
    in
    (match page with
     | W.Answered (Ok (P.V2_present_page { page; _ })) ->
       require (page.uuid = Test_support.page_uuid) "page DTO lost identity"
     | _ -> failwith "page lookup failed");
    let _, children =
      request
        (W.Query
           ( budget
           , W.Child_members
               { parent = Test_support.page_uuid; revision = None; after = None } ))
    in
    let next =
      match children with
      | W.Answered (Ok children) ->
        require
          (List.length children.items = 1 && Option.is_some children.next)
          "bounded children lost More";
        Option.get children.next
      | _ -> failwith "children lookup failed"
    in
    let _, continued =
      request
        (W.Query
           ( budget
           , W.Child_members
               { parent = Test_support.page_uuid; revision = None; after = Some next } ))
    in
    (match continued with
     | W.Answered (Ok children) ->
       require (List.length children.items = 1) "continuation failed"
     | _ -> failwith "typed continuation failed");
    (match
       C.request
         !state
         session
         (W.Query
            ( budget
            , W.Child_members
                { parent = Test_support.authoritative_block_uuid
                ; revision = None
                ; after = Some next
                } ))
     with
     | Error (W.Invalid_input _) -> ()
     | _ -> failwith "foreign parent accepted continuation");
    let summary_budget = W.read_budget session ~maximum_items:P.maximum_page_size ~maximum_bytes:65536 |> Result.get_ok in
    let _, summary =
      request
        (W.Query
           ( summary_budget
           , W.Block_summary
               { block = Test_support.authoritative_block_uuid; after = None } ))
    in
    (match summary with
     | W.Answered (Ok summary) ->
       require (summary.next=None) "test projection cannot infer exact child count from Partial";
       require (Option.is_some summary.page) "atomic summary lost owning page";
       (match summary.lookup, summary.page with
        | P.V2_present_block { value; revision }, Some (P.V2_present_page { page; _ }) ->
          require
            (revision <> "" && value.block.title = "Authoritative block")
            "full DTO lost source/revision";
          let projected =
            Journal_graph_projection.block_on_page
              ~page
              ~revision
              ~child_count:(List.length summary.items)
              ~time_context:{ localtime = Unix.gmtime }
              value.block
            |> Result.get_ok
          in
          require
            (Journal_model.source projected = "Authoritative block")
            "actual App projection lost typed DTO source"
        | _ -> failwith "atomic summary missing canonical block")
     | _ -> failwith "atomic summary failed");
    (* Drive the production summary planner through real Service pages. The
       smaller test budget exercises continuation; production uses the protocol
       default budget. No write UI is switched by this read-path test. *)
    let module Confirmation = Journal_graph_mutation_confirmation in
    let owner = Confirmation.create () in
    let planned = ref None
    and clock = ref 800L in
    let ports : Confirmation.ports =
      { now =
          (fun () ->
            clock := Int64.succ !clock;
            !clock)
      ; plan_read =
          (fun ~source_epoch:_ read command ->
            let original : P.request =
              { api_version = P.api_version
              ; request_id = uuid (Printf.sprintf "9c000000-0000-4000-8000-%012Ld" !clock)
              ; command
              }
            in
            planned := Some (read, original);
            original)
      }
    in
    ignore
      (Confirmation.start
         owner
         ~ports
         (Update_conflict_refresh
            { block_id = W.Uuid.to_string Test_support.authoritative_block_uuid })
       |> Result.get_ok);
    let rec summary_page count =
      require (count < 10) "real summary cursor did not terminate";
      let read, _ = Option.get !planned in
      let _, reply = request (W.Query (budget, Confirmation.worker_query read)) in
      match reply with
      | W.Answered (Ok value) ->
        let more = Option.is_some value.next in
        (match
           Confirmation.receive_summary
             owner
             ~ports
             read
             ~lookup:value.lookup
             ~page:value.page
             ~items:value.items
             ~next_cursor:value.next
             ~scope_revision:value.scope_revision
             ~generation:value.generation
             ~projection_revision:value.projection_revision
         with
         | Continue (Ok _) ->
           require more "planner continued exhausted real summary";
           summary_page (count + 1)
         | Confirmed value ->
           require ((not more) && count >= 1) "summary completed before all real pages";
           require (Rrbvec.length value.children = 2) "summary lost exact child cardinality";
           List.iter
             (fun n ->
                require
                  (Rrbvec.exists
                     (fun (item : P.v2_child_member) ->
                        W.Uuid.equal item.value.block.uuid (summary_child n))
                     value.children)
                  "summary lost actual child identity")
             [ 1; 2 ]
         | _ -> failwith "production summary planner rejected actual Service DTO")
      | _ -> failwith "real summary planner query failed"
    in
    summary_page 0;
    let baseline =
      List.find_map
        (fun (event, _) ->
           match event with
           | Mailbox.Push { payload = Service.Coordination_updates updates; _ } ->
             List.find_map
               (function
                 | Service.Coordination_snapshot b
                   when Option.is_some b.baseline.state.sync.selected
                        && List.exists
                             (fun (_, g) -> g.Logseq_db_worker.phase = Graph_open)
                             b.baseline.state.residents -> Some b
                 | _ -> None)
               updates
           | _ -> None)
        !deliveries
      |> Option.get
    in
    let owner = Option.get baseline.baseline.state.sync.selected in
    let catalog =
      Journal_graph_runtime.submit business Journal_graph_request.Load_task_statuses
      |> fun output ->
      List.find
        (fun (request : P.request) ->
           match request.command with
           | V2_list_task_statuses _ -> true
           | _ -> false)
        output.requests
    in
    require
      (Option.is_some (Journal_graph_runtime.worker_read business catalog))
      "task catalog pagination still bypassed the typed coordinator";
    let rec read_catalog page original =
      require (page < 100) "real status cursor did not terminate";
      match Journal_graph_runtime.worker_read business original with
      | Some (Journal_graph_runtime.Read read) ->
        let _, reply = request (W.Query (budget, read.query)) in
        (match reply with
         | W.Answered (Ok value) ->
           let result = read.outcome value in
           let more =
             match result with
             | Journal_graph_runtime.Task_catalog_read value -> Option.is_some value.next
             | _ -> failwith "catalog result lost typed correspondence"
           in
           let output =
             Journal_graph_runtime.receive_worker_read
               business
               ~request_id:original.request_id
               result
           in
           if more
           then (
             require
               (not
                  (List.exists
                     (fun response ->
                        match response.Journal_graph_runtime.payload with
                        | Task_statuses_changed { complete = true; _ } -> true
                        | _ -> false)
                     output.responses))
               "partial catalog was published as Complete";
             let next =
               List.find
                 (fun (request : P.request) ->
                    match request.command with
                    | V2_list_task_statuses _ -> true
                    | _ -> false)
                 output.requests
             in
             read_catalog (page + 1) next)
           else (
             let items =
               List.find_map
                 (fun response ->
                    match response.Journal_graph_runtime.payload with
                    | Task_statuses_changed { complete = true; items; _ } -> Some items
                    | _ -> None)
                 output.responses
               |> Option.get
             in
             require
               (page >= 11)
               "actual Service did not paginate all seeded status identities";
             for n = 0 to 11 do
               require
                 (Rrbvec.exists
                    (fun (definition : W.Graph.task_status_definition) ->
                       W.Uuid.equal definition.uuid (Test_support.status_uuid n))
                    items)
                 "completed catalog lost a stable status UUID"
             done)
         | _ -> failwith "real typed catalog page failed")
      | _ -> failwith "catalog business page bypassed coordinator"
    in
    read_catalog 0 catalog;
    (* Only the date planner is migrated in this checkpoint. Resolve its empty
       root reads through the existing typed Tree API as an explicit test driver;
       this does not claim production Tree dispatch has been migrated. *)
    let calendar =
      Journal_calendar.Sampler.create
        ~clock:(fun () -> 1_788_307_200.)
        ~localtime:Unix.gmtime
        ()
    in
    ignore (Journal_calendar.Sampler.sample calendar |> Result.get_ok);
    Journal_graph_runtime.set_calendar
      business
      (Journal_calendar.Sampler.sample calendar |> Result.get_ok);
    let dates =
      Journal_graph_runtime.submit
        business
        (Load_feed
           { cursor = Some { before_day = Some 20260831; skipped_day = None }
           ; root_limit = 1
           ; day_limit = 1
           ; request_generation = 320L
           })
      |> fun o ->
      List.find
        (fun (r : P.request) ->
           match r.command with
           | V2_list_journals _ -> true
           | _ -> false)
        o.requests
    in
    let seen = ref [] and last_root = ref None in
    let rec date_page remaining original =
      match Journal_graph_runtime.worker_read business original with
      | Some (Journal_graph_runtime.Read read) ->
        require (read.maximum_items = 1) "date planner lost requested budget";
        let _, reply = request (W.Query (budget, read.query)) in
        (match reply with
         | W.Answered (Ok value) ->
           let result = read.outcome value in
           let items, more =
             match result with
             | Journal_graph_runtime.Journals_read value ->
               value.items, Option.is_some value.next
             | _ -> failwith "date result lost typed family"
           in
           require (List.length items = 1) "real date page lost item bound";
           let item = List.hd items in
           require (item.journal_day = 20260830) "date request lost inclusive bound";
           require
             (not (List.exists (W.Uuid.equal item.page.uuid) !seen))
             "date cursor repeated identity";
           seen := item.page.uuid :: !seen;
           let output =
             Journal_graph_runtime.receive_worker_read
               business
               ~request_id:original.request_id
               result
           in
           require
             (not
                (List.exists
                   (fun response ->
                      match response.Journal_graph_runtime.payload with
                      | Feed_loaded { complete = true; _ } -> true
                      | _ -> false)
                   output.responses))
             "date Partial masqueraded as complete feed";
           let root =
             List.find
               (fun (r : P.request) ->
                  match r.command with
                  | V2_get_page_tree _ -> true
                  | _ -> false)
               output.requests
           in
           last_root:=Some root;
           if remaining > 1
           then (
             require more "real first date page omitted continuation";
             let query =
               match root.command with
               | V2_get_page_tree { page; maximum_depth; revision; cursor = None; _ } ->
                 W.Tree { page; maximum_depth; revision; after = None }
               | _ -> failwith "empty root fixture unexpectedly continued"
             in
             let _, tree = request (W.Query (budget, query)) in
             let items =
               match tree with
               | W.Answered (Ok value) when value.next = None -> value.items
               | _ -> failwith "actual empty root read failed"
             in
             require (items = []) "synthetic journal unexpectedly has roots";
             let output =
               Journal_graph_runtime.receive
                 business
                 (P.V2_response
                    { api_version = P.api_version
                    ; request_id = root.request_id
                    ; outcome =
                        V2_page_tree_outcome
                          { page = item.page.uuid
                          ; maximum_depth = 0
                          ; items
                          ; next_cursor = None
                          }
                    })
             in
             let next =
               List.find
                 (fun (r : P.request) ->
                    match r.command with
                    | V2_list_journals _ -> true
                    | _ -> false)
                 output.requests
             in
             date_page (remaining - 1) next)
         | _ -> failwith "real typed date page failed")
      | _ -> failwith "date planner bypassed coordinator"
    in
    date_page 2 dates;
    List.iter
      (fun n ->
         require
           (List.exists (W.Uuid.equal (journal_page n)) !seen)
           "real date continuation lost seeded same-day identity")
      [ 1; 2 ];
    let root = Option.get !last_root in
    let query =
      match root.command with
      | V2_get_page_tree { page; maximum_depth; revision; cursor = None; _ } ->
        W.Tree { page; maximum_depth; revision; after = None }
      | _ -> failwith "preview root driver lost first-page shape"
    in
    let _, reply = request (W.Query (budget, query)) in
    let items =
      match reply with
      | W.Answered (Ok value) when value.next = None -> value.items
      | _ -> failwith "actual preview root unavailable"
    in
    require (List.length items = 1) "synthetic preview root cardinality changed";
    let output =
      Journal_graph_runtime.receive
        business
        (P.V2_response
           { api_version = P.api_version
           ; request_id = root.request_id
           ; outcome =
               V2_page_tree_outcome
                 { page = journal_page 2; maximum_depth = 0; items; next_cursor = None }
           })
    in
    let child_request output =
      List.find
        (fun (r : P.request) ->
           match r.command with
           | V2_get_children _ -> true
           | _ -> false)
        output.Journal_graph_runtime.requests
    in
    let rec preview_page page original =
      require (page < 10) "actual preview did not terminate";
      match Journal_graph_runtime.worker_read business original with
      | Some (Journal_graph_runtime.Read read) ->
        let _, reply = request (W.Query (budget, read.query)) in
        (match reply with
         | W.Answered (Ok value) ->
           let result = read.outcome value in
           let more =
             match result with
             | Journal_graph_runtime.Child_members_read value -> Option.is_some value.next
             | _ -> failwith "preview lost typed child result"
           in
           let output =
             Journal_graph_runtime.receive_worker_read
               business
               ~request_id:original.request_id
               result
           in
           if more
           then preview_page (page + 1) (child_request output)
           else (
             require (page = 1) "real preview did not exercise sealed continuation";
             let entry =
               List.find_map
                 (fun response ->
                    match response.Journal_graph_runtime.payload with
                    | Feed_loaded { complete = true; feed; _ } ->
                      List.find_map
                        (fun (day : Journal_graph_projection.day_feed) ->
                           List.find_opt
                             (fun (entry : Journal_graph_projection.timeline_entry) ->
                                Journal_model.id entry.block = W.Uuid.to_string preview_root)
                             day.entries)
                        feed.days
                    | _ -> None)
                 output.responses
               |> Option.get
             in
             require
               (List.length entry.child_summaries = 2)
               "actual preview lost visible children")
         | _ -> failwith "actual preview query failed")
      | _ -> failwith "production preview dispatch bypassed coordinator"
    in
    preview_page 0 (child_request output);
    let favorites_request : Journal_graph_request.favorites_request =
      { graph_generation = owner.graph_generation
      ; request_generation = 310L
      ; limit = 1
      ; cursor = None
      }
    in
    let request_query = request in
    let membership = ref None in
    let read_favorites request =
      let planned = Journal_graph_runtime.submit business (Load_favorites request) in
      let original =
        List.find
          (fun (r : P.request) ->
             match r.command with
             | V2_list_favorites _ -> true
             | _ -> false)
          planned.requests
      in
      let read = Journal_graph_runtime.worker_read business original in
      match read with
      | Some (Journal_graph_runtime.Read read) ->
        let _, reply = request_query (W.Query (budget, read.query)) in
        (match reply with
         | W.Answered (Ok value) ->
           let output =
             Journal_graph_runtime.receive_worker_read
               business
               ~request_id:original.request_id
               (read.outcome value)
           in
           List.iter (fun (r:P.request) -> match r.command with
             | V2_get_children {parent;_} when W.Uuid.equal parent favorite_page_id -> membership:=Some r
             | _ -> ()) output.requests;
           List.find_map
             (fun response ->
                match response.Journal_graph_runtime.payload with
                | Favorites_loaded (_, value) -> Some value
                | _ -> None)
             output.responses
           |> Option.get
         | _ -> failwith "actual typed Favorites page failed")
      | _ -> failwith "Favorites business read did not reach coordinator"
    in
    let first = read_favorites favorites_request in
    require
      (Rrbvec.length first.items = 1 && Option.is_some first.next_cursor)
      (Printf.sprintf
         "first Favorites page lost Partial continuation: items=%d more=%b page=%s"
         (Rrbvec.length first.items)
         (Option.is_some first.next_cursor)
         (Option.fold ~none:"none" ~some:W.Uuid.to_string first.favorites_page));
    require
      ((Rrbvec.nth first.items 0).membership_uuid = favorite_member 1)
      "first real Favorites membership changed";
    let second =
      read_favorites
        { favorites_request with request_generation = 311L; cursor = first.next_cursor }
    in
    require
      (Rrbvec.length second.items = 1 && second.next_cursor = None)
      "second Favorites page inferred completeness incorrectly";
    require
      ((Rrbvec.nth second.items 0).membership_uuid = favorite_member 2)
      "actual second wire request did not retain the sealed backend continuation";
    let rec membership_page page seen original =
      require (page < 10) "actual Favorite memberships did not terminate";
      match Journal_graph_runtime.worker_read business original with
      | Some (Journal_graph_runtime.Read read) ->
        let _, reply = request_query (W.Query (budget, read.query)) in
        (match reply with
         | W.Answered (Ok value) ->
           let result = read.outcome value in
           let items, more =
             match result with
             | Journal_graph_runtime.Child_members_read value ->
               value.items, Option.is_some value.next
             | _ -> failwith "Favorite membership lost typed result"
           in
           let seen =
             seen @ List.map (fun (item : P.v2_child_member) -> item.value.block.uuid) items
           in
           let output =
             Journal_graph_runtime.receive_worker_read
               business
               ~request_id:original.request_id
               result
           in
           if more
           then membership_page (page + 1) seen (child_request output)
           else (
             require
               (page = 1 && List.length seen = 2)
               "actual membership lost two-page read";
             List.iter
               (fun n ->
                  require
                    (List.exists (W.Uuid.equal (favorite_member n)) seen)
                    "actual Favorite membership UUID lost")
               [ 1; 2 ])
         | _ -> failwith "actual Favorite membership query failed")
      | _ -> failwith "Favorite membership bypassed production typed dispatch"
    in
    membership_page 0 [] (Option.get !membership);
    let drive_detail demand =
      let rec drive remaining output =
        require (remaining > 0) "actual Detail read did not converge";
        match
          List.find_map
            (fun response ->
               match response.Journal_graph_runtime.payload with
               | Detail_loaded { request_generation; detail } ->
                 Some (request_generation, detail)
               | Detail_failed _ -> failwith "actual Detail read failed"
               | _ -> None)
            output.Journal_graph_runtime.responses
        with
        | Some result -> result
        | None ->
          let original =
            List.find
              (fun (r : P.request) ->
                 match r.command with
                 | V2_get_outline_block _ | V2_get_page _ | V2_get_children _ -> true
                 | _ -> false)
              output.requests
          in
          (match Journal_graph_runtime.worker_read business original with
           | Some (Journal_graph_runtime.Read read) ->
             let budget =
               W.read_budget session ~maximum_items:read.maximum_items ~maximum_bytes:65536
               |> Result.get_ok
             in
             let _, reply = request_query (W.Query (budget, read.query)) in
             (match reply with
              | W.Answered (Ok value) ->
                drive
                  (remaining - 1)
                  (Journal_graph_runtime.receive_worker_read
                     business
                     ~request_id:original.request_id
                     (read.outcome value))
              | _ -> failwith "actual Detail typed query failed")
           | _ -> failwith "actual Detail query bypassed coordinator")
      in
      drive 10 (Journal_graph_runtime.submit business demand)
    in
    let block_id = W.Uuid.to_string Test_support.authoritative_block_uuid in
    let _, first =
      drive_detail
        (Load_detail { block_id; after = None; limit = 1; request_generation = 350L })
    in
    require
      (List.length first.children.blocks = 1 && first.children.continuation <> None)
      "actual Detail first page lost Partial cursor";
    let ui = Journal_detail.create ~session_number:350L first in
    let ui, demands = Journal_detail.step ui (Load_more block_id) in
    let demand =
      match demands with
      | [ demand ] -> demand
      | _ -> failwith "Detail UI did not retain its continuation"
    in
    let generation, second = drive_detail demand in
    let ui, _ = Journal_detail.step ui (Loaded (generation, second)) in
    require
      (List.length (Journal_detail.children ui) = 2)
      "Detail UI did not merge both real Service pages";
    require
      (Journal_detail.continuation ui ~parent_id:block_id = None)
      "actual exhausted Detail did not clear cursor";
    require
      (Journal_model.child_count (Journal_detail.root ui) = 2)
      "Detail UI advertised partial page size as final count";
    List.iter
      (fun n ->
         require
           (List.exists
              (fun block -> Journal_model.id block = W.Uuid.to_string (summary_child n))
              (Journal_detail.children ui))
           "actual Detail UI lost child identity")
      [ 1; 2 ];
    let revision =
      match summary with
      | W.Answered (Ok { lookup = P.V2_present_block { revision; _ }; _ }) -> revision
      | _ -> assert false
    in
    let mutation_request : P.request =
      { api_version = P.api_version
      ; request_id = uuid "9c000000-0000-4000-8000-000000000004"
      ; command =
          V2_save_block
            { mutation_id = uuid "9c000000-0000-4000-8000-000000000005"
            ; block = Test_support.authoritative_block_uuid
            ; title = "Read capability must not write"
            ; preconditions =
                { blocks = [ Test_support.authoritative_block_uuid, revision ]
                ; pages = []
                ; scopes = []
                }
            }
      }
    in
    let actual =
      match
        Mailbox.send
          client
          (Service.Coordination_query
             { registration = baseline.registration
             ; owner = Option.get baseline.baseline.state.sync.selected
             ; request = mutation_request
             })
      with
      | Accepted id -> id
      | _ -> failwith "negative test transport was not admitted"
    in
    let outcome () =
      List.find_map
        (function
          | Mailbox.Response { request_id; outcome; _ }, _
            when Id.Worker.Request_id.equal request_id actual -> Some outcome
          | _ -> None)
        !deliveries
    in
    wait (fun () -> Option.is_some (outcome ()));
    require
      (match outcome () with
       | Some (Mailbox.Failed _) -> true
       | _ -> false)
      "backend accepted a mutation through a read-only registration";
    let _, unchanged =
      request
        (W.Query
           ( budget
           , W.Outline_block
               { uuid = Test_support.authoritative_block_uuid; revision = None } ))
    in
    (match unchanged with
     | W.Answered (Ok (P.V2_present_block { value; _ })) ->
       require
         (value.block.title = "Authoritative block")
         "rejected read capability altered storage"
     | _ -> failwith "guard verification read failed");
    let intent =
      W.mutation_intent
        session
        ~mutation_id:(uuid "9c000000-0000-4000-8000-000000000017")
        (W.Save_block
           { block = Test_support.authoritative_block_uuid
           ; title = "Durable coordinated edit"
           ; preconditions =
               { blocks = [ Test_support.authoritative_block_uuid, revision ]
               ; pages = []
               ; scopes = []
               }
           })
      |> function
      | Ok intent -> intent
      | Error (W.Invalid_input message) -> failwith message
      | Error _ -> failwith "durable intent rejected"
    in
    let wire = W.encode_mutation_intent intent in
    let restored = W.restore_mutation_intent session wire |> Result.get_ok in
    require
      (W.encode_mutation_intent restored = wire)
      "complete mutation changed on restore";
    let mutation_ticket, mutation_reply = request (W.Mutate intent) in
    let receipt =
      match mutation_reply with
      | W.Answered (Ok (W.Committed_pending_presentation receipt)) -> receipt
      | _ -> failwith "real durable mutation did not return commit evidence"
    in
    let original = W.receipt_revisions receipt in
    require
      (Rrbvec.to_list (W.receipt_targets receipt)
       = [ Test_support.authoritative_block_uuid ])
      "durable receipt lost canonical target";
    apply (C.step !state (C.Forget mutation_ticket));
    require
      (Option.is_some (C.intent_progress (C.view !state) intent))
      "forgetting ticket erased durable outcome";
    let _, again = request (W.Mutate restored) in
    (match again with
     | W.Answered (Ok (W.Committed_pending_presentation repeated)) ->
       require
         (W.receipt_revisions repeated = original)
         "retry replaced original commit revision"
     | _ -> failwith "same durable intent could not be reconciled");
    let _, readback =
      request
        (W.Query
           ( budget
           , W.Outline_block
               { uuid = Test_support.authoritative_block_uuid; revision = None } ))
    in
    (match readback with
     | W.Answered (Ok (P.V2_present_block { value; _ })) ->
       require
         (value.block.title = "Durable coordinated edit")
         "durable mutation did not reach real projection"
     | _ -> failwith "durable mutation readback failed");
    let presentation =
      C.projection (C.view !state) |> Option.get |> W.selected |> Option.get
    in
    let confirm_ticket, confirmation_reply =
      request (W.Confirm (presentation, receipt))
    in
    (match confirmation_reply with
     | W.Answered (Ok (W.Confirmed confirmation)) ->
       require
         (W.receipt_revisions (W.confirmation_receipt confirmation) = original)
         "confirmation replaced original commit point";
       (match W.confirmation_primary confirmation with
        | W.Confirmed_block summary ->
          require (Option.is_some summary.page) "confirmation lost atomic owning page";
          (match summary.lookup with
           | P.V2_present_block { value; _ } ->
             require
               (value.block.title = "Durable coordinated edit")
               "confirmation did not expose canonical readback"
           | _ -> failwith "confirmation lost canonical block")
        | _ -> failwith "save confirmation did not return canonical block summary")
     | _ -> failwith "real Confirm failed");
    apply (C.step !state (C.Forget confirm_ticket));
    let tiny = W.read_budget session ~maximum_items:1 ~maximum_bytes:1 |> Result.get_ok in
    let _, oversized = request (W.Query (tiny, W.Graph_info)) in
    (match oversized with
     | W.Answered (Error W.Response_budget_exceeded) -> ()
     | _ -> failwith "oversized singleton was not rejected");
    let owned =
      List.find_map
        (function
          | (Mailbox.Response _, R.Consumed) as pair -> Some (fst pair)
          | _ -> None)
        !deliveries
      |> Option.get
    in
    require
      ((R.on_event runner owned).disposition = R.Consumed)
      "owned duplicate fell through";
    require
      (List.exists (fun (_, d) -> d = R.Unowned_response) !deliveries)
      "legacy response ownership disappeared";
    let forgotten = C.step !state (C.Forget info_ticket) in
    apply forgotten;
    require
      (C.reply (C.view !state) info_ticket = None)
      "forgotten ticket retained rendering result";
    require (!published > 0) "coordinator did not publish";
    ignore
      (Mailbox.send
         client
         (Service.Client_command
            (Configure_resident_graphs [ Test_support.graph_uuid; second_graph ])));
    wait (fun () ->
      Option.fold
        ~none:false
        ~some:(fun p ->
          List.length (W.residents p) = 2
          && List.for_all (fun r -> r.W.phase = W.Open) (W.residents p))
        (C.projection (C.view !state)));
    let selected () = Option.bind (C.projection (C.view !state)) W.selected in
    let initial_presentation = Option.map W.presentation_generation (selected ()) in
    ignore
      (Mailbox.send client (Service.Client_command (Focus_resident_graph second_graph)));
    wait (fun () ->
      Option.fold
        ~none:false
        ~some:(fun p -> W.graph_id (W.presentation_session p) = second_graph)
        (selected ()));
    ignore
      (Mailbox.send
         client
         (Service.Client_command (Focus_resident_graph Test_support.graph_uuid)));
    wait (fun () ->
      Option.fold
        ~none:false
        ~some:(fun p ->
          W.graph_id (W.presentation_session p) = Test_support.graph_uuid
          && Some (W.presentation_generation p) <> initial_presentation)
        (selected ()));
    require
      (Option.fold
         ~none:false
         ~some:(fun p -> W.equal_session (W.presentation_session p) session)
         (selected ()))
      "focus roundtrip revoked resident execution instead of presentation";
    (match C.intent_progress (C.view !state) intent with
     | Some (W.Committed_pending_presentation preserved) ->
       require
         (W.receipt_revisions preserved = original)
         "focus roundtrip changed durable receipt"
     | _ -> failwith "focus roundtrip did not retire old presentation confirmation");
    require
      (Result.is_error (C.request !state session (W.Confirm (presentation, receipt))))
      "old presentation confirmed a new focus round";
    let current_presentation = selected () |> Option.get in
    let _, reconfirmed = request (W.Confirm (current_presentation, receipt)) in
    (match reconfirmed with
     | W.Answered (Ok (W.Confirmed _)) -> ()
     | _ -> failwith "new explicit Confirm could not use preserved receipt");
    apply (C.step !state C.Retry_bootstrap);
    require
      (Result.is_error (C.request !state session (W.Query (budget, W.Graph_info))))
      "retry admitted old session";
    wait (fun () ->
      Option.fold
        ~none:false
        ~some:(fun next -> not (W.equal_session next session))
        (current_session ()));
    require
      ((R.on_event runner owned).disposition = R.Consumed)
      "rebind lost old response ownership";
    let replacement = Option.get (current_session ()) in
    let next_budget =
      W.read_budget replacement ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
    in
    let ticket, transition =
      C.request !state replacement (W.Query (next_budget, W.Graph_info)) |> Result.get_ok
    in
    apply transition;
    apply (C.step !state (C.Cancel ticket));
    apply (C.step !state (C.Forget ticket));
    require
      (R.shutdown runner = R.Draining)
      "shutdown fabricated immediate unregister ACK";
    wait (fun () -> R.shutdown runner = R.Stopped);
    require
      (C.reply (C.view !state) ticket = None)
      "late cancelled read revived a forgotten consumer")
;;

let test_read_completion_rechecks_graph_owner ?(durable = false) () =
  let armed = Atomic.make false
  and entered = Atomic.make false
  and release = Atomic.make false in
  let epoch_ms () =
    if Atomic.get armed
    then (
      Atomic.set entered true;
      while not (Atomic.get release) do
        Eio.Fiber.yield ()
      done);
    1_700_000_000_000L
  in
  with_client ~epoch_ms (fun client ->
    Fun.protect
      ~finally:(fun () -> Atomic.set release true)
      (fun () ->
         let responses = Hashtbl.create 16
         and baseline = ref None in
         Mailbox.on_event client (function
           | Mailbox.Response { request_id; outcome; _ } ->
             Hashtbl.replace responses request_id outcome
           | Push { payload = Service.Coordination_updates updates; _ } ->
             List.iter
               (function
                 | Service.Coordination_snapshot value -> baseline := Some value
                 | _ -> ())
               updates
           | _ -> ());
         let wait predicate =
           let deadline = Unix.gettimeofday () +. 4. in
           while (not (predicate ())) && Unix.gettimeofday () < deadline do
             Mailbox.Private.deliver client ~max_events:64;
             Thread.delay 0.001
           done;
           require (predicate ()) "Service completion ownership race did not settle"
         in
         let send request =
           match Mailbox.send client request with
           | Accepted id -> id
           | _ -> failwith "race request not admitted"
         in
         ignore
           (send (Service.Client_command (Restore_local_account { user_id = "user-1" })));
         let registration = 900000L in
         let id = send (Service.Register_coordination registration) in
         wait (fun () -> Hashtbl.mem responses id);
         (match Hashtbl.find responses id with
          | Completed (Service.Coordination_registered value) -> baseline := Some value
          | _ -> assert false);
         wait (fun () ->
           match !baseline with
           | Some value ->
             List.exists
               (fun (_, state) ->
                  state.Logseq_db_worker.phase = Logseq_db_worker.Graph_open)
               value.baseline.state.residents
           | _ -> false);
         let owner = Option.get (Option.get !baseline).baseline.state.sync.selected in
         let req suffix command =
           { P.api_version = P.api_version
           ; request_id =
               W.Uuid.of_string ("99000000-0000-4000-8000-" ^ suffix) |> Result.get_ok
           ; command
           }
         in
         let read =
           send
             (Service.Coordination_query
                { registration
                ; owner
                ; request =
                    req
                      "000000000001"
                      (P.V2_get_outline_block
                         { block = Test_support.authoritative_block_uuid
                         ; revision = None
                         })
                })
         in
         wait (fun () -> Hashtbl.mem responses read);
         let revision =
           match Hashtbl.find responses read with
           | Completed
               (Service.Graph_response
                  (P.V2_response
                     { outcome = V2_block_outcome (V2_present_block { revision; _ }); _ }))
             -> revision
           | _ -> failwith "race fixture block missing"
         in
         Atomic.set armed true;
         let mutation_request =
           req
             "000000000002"
             (P.V2_save_block
                { mutation_id = uuid "99000000-0000-4000-8000-000000000003"
                ; block = Test_support.authoritative_block_uuid
                ; title = "Synthetic held writer"
                ; preconditions =
                    { blocks = [ Test_support.authoritative_block_uuid, revision ]
                    ; pages = []
                    ; scopes = []
                    }
                })
         in
         let module Wire = Logseq_db_worker_contract.Mutation_pure_wire in
         let wire =
           Wire.create
             ~origin:(Uri.of_string "https://api.logseq.io")
             ~user:"user-1"
             ~graph:Test_support.graph_uuid
             mutation_request.command
           |> Result.get_ok
         in
         let writer =
           send
             (if durable
              then
                Service.Coordination_mutation
                  { registration
                  ; owner
                  ; request_id = mutation_request.request_id
                  ; intent = Wire.encode wire
                  }
              else Service.Graph_request_at (owner, mutation_request))
         in
         wait (fun () -> Atomic.get entered);
         let read =
           send
             (Service.Coordination_query
                { registration; owner; request = req "000000000004" P.V2_graph_info })
         in
         (* Cancelling the outer writer releases its Service lane, not its
            accepted durable DB operation. Keep that operation held while the
            second lane is waiting on the real snapshot mutex. *)
         Mailbox.cancel client ~request_id:writer;
         if not durable
         then (
           wait (fun () -> Hashtbl.mem responses writer);
           require
             (Hashtbl.find responses writer = Mailbox.Cancelled)
             "held legacy writer cancellation did not release its outer lane");
         wait (fun () ->
           (Mailbox.Private.metrics (Mailbox.Private.pack_client client))
             .active_request_fibers
           > 0);
         require
           (not (Hashtbl.mem responses read))
           "read did not wait behind actual writer";
         ignore (send (Service.Client_command Return_to_graph_picker));
         wait (fun () ->
           match !baseline with
           | Some value -> value.baseline.state.sync.selected = None
           | _ -> false);
         Atomic.set release true;
         wait (fun () -> Hashtbl.mem responses read);
         require
           (match Hashtbl.find responses read with
            | Failed _ -> true
            | _ -> false)
           "retired graph read completion still crossed Service's authority gate";
         if durable
         then (
           wait (fun () -> Hashtbl.mem responses writer);
           require
             (Hashtbl.find responses writer = Mailbox.Cancelled)
             "cancelled durable attempt was reported as known rollback";
           Atomic.set armed false;
           ignore (send (Service.Client_command (Select_graph Test_support.graph_uuid)));
           wait (fun () ->
             match !baseline with
             | Some value ->
               Option.is_some value.baseline.state.sync.selected
               && List.exists
                    (fun (_, state) -> state.Logseq_db_worker.phase = Graph_open)
                    value.baseline.state.residents
             | _ -> false);
           let next_owner =
             Option.get (Option.get !baseline).baseline.state.sync.selected
           in
           require
             (next_owner.graph_generation <> owner.graph_generation)
             "reopen did not replace execution generation";
           let retry =
             send
               (Service.Coordination_mutation
                  { registration
                  ; owner = next_owner
                  ; request_id = (req "000000000004" P.V2_graph_info).request_id
                  ; intent = Wire.encode wire
                  })
           in
           wait (fun () -> Hashtbl.mem responses retry);
           match Hashtbl.find responses retry with
           | Completed
               (Service.Coordination_mutation_result
                  { outcome =
                      Wire.Committed
                        (P.V2_response { outcome = P.V2_mutation_committed committed; _ })
                  ; _
                  }) ->
             require
               (committed.status = P.V2_applied)
               "unknown write replay invented Already_applied/current revision";
             require
               (committed.before_projection_revision
                <> committed.after_projection_revision)
               "unknown accepted write lost original commit evidence"
           | _ -> failwith "durable unknown did not reconcile across close/reopen")))
;;

let test_host_preserves_query_origin_before_forget () =
  let module Host = Journal_worker_coordination_host in
  with_client (fun client ->
    let queue = Queue.create () in
    let host =
      Host.create
        ~client
        ~client_id
        ~managed_origin:"https://api.logseq.io"
        ~user_id:"user-1"
        ~enqueue:(fun f -> Queue.add f queue)
        ~changed:(fun _ -> ())
      |> Result.get_ok
    in
    Mailbox.on_event client (fun event -> ignore (Host.on_event host event));
    let pump () =
      Mailbox.Private.deliver client ~max_events:64;
      let count = Queue.length queue in
      for _ = 1 to count do
        (Queue.take queue) ()
      done
    in
    let wait predicate =
      let deadline = Unix.gettimeofday () +. 4. in
      while (not (predicate ())) && Unix.gettimeofday () < deadline do
        pump ();
        Thread.delay 0.001
      done;
      require (predicate ()) "host provenance integration did not settle"
    in
    wait (fun () ->
      match C.bootstrap (Host.view host) with
      | W.Bootstrap_not_ready _ -> true
      | _ -> false);
    let owner : Service.timeline_scope =
      { startup = { account_generation = 1; presentation_generation = 1 }
      ; graph_id = Test_support.graph_uuid
      ; graph_generation = 1
      }
    in
    let ticket =
      Host.plan_query host ~owner ~maximum_items:1 ~maximum_bytes:65536 W.Graph_info
      |> Result.get_ok
    in
    let callback = ref None
    and calls = ref 0 in
    Host.watch_read host ticket ~f:(fun origin reply ->
      incr calls;
      require
        (C.query_origin (Host.view host) ticket = None)
        "business callback ran before ticket Forget";
      callback := Some (origin, reply));
    ignore
      (Mailbox.send
         client
         (Service.Client_command (Restore_local_account { user_id = "user-1" })));
    wait (fun () -> Option.is_some !callback);
    let session, budget =
      match Option.get !callback with
      | Some origin, W.Answered (Ok info) ->
        require
          (W.Uuid.equal info.graph_uuid Test_support.graph_uuid)
          "real host query lost graph";
        origin
      | _ -> failwith "real host callback lost exact execution origin"
    in
    require
      (W.validate_request session (W.Query (budget, W.Graph_info)) = Ok ())
      "forwarded origin budget is unrelated to Send";
    require (Host.validate_session host session = Ok ()) "live read origin was rejected";
    ignore (Host.shutdown host);
    wait (fun () -> C.shutdown_state (Host.view host) = C.Stopped);
    require
      (Host.validate_session host session = Error W.Revoked_session)
      "stopped host allowed cached read";
    require (!calls = 1) "query origin callback was delivered more than once")
;;

let () =
  test_host_preserves_query_origin_before_forget ();
  test_client_to_typed_read ();
  test_read_completion_rechecks_graph_owner ();
  test_read_completion_rechecks_graph_owner ~durable:true ();
  print_endline "Worker coordination real client/read/cleanup passed"
;;
