module W = Journal_worker_coordination.Worker_api
module C = Journal_worker_coordination.Worker_pure_coordinator
module R = Journal_worker_coordination.Worker_effect_runner
module Mailbox = Logseq_db_worker_lui.Journal_worker
module Runtime = Logseq_db_worker_lui.Journal_worker_runtime
module Id = Journal_worker_ids
module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module T = Logseq_db_worker_test_support.Test_support
module Sync = Logseq_sync_pure_reducer.Core
module SR = Logseq_sync_effect_runner.Effect_runner

let require condition message = if not condition then failwith message
let uuid value = W.Uuid.of_string value |> Result.get_ok

(* Registration replies and later live pushes can be drained in one batch.
   Consuming a retained reply must not replace a newer snapshot already seen. *)
let remember_baseline baseline (value : Service.coordination_baseline) =
  match !baseline with
  | Some current when current.Service.registration = value.registration
      && current.baseline.version > value.baseline.version -> ()
  | _ -> baseline := Some value
;;
module Read=Worker_pure_read

(* This Service-side source uses the real client's incarnation and its atomic
   baseline. It exercises the backend contract rather than fabricating an ACK. *)
let observation_read client baseline (owner:Service.timeline_scope) registration ?(maximum_items=1) ?(maximum_bytes=16384) query =
  let module F=Read.For_worker in
  let baseline=Option.get baseline in
  let scope=List.find_map(fun((scope:Sync.graph_scope),_)->
    if scope.Logseq_sync_pure_reducer.Core.graph_id=owner.graph_id
      && scope.graph_generation=owner.graph_generation
      && scope.account.account_generation=owner.startup.account_generation then Some scope else None)
    baseline.Service.baseline.state.residents |> Option.get in
  let binding=F.binding ~serial:registration
    ~incarnation:(Read.worker_incarnation ~runtime_epoch:(Mailbox.runtime_epoch client) ~worker_generation:(Mailbox.worker_generation client))
    ~origin:(Uri.to_string scope.account.managed_sync_origin) ~user:scope.account.user_id in
  let session=F.session ~binding ~graph:scope.graph_id ~account:scope.account.account_generation
    ~lifecycle:scope.account.lifecycle_generation ~generation:scope.graph_generation ~scope:owner ~asset_scope:scope ~limits:baseline.limits in
  let budget=Read.read_budget session ~maximum_items ~maximum_bytes |> Result.get_ok in
  F.pack_query budget query
;;

let query_request client baseline owner registration request_id ?maximum_items ?maximum_bytes query =
  Service.Coordination_query{registration;owner;request_id;
    read=observation_read client baseline owner registration ?maximum_items ?maximum_bytes query}
let mutation_request client baseline owner registration ~request_id ~mutation_id command =
  let Read.Read_query(budget,_)=observation_read client baseline owner registration Read.Graph_info in
  let session=Read.For_worker.read_budget_owner budget in
  let intent=W.mutation_intent session ~mutation_id command |> Result.get_ok in
  Service.Coordination_mutation{registration;owner;request_id;
    intent=W.Mutation_intent intent}

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

let host_asset_demand host ~receive ~(owner:Service.timeline_scope) ~graph_generation ~name priority assets =
  let module H=Journal_worker_coordination_host in
  match Option.bind(C.projection(H.view host))(fun projection->List.find_map(fun resident->
    if resident.W.phase=W.Open && W.matches_scope resident.session owner then Some resident.session else None)(W.residents projection)) with
  |Some session when owner.graph_generation=graph_generation->
    (match W.asset_consumer session ~name with Error _->None|Ok consumer->
      match H.request host session(W.Replace_asset_demand(consumer,priority,assets)) with
      |Error _->None|Ok ticket->H.watch host ticket ~f:(function
          |W.Answered(Ok demand)->receive ticket demand
          |_->());
        Some ticket)
  |_->None

let host_asset_release host (ticket,demand) =
  let module H=Journal_worker_coordination_host in
  match demand with
  |None->H.post host(C.Cancel ticket);true
  |Some demand->
    match H.request host (W.asset_demand_session demand)(W.Release_asset_demand demand) with
    |Error _->false|Ok ticket->H.watch host ticket ~f:(fun _->());true

let favorite_page_id = uuid "9c000000-0000-4000-8000-000000000100"
let favorite_member n = uuid (Printf.sprintf "9c000000-0000-4000-8000-%012d" (100 + n))

let byte_root n = uuid (Printf.sprintf "9c000000-0000-4000-8000-%012d" (700+n))
let quota_root n = uuid (Printf.sprintf "9c000000-0000-4000-8000-%012d" (500+n))
let preview_root = uuid "9c000000-0000-4000-8000-000000000400"
let preview_child n = uuid (Printf.sprintf "9c000000-0000-4000-8000-%012d" (400+n))
let summary_child n = uuid (Printf.sprintf "9c000000-0000-4000-8000-%012d" (300+n))
let journal_page n = uuid (Printf.sprintf "9c000000-0000-4000-8000-%012d" (200+n))

let seed_coordination_read_data ?(assets=false) path =
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
             Add (node,"block/journal-day",Int64 (if n=4 then 20260831L else if n=3 then 20260829L else 20260830L));
             Add (node,"logseq.property/public?",Bool true)]) [1;2;3;4]
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
       let ops=ops @ List.concat_map (fun index ->
         let n=index+1 in
         let node=Datascript.Temp_id ("synthetic-quota-root-" ^ string_of_int n) in
         Datascript.[
           Add (node,"block/uuid",Uuid (W.Uuid.to_string (quota_root n)));
           Add (node,"block/title",String (if n<=20 then "" else "Quota root " ^ string_of_int n));
           Add (node,"block/order",String (Printf.sprintf "a%04d" n));
           Add (node,"block/parent",Ref_to (lookup (journal_page 3)));
           Add (node,"block/page",Ref_to (lookup (journal_page 3)))]) (List.init 60 Fun.id) in
       let ops=ops @ List.concat_map (fun index ->
         let n=index+1 in
         let node=Datascript.Temp_id ("synthetic-byte-root-" ^ string_of_int n) in
         Datascript.[
           Add (node,"block/uuid",Uuid (W.Uuid.to_string (byte_root n)));
           Add (node,"block/title",String ((if n<=30 then "Before byte boundary " else String.make 3000 'x') ^ string_of_int n));
           Add (node,"block/order",String (Printf.sprintf "a%04d" n));
           Add (node,"block/parent",Ref_to (lookup (journal_page 4)));
           Add (node,"block/page",Ref_to (lookup (journal_page 4)))]) (List.init 60 Fun.id) in
       let ops=if not assets then ops else ops @ List.concat_map(fun n->
         let node=Datascript.Temp_id ("typed-scan-external-asset-" ^ string_of_int n) in
         Datascript.[
           Add(node,"block/uuid",Uuid(Printf.sprintf "9c000000-0000-4000-8000-%012d" (900+n)));
           Add(node,"block/title",String "Synthetic external attachment");
           Add(node,"block/parent",Ref_to(lookup(journal_page 1)));
           Add(node,"block/page",Ref_to(lookup(journal_page 1)));
           Add(node,"block/order",String("a" ^ string_of_int n));
           Add(node,"block/tags",Ref_to(Ident "logseq.class/Asset"));
           Add(lookup(journal_page 1),"block/refs",Ref_to node);
           Add(node,"logseq.property.asset/external-url",String("https://example.invalid/" ^ string_of_int n))]) [1;2;3] in
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

let prepare_atomic_append_fixture support =
  let module D=Logseq_overlay_db.Database in
  let module J=Transit_core.Json in
  Eio_main.run(fun _->Eio.Switch.run(fun sw->
    let inspection=D.inspect_mirror ~application_support_directory:support ~graph_id:Test_support.graph_uuid |> Result.get_ok in
    let database=D.open_ ~sw (Test_support.dependencies ~behavior:"atomic append fixture") inspection
      ~graph_name:"atomic append fixture" |> Result.get_ok in
    Fun.protect ~finally:(fun()->ignore(D.close database))(fun()->
      let web=J.String "existing-web-append-day" in
      let add attribute value=Test_support.status_add web attribute value in
      Test_support.apply_test_transaction database ~cursor:2
        [Test_support.status_add (J.Keyword "logseq.class/Journal")
           "logseq.property.journal/title-format" (J.String "yyyy-MM-dd");
         add "block/uuid" (J.Uuid "9f000000-0000-4000-8000-000000002100");
         add "block/title" (J.String "Existing Web day title");add "block/name" (J.String "existing-web-append-day");
         add "block/journal-day" (J.Int 20261103);add "block/tags" (J.Keyword "logseq.class/Journal")])))
;;

let with_service_fixture
      ?(epoch_ms = fun () -> 1_700_000_000_000L)
      ?(favorites = false)
      ?(assets = false)
      ?(statuses = false)
      ?change_max_items
      ?(extra_graphs = [])
      ?(prepare = fun _ -> ())
      f
  =
  T.with_managed (fun fixture ->
    let root = fixture.config.application_support_directory in
    let first_path = Test_support.seed_mirror root in
    if favorites then seed_coordination_read_data ~assets first_path;
    ignore (Test_support.seed_mirror ~graph_id:second_graph root);
    List.iter(fun graph_id->ignore(Test_support.seed_mirror ~graph_id root))extra_graphs;
    if statuses then seed_status_catalog root;
    prepare root;
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
                ([ graph
                ; { graph with
                    graph_id = second_graph
                  ; name = "Second coordination synthetic"
                  }
                ] @ List.map(fun graph_id->{graph with graph_id;name="Extra synthetic graph"})extra_graphs)
              ~selected_graph:(Some graph.graph_id)
            |> Sync.encode_catalog_cache));
    let deps =
      Service.dependencies
        ~overlay:
          (Logseq_overlay_db.Database.dependencies
             ~epoch_ms
             ~monotonic_ns:(fun () -> 1L)
             ~limits:(let limits=Logseq_overlay_db.Database.dependency_limits fixture.overlay in
               match change_max_items with None->limits|Some change_max_items->{limits with change_max_items})
           |> Result.get_ok)
        ~crypto
        ~secrets
        ~tls_authenticator:(SR.system_tls_authenticator () |> Result.get_ok)
    in
    f deps fixture.config)
;;

let with_client_sessions ?epoch_ms ?favorites ?assets ?statuses ?change_max_items ?prepare f =
  with_service_fixture ?epoch_ms ?favorites ?assets ?statuses ?change_max_items ?prepare (fun deps config ->
    let current = ref None and epoch = ref 8999L in
    let stop () = Option.iter Runtime.stop !current; current := None in
    let start () =
      stop ();
      epoch := Int64.succ !epoch;
      let client = Runtime.start ~runtime_epoch:(Id.Runtime.Epoch.of_int64 !epoch)
          (Service.create ~dependencies:deps) config |> Result.get_ok in
      current := Some client;
      client
    in
    Fun.protect ~finally:stop (fun () -> f start))
;;

let with_client ?epoch_ms ?favorites ?assets ?statuses ?change_max_items ?prepare f =
  with_client_sessions ?epoch_ms ?favorites ?assets ?statuses ?change_max_items ?prepare
    (fun start -> f (start ()))
;;

(* The pure route reducer has no manager push or host handoff input.
   Drive public mounted hooks over the actual Service, DB and resource owners. *)
(* These failures originate in mailbox-outcome decoding, outside the pure
   reducer. Exercise the public runner with a real admitted request, then replace
   only its transport outcome; the reducer never receives a fabricated error. *)
let test_cleanup_transport_causes () =
  let failures=ref [] in
  let check condition message=if not condition then failures:=message::!failures in
  let run stage outcome suffix = with_client (fun client ->
    let events=Queue.create () and state=ref(C.initial ~client_id) in
    let runner=R.create ~client ~managed_origin:"https://api.logseq.io" ~user_id:"user-1"
      ~post:(fun event->Queue.add event events) ~publish:(fun _->()) |> Result.get_ok in
    let injecting=ref false and captured=ref [] and delivery_errors=ref [] and imported=ref None in
    Mailbox.on_event client(fun event->
      let event=match event,!injecting with
        |Mailbox.Response response,true->Mailbox.Response{response with outcome}
        |_->event in
      let delivery=R.on_event runner event in
      if !injecting then delivery_errors:=delivery.error::!delivery_errors);
    let apply transition=state:=transition.C.next;List.iter(fun instruction->
      (match instruction,stage with
       |C.Release_observation_registration _,"Observation release"
       |C.Finalize_observation_registration _,"Observation finalization"
       |C.Release_binding _,"Binding unregister"
       |C.Send(_,_,W.Import _),"Import"->injecting:=true
       |_->());R.submit runner instruction)transition.instructions in
    let pump ()=
      Mailbox.Private.deliver client ~max_events:64;
      let count=Queue.length events in
      for _=1 to count do
        let event=Queue.take events in
        if !injecting then captured:=event::!captured else apply(C.step !state event)
      done in
    let wait message predicate=
      let deadline=Unix.gettimeofday()+.4. in
      while not(predicate()) && Unix.gettimeofday()<deadline do pump();Thread.delay 0.001 done;
      require(predicate())message in
    wait "cleanup fixture registration" (fun()->match C.bootstrap(C.view !state)with W.Bootstrap_not_ready _->true|_->false);
    ignore(Mailbox.send client(Service.Client_command(Restore_local_account{user_id="user-1"})));
    let session ()=Option.bind(C.projection(C.view !state))(fun projection->
      List.find_map(fun resident->if resident.W.phase=W.Open then Some resident.session else None)(W.residents projection)) in
    wait "cleanup fixture session" (fun()->Option.is_some(session()));
    let session=Option.get(session()) in
    pump();
    let push notice=R.on_event runner(Mailbox.Push{
      runtime_epoch=Mailbox.runtime_epoch client;worker_generation=Mailbox.worker_generation client;
      push_sequence=Id.Worker.Push_sequence.of_int64 999L;topic=Service.asset_topic;
      payload=Service.Asset_notice(Read.For_worker.session_asset_scope session,notice)}) in
    require((push Service.Asset_capacity_available).error=None)
      "valid asset notice became a transport error";
    check((push(Service.Asset_demand_accepted "foreign-demand-owner")).error=Some W.Revoked_session)
      "asset notice decoding erased its typed ownership cause";
    if stage="Binding unregister" then apply(C.step !state C.Shutdown_requested)
    else if stage="Import" then (
      let source:Logseq_db_types.Asset_import.t={
        operation=uuid "9c000000-0000-4000-8000-000000009921";
        asset=uuid "9c000000-0000-4000-8000-000000009922";target=Test_support.authoritative_block_uuid;
        local_mutation=uuid "9c000000-0000-4000-8000-000000009923";
        metadata_mutation=uuid "9c000000-0000-4000-8000-000000009924";
        replace_reference=None;source_file="/synthetic-missing/import.png";title="Synthetic import";file_type="png"} in
      let intent=W.asset_import_intent session source |> Result.get_ok in
      imported:=Some intent;
      let _,plan=C.request !state session(W.Import intent) |> Result.get_ok in apply plan)
    else (
      let budget=W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok in
      let ticket,plan=C.request !state session(W.Observe(budget,W.Graph_info)) |> Result.get_ok in
      apply plan;wait "cleanup fixture observation" (fun()->Option.is_some(C.reply(C.view !state)ticket));
      let handle=match C.reply(C.view !state)ticket with Some(W.Answered(Ok value))->value.W.observation
        |_->failwith "cleanup fixture observation failed" in
      apply(C.step !state(C.Forget ticket));
      let released,plan=C.request !state session(W.Release handle) |> Result.get_ok in
      apply plan;
      if stage="Observation finalization" then (
        wait "cleanup fixture release" (fun()->Option.is_some(C.reply(C.view !state)released));
        apply(C.step !state(C.Forget released));
        apply(C.step !state(C.Observation_returned handle))));
    if stage="Import" then (
      wait "Import completion missing" (fun()->List.exists(function C.Completed _->true|_->false)!captured);
      check(List.mem (Some(W.Service_failed("Import: "^suffix))) !delivery_errors)
        "Import transport failure erased its diagnostic cause";
      check(List.exists(function
        |C.Completed(_,W.Interrupted(W.Transport_lost cause))->cause=W.Service_failed("Import: "^suffix)
        |_->false)!captured) "Import reply erased its typed interruption cause";
      List.iter(fun event->state:=(C.step !state event).next)(List.rev !captured);
      check(C.import_progress(C.view !state)(Option.get !imported)=Some W.Import_unknown)
        "Import transport failure falsely settled its unknown outcome")
    else (
    let result=function
      |C.Observation_release_completed(_,_,result) when stage="Observation release"->Some result
      |C.Observation_finalize_completed(_,_,result) when stage="Observation finalization"->Some result
      |C.Binding_release_completed(_,result) when stage="Binding unregister"->Some result
      |_->None in
    wait (stage^" completion missing") (fun()->List.exists(fun event->Option.is_some(result event))!captured);
    check(List.exists(fun event->result event=Some(Error(W.Service_failed(stage^": "^suffix))))!captured)
      (stage^" erased its backend cause"))) in
  List.iter(fun stage->List.iter(fun(outcome,suffix)->run stage outcome suffix)
    [Mailbox.Failed "synthetic cleanup backend refused retirement","synthetic cleanup backend refused retirement";
     Mailbox.Cancelled,"cancelled before retirement acknowledgement";
     Mailbox.Shutdown,"worker stopped before retirement acknowledgement"])
    ["Observation release";"Observation finalization";"Binding unregister"];
  run "Import" (Mailbox.Failed "synthetic import transport lost") "synthetic import transport lost";
  require(!failures=[]) (String.concat "; " (List.rev !failures))
;;

let test_application_current_close ~replacement () =
  let third=uuid "9c000000-0000-4000-8000-000000000004"
  and fourth=uuid "9c000000-0000-4000-8000-000000000005" in
  let prepare root=List.iter(fun graph_id->
    let path=Filename.concat root("logseq-db-worker/synced-graphs/" ^ W.Uuid.to_string graph_id ^ "/db.sqlite") in
    seed_coordination_read_data ~assets:true path)[second_graph;third;fourth] in
  with_service_fixture ~favorites:true ~assets:true ~extra_graphs:[third;fourth] ~prepare (fun deps config ->
    let client=ref None and requests=Queue.create() in
    let calendar_sampler=Journal_calendar.Sampler.create ~clock:(fun()->1788048000.) ~localtime:Unix.gmtime () in
    let hooks=Application.For_testing.app_with_service ~calendar_sampler ~on_client:(fun value->client:=Some value)
      ~on_platform_request:(fun packet->Queue.add(Bytes.copy packet)requests)
      (Service.create ~dependencies:deps) in
    Fun.protect ~finally:(fun()->ignore(hooks.dispose());Option.iter Runtime.stop !client)(fun()->
      let controls=Hashtbl.create 128 and parents=Hashtbl.create 128 and appearances=Queue.create() in
      let selected=ref None and residents=ref [] in
      let rec drop id=
        Hashtbl.to_seq parents |> List.of_seq |> List.iter(fun(child,parent)->if parent=id then drop child);
        Hashtbl.remove parents id;Hashtbl.remove controls id in
      let patch_path=Filename.concat config.Logseq_db_worker.Config.application_support_directory "mounted-ui-patch.json" in
      let consume source=if source<>"" then (
        Out_channel.with_open_bin patch_path (fun out->output_string out source);
        let fields=function `Assoc fields->fields|_->failwith "invalid UI patch object" in
        let int=function `Int value->value|_->failwith "invalid UI patch node" in
        let ops=match List.assoc "ops" (fields(T.read_json patch_path))with
          |`List ops->ops|_->failwith "invalid UI patch operations" in
        List.iter(fun op->let fields=fields op in let get name=List.assoc name fields in
          match get "op" with
          |`String "create-extension"->
            Hashtbl.replace controls(int(get "id"))["_extension",(match get "identifier" with `String value->value|_->"")]
          |`String("drop-node"|"drop-extension"|"detach-subtree")->drop(int(get "id"))
          |`String("insert-child"|"move-child")->Hashtbl.replace parents(int(get "child"))(int(get "parent"))
          |`String"remove-child"->Hashtbl.remove parents(int(get "child"))
          |`String("set-prop"|"set-extension-prop")->
            let id=int(get "id") in
            (match get "property",get "value" with
             |`String "appear-enabled",`Bool true->Queue.add id appearances
             |`String key,`Bool value->
               let old=Option.value(Hashtbl.find_opt controls id) ~default:[] in
               Hashtbl.replace controls id ((key,string_of_bool value)::List.remove_assoc key old)
             |`String key,`String value->
               let old=Option.value(Hashtbl.find_opt controls id) ~default:[] in
               Hashtbl.replace controls id ((key,value)::List.remove_assoc key old)
             |_->())
          |_->())ops) in
      let rec mounted id= id=hooks.root_node() || match Hashtbl.find_opt parents id with None->false|Some parent->mounted parent in
      let find key value=Hashtbl.fold(fun id fields found->
        if mounted id && List.assoc_opt key fields=Some value then Some(max id(Option.value found ~default:0))else found)controls None in
      let native_authenticated=ref false and token_requested=ref false and registrations=ref 0 in
      let packet tag json=let packet=Bytes.make(32+String.length json)'\000' in
        Bytes.blit_string "LJP2" 0 packet 0 4;Bytes.set_uint16_le packet 4 2;
        Bytes.set_uint16_le packet 6 tag;Bytes.set_int32_le packet 24(Int32.of_int(String.length json));
        Bytes.blit_string json 0 packet 32(String.length json);Bytes.to_string packet in
      let answer_native ()=while not(Queue.is_empty requests)do
        let request=Queue.take requests in
        let response=match Bytes.get_uint16_le request 6 with
          |20->Some(21,"{\"userId\":\"user-1\",\"managedSyncOrigin\":\"https://api.logseq.io\"}")
          |6->Some(7,"{\"userId\":\"user-1\"}")
          |22->
            if not !native_authenticated then (
              native_authenticated:=true;
              let scope=Bytes.sub_string request 32 (Bytes.length request-32) in
              hooks.platform_event(packet 7("{\"userId\":\"user-1\",\"startupScope\":" ^ scope ^ "}")));
            Some(23,"{\"presented\":true}")
          |_->None in
        Option.iter(fun(tag,json)->hooks.platform_response(packet tag json))response
      done in
      let wait label predicate=
        let deadline=Unix.gettimeofday()+.5. in
        while not(predicate()) && Unix.gettimeofday()<deadline do answer_native();
          while not(Queue.is_empty appearances)do consume(hooks.dispatch(Appear(Queue.take appearances)))done;
          consume(hooks.pump());Thread.delay 0.001 done;
        require(predicate())label in
      let contains source part=let rec loop n= n+String.length part<=String.length source
        && (String.sub source n (String.length part)=part || loop(n+1)) in loop 0 in
      let rec current_host id=
        let fields=Option.value(Hashtbl.find_opt controls id)~default:[] in
        match List.assoc_opt "payload" fields with
        |Some payload when String.starts_with ~prefix:"{\"mode\":\"timeline-host\"" payload ->
          Option.fold ~none:false ~some:(fun graph->contains payload(W.Uuid.to_string graph))!selected
        |_->match Hashtbl.find_opt parents id with None->true|Some parent->current_host parent in
      let press key value=
        let clickable ()=Hashtbl.fold(fun id fields found->
          if mounted id && current_host id && List.assoc_opt key fields=Some value && List.assoc_opt "press-enabled" fields=Some "true"
          then Some id else found)controls None in
        wait ("missing control: " ^ value)(fun()->Option.is_some(clickable()));
        consume(hooks.dispatch(Press(Option.get(clickable())))) in
      consume(hooks.init 2 2 (Journal_startup.encode config |> Result.get_ok |> Bytes.to_string));
      let worker=Option.get !client in
      Mailbox.on_event worker(function Mailbox.Push{payload=Service.Client_state_changed state;_}->
        selected:=state.snapshot.selected_graph;residents:=state.snapshot.resident_graphs
        |Mailbox.Push{payload=Service.Need_id_token _;_}->token_requested:=true
        |Mailbox.Response{outcome=Completed(Service.Coordination_registered _);_}->incr registrations|_->());
      let send command=match Mailbox.send worker(Service.Client_command command)with
        |Mailbox.Accepted _->()|_->failwith "real app fixture command refused" in
      wait "real app restores first graph" (fun()-> !selected=Some Test_support.graph_uuid);
      send(Configure_resident_graphs[Test_support.graph_uuid;second_graph;third]);
      wait "real app admits three resident scopes" (fun()->List.length !residents=3);
      press "accessibility-label" "Favorites";
      press "text" "Switch graph";
      wait "native identity reaches the deliberately blocked token request" (fun()-> !token_requested);
      wait "same-user authentication rebind completes before the close action" (fun()-> !registrations>=2);
      if Option.is_none(find "accessibility-identifier" "graph-picker-list")then press "text" "Switch graph";
      List.iter(fun graph_id->
        press "accessibility-identifier" ("graph-picker:" ^ W.Uuid.to_string graph_id);
        wait "user selection becomes current" (fun()-> !selected=Some graph_id);
        wait "selection closes picker" (fun()->Option.is_none(find "accessibility-identifier" "graph-picker-list"));
        press "text" "Switch graph";
        wait "selected graph opens picker" (fun()->Option.is_some(find "accessibility-identifier" "graph-picker-list")))[second_graph;third];
      if replacement then (
        press "accessibility-identifier" ("graph-picker:" ^ W.Uuid.to_string fourth);
        press "accessibility-identifier" ("graph-resident-replace:" ^ W.Uuid.to_string third))
      else press "accessibility-identifier" ("graph-resident-remove:" ^ W.Uuid.to_string third);
      let target=if replacement then fourth else Test_support.graph_uuid in
      wait "real current close settles and selects retained/replacement graph" (fun()-> !selected=Some target && not(List.mem third !residents));
      press "text" "Switch graph";
      wait "retained graph responds to picker after retirement" (fun()->Option.is_some(find "accessibility-identifier" "graph-picker-list"));
      press "accessibility-identifier" "graph-picker-close";
      press "accessibility-label" "Journals";
      press "accessibility-identifier" "journal-capture-open";
      wait "current graph opens a real Capture editor after retirement" (fun()->Option.is_some(find "accessibility-identifier" "field.composer"))))
;;

(* Actual Service/DB/Sync ownership is not expressible by injecting Core
   completions. Exercise the real retained listener, close, consume and reopen. *)
let test_real_host_close_keeps_other_resident_and_reopens () =
  with_client(fun client->
    let events=Queue.create() and state=ref(C.initial ~client_id) in
    let runner=R.create ~client ~managed_origin:"https://api.logseq.io" ~user_id:"user-1"
      ~post:(fun event->Queue.add event events) ~publish:(fun _->()) |> Result.get_ok in
    let apply transition=state:=transition.C.next;List.iter(R.submit runner)transition.instructions in
    let host_responses=ref 0 in
    Mailbox.on_event client(fun event->
      let delivery=R.on_event runner event in
      match event with
      |Mailbox.Response{outcome=Completed(Service.Coordination_host_prepared _|Coordination_host_applied _);_}->
        incr host_responses;
        require(delivery.disposition=R.Consumed)"actual host receipt escaped its exclusive response owner"

      |_->());
    let pump()=Mailbox.Private.deliver client ~max_events:64;
      let count=Queue.length events in for _=1 to count do apply(C.step !state(Queue.take events)) done in
    let wait label predicate=
      let deadline=Unix.gettimeofday()+.4. in
      while not(predicate()) && Unix.gettimeofday()<deadline do pump();Thread.delay 0.001 done;
      require(predicate())label in
    ignore(Mailbox.send client(Service.Client_command(Restore_local_account{user_id="user-1"})));
    let open_sessions()=match C.projection(C.view !state)with None->[]|Some projection->
      W.residents projection |> List.filter_map(fun resident->if resident.W.phase=W.Open then Some resident.session else None) in
    wait "host initial actual DB did not open" (fun()->List.length(open_sessions())=1);
    ignore(Mailbox.send client(Service.Client_command(Configure_resident_graphs[Test_support.graph_uuid;second_graph])));
    wait "host two actual residents did not open" (fun()->List.length(open_sessions())=2);
    let first=List.find(fun session->W.graph_id session=Test_support.graph_uuid)(open_sessions())
    and second=List.find(fun session->W.graph_id session=second_graph)(open_sessions()) in
    let budget=W.read_budget first ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok in
    let observed,registration=C.request !state first(W.Observe(budget,W.Graph_info)) |> Result.get_ok in
    apply registration;wait "actual host listener not registered"(fun()->Option.is_some(C.reply(C.view !state)observed));
    let observation=match C.reply(C.view !state)observed with Some(W.Answered(Ok value))->value.W.observation
      |_->failwith "actual host observation did not sample" in
    let id,prepare=C.prepare_host_change !state(W.Graph_will_close(W.graph_id first)) |> Result.get_ok in
    apply prepare;
    let receipt=ref None in
    wait "actual host prepare did not settle"(fun()->match C.handoff(C.view !state)id with
      |Some(W.Safe_to_proceed value)->receipt:=Some value;true
      |Some(W.Handoff_failed(_,(W.Service_failed message|W.Protocol_mismatch message)))->failwith message
      |Some(W.Handoff_failed _)->failwith "actual host prepare failed"
      |_->false);
    require(C.observed(C.view !state)observation=None)"host Safe published before its listener retirement ACK";
    let query session=
      let budget=W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok in
      let ticket,transition=C.request !state session(W.Query(budget,W.Graph_info)) |> Result.get_ok in
      apply transition;wait "unrelated resident read did not finish"(fun()->Option.is_some(C.reply(C.view !state)ticket));
      let info=match C.reply(C.view !state)ticket with Some(W.Answered(Ok info))->info|_->failwith "actual host read failed" in
      apply(C.step !state(C.Forget ticket));info in
    require((query second).graph_uuid=second_graph)"closing first resident interrupted the other actual DB";
    let receipt=Option.get !receipt in
    apply(C.authorize_host_change !state receipt |> Result.get_ok);
    wait "actual host consume did not acknowledge"(fun()->match C.handoff(C.view !state)id with
      |Some(W.Host_change_applied _)->true
      |Some(W.Handoff_failed(_,(W.Service_failed message|W.Protocol_mismatch message)))->failwith message
      |Some(W.Handoff_failed _)->failwith "actual host consume failed"|_->false);
    require(C.validate_session !state first=Error W.Revoked_session)"actual consume revived its old execution";
    ignore(Mailbox.send client(Service.Client_command(Configure_resident_graphs[Test_support.graph_uuid;second_graph])));
    wait "actual graph could not reopen after consumed close"(fun()->List.length(open_sessions())=2);
    let reopened=List.find(fun session->W.graph_id session=Test_support.graph_uuid)(open_sessions()) in
    require(not(W.equal_session first reopened))"actual reopen reused old execution generation";
    require((query reopened).graph_uuid=Test_support.graph_uuid)"new execution remained fenced after close";
    require(Result.is_error(C.authorize_host_change !state receipt))"old safe permission consumed after real reopen";
    require(!host_responses=2)"host prepare/consume did not own exactly two real responses";
    apply(C.step !state C.Shutdown_requested);
    wait "real host coordination did not drain"(fun()->C.shutdown_state(C.view !state)=C.Stopped))
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
        ~maximum_bytes:Worker_pure_data.maximum_response_bytes
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
    let request_in session operation =
      let ticket, transition = C.request !state session operation |> Result.get_ok in
      apply transition;
      wait (fun () -> Option.is_some (C.reply (C.view !state) ticket));
      ticket, C.reply (C.view !state) ticket |> Option.get
    in
    let request operation=request_in session operation in
    let asset_consumer=W.asset_consumer session ~name:"runtime-synthetic-demand" |> Result.get_ok in
    let asset=Logseq_db_types.Asset_descriptor.create
      ~uuid:(uuid "9c000000-0000-4000-8000-000000000881") ~source:(Managed None)
      ~current_checksum:None ~size:None ~dimensions:None |> Result.get_ok in
    let before_demand=C.view !state in
    let demand_ticket,demand_reply=request(W.Replace_asset_demand(asset_consumer,W.Foreground,[asset])) in
    let asset_demand=match demand_reply with W.Answered(Ok demand)->demand
      |_->failwith "actual Service rejected typed scoped asset demand" in
    wait(fun()->List.exists(fun notice->match W.asset_notice_data notice with
      | Service.Asset_demand_accepted name->name="runtime-synthetic-demand"
      | _->false)(C.asset_notices(C.view !state)asset_demand));
    require(List.for_all(fun notice->Option.exists(W.equal_asset_consumer asset_consumer)(W.asset_notice_consumer notice))
      (C.asset_notices(C.view !state)asset_demand)) "actual asset push crossed consumer identity";
    require(Rrbvec.exists(fun notice->match W.asset_notice_data notice with
      |Service.Asset_demand_accepted name->name="runtime-synthetic-demand"|_->false)
      (C.asset_updates ~previous:(Some before_demand)(C.view !state)))
      "actual Service acceptance did not reach the typed asset outlet";
    let release_demand,released_demand=request(W.Release_asset_demand asset_demand) in
    require(released_demand=W.Answered(Ok())) "actual scoped asset demand retirement failed";
    require(C.asset_notices(C.view !state)asset_demand=[]) "retired actual asset demand retained data authority";
    apply(C.step !state(C.Forget demand_ticket));apply(C.step !state(C.Forget release_demand));
    let info_ticket, info = request (W.Query (budget, W.Graph_info)) in
    (match info with
     | W.Answered (Ok info) ->
       require
         (W.Uuid.equal info.graph_uuid Test_support.graph_uuid)
         "typed graph identity mismatch"
     | _ -> failwith "graph info failed");
    (* Actual client -> interpreter -> pure registration -> sampled read and ACK.
       The source values below come from Service, never a synthetic projection. *)
    let observed_ticket,observed_reply=request(W.Observe(budget,W.Graph_info)) in
    let observed=match observed_reply with
      | W.Answered(Ok value)->value
      | _->failwith "real App observation registration failed" in
    require(C.observation_handle(C.view !state) observed_ticket=Some observed.observation)
      "interpreter did not forward actual registration metadata";
    require(C.observed(C.view !state) observed.observation=Some observed)
      "real observed DTO did not reach pure retained state";
    apply(C.step !state(C.Forget observed_ticket));
    require(C.observed(C.view !state) observed.observation=Some observed)
      "host result disposal unregistered the live interest";
    let refresh,refreshed_reply=request(W.Refresh observed.observation) in
    let refreshed=match refreshed_reply with
      | W.Answered(Ok value)->value|_->failwith "real App Refresh failed" in
    require(W.compare_observation_epoch refreshed.epoch observed.epoch>0)
      "real Refresh did not advance the backend epoch";
    apply(C.step !state(C.Forget refresh));
    let released,released_reply=request(W.Release observed.observation) in
    require(released_reply=W.Answered(Ok())) "real Release did not receive a physical ACK";
    require(C.observed(C.view !state) observed.observation=None) "released interest remained visible";
    apply(C.step !state(C.Forget released));
    let tiny=W.read_budget session ~maximum_items:1 ~maximum_bytes:1 |> Result.get_ok in
    let failed_ticket,failed_reply=request(W.Observe(tiny,W.Graph_info)) in
    require(match failed_reply with W.Answered(Error _)->true|_->false)
      "tiny actual observation unexpectedly fit its byte budget";
    let failed_handle=match C.observation_handle(C.view !state) failed_ticket with
      | Some handle->handle|_->failwith "actual read error erased registration metadata" in
    let _,_=request(W.Release failed_handle) in
    apply(C.step !state(C.Forget failed_ticket));
    let cancel_ticket,cancel_plan=C.request !state session(W.Observe(budget,W.Graph_info)) |> Result.get_ok in
    apply cancel_plan;
    (* Admission is queued by the real interpreter, but has not yet been reduced. *)
    apply(C.step !state(C.Cancel cancel_ticket));
    wait(fun ()->C.reply(C.view !state) cancel_ticket<>None);
    wait(fun ()->List.exists(function
      | Mailbox.Response{outcome=Completed(Service.Coordination_observation_released value);_},R.Consumed ->
        W.equal_request_id(W.request_id value.observation_id)(C.ticket_id cancel_ticket)
      | _->false) !deliveries);
    require(C.observation_handle(C.view !state) cancel_ticket=None)
      "canceled registration adopted a late active handle";
    require(match C.reply(C.view !state) cancel_ticket with
      | Some(W.Interrupted W.Cancelled)->true|_->false)
      "canceled observation returned a successful sampled result";
    apply(C.step !state(C.Forget cancel_ticket));

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
    let business = Journal_graph_runtime.create ~validate_session:(fun session -> C.validate_session ~owner !state session) () in
    let original = Journal_graph_runtime.start business in
    require
      (Journal_graph_runtime.worker_read business (W.Uuid.of_string "98000000-0000-4000-8000-000000009999" |> Result.get_ok)=None)
      "an unplanned business request acquired a typed query";
    (match Journal_graph_runtime.worker_read business original with
     | Some (Journal_graph_runtime.Read read) ->
       let _, reply = request (W.Query (budget, read.query)) in
       (match reply with
        | W.Answered (Ok value) ->
          let output =
            Journal_graph_runtime.receive_worker_read
              business
              ~request_id:original
              (Journal_graph_runtime.Query_result(read.query,value))
          in
          require
            (List.exists
               (fun response ->
                  response.Journal_graph_runtime.payload
                  = Journal_graph_runtime.Graph_ready)
               output.responses)
            "typed graph info did not reach actual business projection"
        | _ -> failwith "typed business graph-info read failed")
     | Some (Journal_graph_runtime.Acknowledge _ | Confirm_readback _) -> failwith "graph-info dispatch became a non-query"
     | None -> failwith "business graph-info path was not migrated");
    let _, page =
      request
        (W.Query (budget, W.Page { uuid = Test_support.page_uuid; revision = None }))
    in
    (match page with
     | W.Answered (Ok (Worker_pure_data.V2_present_page { page; _ })) ->
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
    let summary_budget = W.read_budget session ~maximum_items:Worker_pure_data.maximum_page_size ~maximum_bytes:65536 |> Result.get_ok in
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
        | Worker_pure_data.V2_present_block { value; revision }, Some (Worker_pure_data.V2_present_page { page; _ }) ->
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
          (fun ~source_epoch:_ read query ->
            let original=uuid (Printf.sprintf "9c000000-0000-4000-8000-%012Ld" !clock) in
            planned := Some (read,query);
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
      let read, query = Option.get !planned in
      let _, reply = request (W.Query (budget, query)) in
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
                     (fun (item : Worker_pure_data.child_member) ->
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
        (fun request ->
           match Journal_graph_runtime.worker_read business request with
           | Some(Journal_graph_runtime.Read{query=W.Task_statuses _;_}) -> true
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
           let result = Journal_graph_runtime.Query_result(read.query,value) in
           let more =
             match result with
             | Journal_graph_runtime.Query_result(W.Task_statuses _,value) -> Option.is_some value.next
             | _ -> failwith "catalog result lost typed correspondence"
           in
           let output =
             Journal_graph_runtime.receive_worker_read
               business
               ~request_id:original
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
                 (fun request ->
                    match Journal_graph_runtime.worker_read business request with
                    | Some(Journal_graph_runtime.Read{query=W.Task_statuses _;_}) -> true
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
    (* Exercise production date/root/preview planning with actual Service reads.
       Root replies carry the exact pure coordinator origin through the adapter. *)
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
        (fun r ->
           match Journal_graph_runtime.worker_read business r with
           | Some(Journal_graph_runtime.Read{query=W.Journals _;_}) -> true
           | _ -> false)
        o.requests
    in
    let deliver_root original =
      match Journal_graph_runtime.worker_read business original with
      | Some (Journal_graph_runtime.Read read) ->
        let ticket, reply = request (W.Query (budget, read.query)) in
        (match reply with
         | W.Answered (Ok value) ->
           let result = Journal_graph_runtime.Query_result(read.query,value) in
           let items, next =
             match result with
             | Journal_graph_runtime.Query_result(W.Tree _,value) -> value.items, value.next
             | _ -> failwith "root lost typed result"
           in
           ( items
           , next
           , Journal_graph_runtime.receive_worker_read
               ?origin:(C.query_origin (C.view !state) ticket)
               business
               ~request_id:original
               result )
         | _ -> failwith "actual root query failed")
      | _ -> failwith "production root dispatch bypassed coordinator"
    in
    let seen = ref []
    and last_root = ref None in
    let rec date_page remaining original =
      match Journal_graph_runtime.worker_read business original with
      | Some (Journal_graph_runtime.Read read) ->
        require (read.maximum_items = 1) "date planner lost requested budget";
        let _, reply = request (W.Query (budget, read.query)) in
        (match reply with
         | W.Answered (Ok value) ->
           let result = Journal_graph_runtime.Query_result(read.query,value) in
           let items, more =
             match result with
             | Journal_graph_runtime.Query_result(W.Journals _,value) ->
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
               ~request_id:original
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
               (fun r ->
                  match Journal_graph_runtime.worker_read business r with
                  | Some(Journal_graph_runtime.Read{query=W.Tree _;_}) -> true
                  | _ -> false)
               output.requests
           in
           last_root := Some root;
           if remaining > 1
           then (
             require more "real first date page omitted continuation";
             let items, next_cursor, output = deliver_root root in
             require
               (items = [] && next_cursor = None)
               "synthetic first journal unexpectedly has roots";
             let next =
               List.find
                 (fun r ->
                    match Journal_graph_runtime.worker_read business r with
                    | Some(Journal_graph_runtime.Read{query=W.Journals _;_}) -> true
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
    let items, next, output = deliver_root root in
    require
      (List.length items = 1 && next = None)
      "synthetic preview root cardinality changed";
    let child_request output =
      List.find
        (fun r ->
           match Journal_graph_runtime.worker_read business r with
           | Some(Journal_graph_runtime.Read{query=W.Child_members _;_}) -> true
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
           let result = Journal_graph_runtime.Query_result(read.query,value) in
           let more =
             match result with
             | Journal_graph_runtime.Query_result(W.Child_members _,value) -> Option.is_some value.next
             | _ -> failwith "preview lost typed child result"
           in
           let output =
             Journal_graph_runtime.receive_worker_read
               business
               ~request_id:original
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
    let drive_feed ?(maximum_bytes = 65536) demand =
      let queue = Queue.create ()
      and responses = ref []
      and root_reads = ref [] in
      let add output =
        responses := List.rev_append output.Journal_graph_runtime.responses !responses;
        List.iter (fun request -> Queue.add request queue) output.requests
      in
      add (Journal_graph_runtime.submit business demand);
      let turns = ref 0 in
      while not (Queue.is_empty queue) do
        incr turns;
        require (!turns < 1000) "actual root quota read did not converge";
        let original = Queue.take queue in
        (match Journal_graph_runtime.worker_read business original with
         | Some(Journal_graph_runtime.Read{query=W.Tree _;maximum_items=limit}) -> root_reads := limit :: !root_reads
         | _ -> ());
        match Journal_graph_runtime.worker_read business original with
        | Some (Journal_graph_runtime.Read read) ->
          let budget =
            W.read_budget session ~maximum_items:read.maximum_items ~maximum_bytes
            |> Result.get_ok
          in
          let ticket, reply = request (W.Query (budget, read.query)) in
          (match reply with
           | W.Answered (Ok value) ->
             add
               (Journal_graph_runtime.receive_worker_read
                  ?origin:(C.query_origin (C.view !state) ticket)
                  business
                  ~request_id:original
                  (Journal_graph_runtime.Query_result(read.query,value)))
           | _ -> failwith "actual root quota typed query failed")
        | _ -> failwith "actual root quota path bypassed coordinator"
      done;
      let feed =
        List.find_map
          (fun response ->
             match response.Journal_graph_runtime.payload with
             | Feed_loaded { complete = true; feed; _ } -> Some feed
             | _ -> None)
          !responses
        |> Option.get
      in
      feed, List.rev !root_reads
    in
    let first, reads =
      drive_feed
        (Load_feed
           { cursor = Some { before_day = Some 20260830; skipped_day = None }
           ; root_limit = 30
           ; day_limit = 1
           ; request_generation = 330L
           })
    in
    require (reads = [ 30; 30 ]) "actual Tree continuation changed the sealed item budget";
    let day = List.hd first.days in
    require (List.length day.entries = 30) "actual first Tree page exceeded visible quota";
    (match (Option.get day.continuation).protocol_cursor with
     | Some (Journal_graph_projection.Root_tree_cursor cursor) ->
       require
         (cursor.after = None && Rrbvec.length cursor.remaining = 10)
         "actual final DB page did not retain its bounded over-read tail"
     | _ -> failwith "actual root cursor lost execution provenance");
    let second, reads =
      drive_feed
        (Load_day_blocks
           { day = day.page.day
           ; after = day.continuation
           ; limit = 30
           ; request_generation = 331L
           })
    in
    require (reads = []) "retained final-page roots unnecessarily reread the DB";
    let entries =
      List.concat_map
        (fun (day : Journal_graph_projection.day_feed) -> day.entries)
        second.days
    in
    require
      (List.length entries = 10 && second.continuation = None)
      "actual retained final-page tail did not exhaust exactly";
    let all =
      day.entries @ entries
      |> List.map (fun (entry : Journal_graph_projection.timeline_entry) ->
        Journal_model.id entry.block)
    in
    require
      (List.length (List.sort_uniq String.compare all) = 40)
      "actual final-page Tree tail lost or repeated visible roots";
    let first, reads =
      drive_feed
        ~maximum_bytes:16384
        (Load_feed
           { cursor = Some { before_day = Some 20260901; skipped_day = None }
           ; root_limit = 30
           ; day_limit = 1
           ; request_generation = 332L
           })
    in
    require
      (reads <> [] && List.for_all (( = ) 30) reads)
      "byte-budget fixture changed the sealed item budget";
    let day = List.hd first.days in
    require
      (List.length day.entries = 30 && day.continuation <> None)
      "byte-budget first page lost continuation";
    let second, reads =
      drive_feed
        ~maximum_bytes:16384
        (Load_day_blocks
           { day = day.page.day
           ; after = day.continuation
           ; limit = 30
           ; request_generation = 333L
           })
    in
    require
      (List.length reads > 1 && List.for_all (( = ) 30) reads)
      "server changed the client's sealed item budget while fitting encoded bytes";
    let day = List.hd second.days in
    require
      (List.length day.entries = 30 && day.continuation = None)
      "byte-bounded continuation did not drain all thirty large DTOs";
    require
      (List.for_all
         (fun (entry : Journal_graph_projection.timeline_entry) ->
            String.length (Journal_model.source entry.block) >= 3001)
         day.entries)
      "byte fitting truncated canonical DTO source text";
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
          (fun r ->
             match Journal_graph_runtime.worker_read business r with
             | Some(Journal_graph_runtime.Read{query=W.Favorites _;_}) -> true
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
               ~request_id:original
               (Journal_graph_runtime.Query_result(read.query,value))
           in
           List.iter (fun r -> match Journal_graph_runtime.worker_read business r with
             | Some(Journal_graph_runtime.Read{query=W.Child_members{parent;_};_}) when W.Uuid.equal parent favorite_page_id -> membership:=Some r
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
      (List.length first.items = 1 && Option.is_some first.next)
      (Printf.sprintf
         "first Favorites page lost Partial continuation: items=%d more=%b page=%s"
         (List.length first.items)
         (Option.is_some first.next)
         (Option.fold ~none:"none" ~some:W.Uuid.to_string first.favorites_page));
    require
      ((List.nth first.items 0).membership_uuid = favorite_member 1)
      "first real Favorites membership changed";
    let second =
      read_favorites
        { favorites_request with request_generation = 311L; cursor = first.next }
    in
    require
      (List.length second.items = 1 && second.next = None)
      "second Favorites page inferred completeness incorrectly";
    require
      ((List.nth second.items 0).membership_uuid = favorite_member 2)
      "actual second wire request did not retain the sealed backend continuation";
    let rec membership_page page seen original =
      require (page < 10) "actual Favorite memberships did not terminate";
      match Journal_graph_runtime.worker_read business original with
      | Some (Journal_graph_runtime.Read read) ->
        let _, reply = request_query (W.Query (budget, read.query)) in
        (match reply with
         | W.Answered (Ok value) ->
           let result = Journal_graph_runtime.Query_result(read.query,value) in
           let items, more =
             match result with
             | Journal_graph_runtime.Query_result(W.Child_members _,value) ->
               value.items, Option.is_some value.next
             | _ -> failwith "Favorite membership lost typed result"
           in
           let seen =
             seen @ List.map (fun (item : Worker_pure_data.child_member) -> item.value.block.uuid) items
           in
           let output =
             Journal_graph_runtime.receive_worker_read
               business
               ~request_id:original
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
              (fun r ->
                 match Journal_graph_runtime.worker_read business r with
                 | Some(Journal_graph_runtime.Read{query=W.Outline_block _;_}) | Some(Journal_graph_runtime.Read{query=W.Page _;_}) | Some(Journal_graph_runtime.Read{query=W.Child_members _;_}) -> true
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
                     ~request_id:original
                     (Journal_graph_runtime.Query_result(read.query,value)))
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
      | W.Answered (Ok { lookup = Worker_pure_data.V2_present_block { revision; _ }; _ }) -> revision
      | _ -> assert false
    in
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
    let wire = W.encode_durable_intent(W.Mutation_intent intent) in
    let restored = W.restore_durable_intent session wire |> Result.get_ok in
    require
      (W.encode_durable_intent restored = wire)
      "complete mutation changed on restore";
    let observed_block_ticket,observed_block_reply=request(W.Observe(budget,
      W.Outline_block{uuid=Test_support.authoritative_block_uuid;revision=None})) in
    let observed_block=match observed_block_reply with
      | W.Answered(Ok value)->value|_->failwith "actual block observation failed" in
    let module Detail_observation=Journal_detail.Pure_observation in
    let context:Detail_observation.context={entry_id="actual-service-detail";
      request_generation=350L;root=Test_support.authoritative_block_uuid;owner;maximum_children=128;
      original=uuid "9c000000-0000-4000-8000-0000000000d0"} in
    let presentation_model,_=Detail_observation.planned Detail_observation.empty context observed_block_ticket in
    let presentation_model,initial_effects=Detail_observation.inspect presentation_model(C.view !state) in
    require(Rrbvec.exists(function Detail_observation.Initial(_,sample)->
      (match sample.value with Worker_pure_data.V2_present_block{value;_}->value.block.title="Authoritative block"|_->false)
      | _->false)initial_effects) "actual Service sample did not reach the pure Detail outlet";
    apply(C.step !state(C.Forget observed_block_ticket));
    let mutation_ticket, mutation_reply = request (W.Mutate intent) in
    let receipt =
      match mutation_reply with
      | W.Answered (Ok (W.Submission_committed receipt)) -> receipt
      | _ -> failwith "real durable mutation did not return commit evidence"
    in
    wait(fun ()->match C.observed(C.view !state) observed_block.observation with
      | Some {value=Worker_pure_data.V2_present_block {value;_};_}->value.block.title="Durable coordinated edit"
      | _->false);
    let observed_after=Option.get(C.observed(C.view !state) observed_block.observation) in
    require(W.compare_observation_epoch observed_after.epoch observed_block.epoch>0)
      "actual write invalidation did not advance retained observation";
    let presentation_model,update_effects=Detail_observation.inspect presentation_model(C.view !state) in
    let actual=Rrbvec.find_opt(function Detail_observation.Updated _->true|_->false)update_effects |> Option.get in
    let sample=match actual with Detail_observation.Updated(_,sample)->sample|_->assert false in
    let business_request=Journal_graph_runtime.plan_observed_block business ~root:context.root in
    let applied=Journal_graph_runtime.receive_worker_read business ~request_id:business_request
      ~origin:(W.observation_session sample.observation,W.observation_budget sample.observation)
      (Journal_graph_runtime.Query_result(W.Outline_block{uuid=context.root;revision=None},sample.value)) in
    require(List.exists(fun response->match response.Journal_graph_runtime.payload with
      | Block_updated{block;_}->Journal_model.id block=W.Uuid.to_string context.root
        && Journal_model.source block="Durable coordinated edit"
      | _->false)applied.responses) "actual observed DTO did not enter the existing Detail projection";
    let presentation_model,cleanup=Detail_observation.retain presentation_model Rrbvec.empty in
    require(Detail_observation.context_count presentation_model=0) "retired actual Detail kept presentation ownership";
    let handle=Rrbvec.find_opt(function Detail_observation.Release _->true|_->false)cleanup |> Option.get
      |> function Detail_observation.Release handle->handle|_->assert false in
    require(W.same_observation handle observed_block.observation<>None) "actual Detail cleanup changed registration";
    let release_ticket,released=request(W.Release handle) in
    require(released=W.Answered(Ok())) "updated observation did not physically release";
    apply(C.step !state(C.Forget release_ticket));
    let original = W.receipt_revisions receipt in
    require
      (Rrbvec.to_list (W.receipt_targets receipt)
       = [ Test_support.authoritative_block_uuid ])
      "durable receipt lost canonical target";
    apply (C.step !state (C.Forget mutation_ticket));
    require
      (Option.is_some (C.intent_progress (C.view !state)(W.Mutation_intent intent)))
      "forgetting ticket erased durable outcome";
    let _, again = request (match restored with W.Mutation_intent intent->W.Mutate intent|Append_intent intent->W.Append intent) in
    (match again with
     | W.Answered (Ok (W.Submission_committed repeated)) ->
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
     | W.Answered (Ok (Worker_pure_data.V2_present_block { value; _ })) ->
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
     | W.Answered (Ok confirmation) ->
       require
         (W.receipt_revisions (W.confirmation_receipt confirmation) = original)
         "confirmation replaced original commit point";
       (match W.confirmation_primary confirmation with
        | W.Confirmed_block summary ->
          require (Option.is_some summary.page) "confirmation lost atomic owning page";
          (match summary.lookup with
           | Worker_pure_data.V2_present_block { value; _ } ->
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
    (match C.intent_progress (C.view !state)(W.Mutation_intent intent) with
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
     | W.Answered (Ok _) -> ()
     | _ -> failwith "new explicit Confirm could not use preserved receipt");
    let source_file=Filename.temp_file "journal-coordination-synthetic-import-" ".png" in
    Out_channel.with_open_bin source_file(fun output->output_string output "file");
    let source:Logseq_db_types.Asset_import.t=
      {operation=uuid "9c000000-0000-4000-8000-000000000885";
       asset=uuid "9c000000-0000-4000-8000-000000000886";target=Test_support.authoritative_block_uuid;
       replace_reference=None;local_mutation=uuid "9c000000-0000-4000-8000-000000000887";
       metadata_mutation=uuid "9c000000-0000-4000-8000-000000000888";
       source_file;title="Synthetic typed import";file_type="png"} in
    let import_bytes,original_import_asset=Fun.protect ~finally:(fun()->if Sys.file_exists source_file then Sys.remove source_file)(fun()->
      let intent=W.asset_import_intent session source |> Result.get_ok in
      let imported_ticket,reply=request(W.Import intent) in
      let imported=match reply with W.Answered(Ok(W.Imported imported))->imported
        |W.Answered(Error(W.Service_failed message))->failwith("actual typed import failed: "^message)
        |_->failwith "actual typed import did not return its durable source receipt" in
      let ordinary_consumer=W.asset_consumer session ~name:"media:actual-imported-bytes" |> Result.get_ok in
      let demand,demand_reply=request(W.Replace_asset_demand(ordinary_consumer,W.Foreground,[(W.import_data imported).asset])) in
      let ordinary_handle=match demand_reply with W.Answered(Ok demand)->demand
        |_->failwith "ordinary typed demand did not reach the actual Service" in
      let active_handle=ref ordinary_handle in
      let ordinary_file()=List.find_map W.ready_asset_file(C.asset_notices(C.view !state) !active_handle) in
      wait(fun()->Option.is_some(ordinary_file()));
      let ordinary_acquire,ordinary_reply=request(W.Acquire_asset_file(Option.get(ordinary_file()))) in
      let ordinary_lease=match ordinary_reply with W.Answered(Ok(Some lease))->lease
        |_->failwith "ordinary Ready capability did not acquire actual retained bytes" in
      require(In_channel.with_open_bin(W.file_path ordinary_lease)In_channel.input_all="file")
        "ordinary typed acquisition did not retain the imported local version";
      let module Descriptor=Logseq_db_types.Asset_descriptor in
      let remote_version=Descriptor.version
        ~checksum:(Logseq_sync_effect_runner.Asset_codec.checksum "synthetic published second version")
        ~file_type:"png" |> Result.get_ok in
      let changed=Descriptor.create ~uuid:source.asset ~source:(Managed(Some remote_version))
        ~current_checksum:None ~size:None ~dimensions:None |> Result.get_ok in
      let replacement_demand,replacement_reply=request(W.Replace_asset_demand(ordinary_consumer,W.Foreground,[changed])) in
      let replacement_handle=match replacement_reply with W.Answered(Ok demand)->demand
        |_->failwith "same-UUID remote version did not replace its typed demand" in
      active_handle:=replacement_handle;
      wait(fun()->List.exists(fun notice->match W.asset_notice_data notice with
        |Service.Asset_availability{descriptor;_}->descriptor=changed|_->false)
        (C.asset_notices(C.view !state)replacement_handle));
      require(ordinary_file()=None) "new remote version incorrectly adopted the cached old Ready";
      require(In_channel.with_open_bin(W.file_path ordinary_lease)In_channel.input_all="file")
        "replacing the transfer version released the renderer's independent old lease";
      let ordinary_release,ordinary_released=request(W.Release_file ordinary_lease) in
      require(ordinary_released=W.Answered(Ok())) "ordinary display lease did not acknowledge its physical release";
      let demand_release,demand_released=request(W.Release_asset_demand replacement_handle) in
      require(demand_released=W.Answered(Ok())) "ordinary demand did not settle its physical transfer owner";
      apply(C.step !state(C.Forget demand));apply(C.step !state(C.Forget replacement_demand));
      apply(C.step !state(C.Forget ordinary_release));apply(C.step !state(C.Forget demand_release));
      apply(C.step !state(C.Forget ordinary_acquire));
      let preview=W.import_preview imported |> Option.get in
      require(Sys.file_exists(W.file_path preview)) "actual imported preview did not own staged bytes";
      require((W.import_data imported).operation=source.operation) "actual import changed its stable operation";
      Sys.remove source_file;
      let acquire,reply=request(W.Acquire_imported_file imported) in
      let retained=match reply with W.Answered(Ok(Some lease))->lease|_->failwith "actual imported source could not be re-retained after picker removal" in
      require(W.file_lease_id retained<>W.file_lease_id preview) "two real acquisitions shared one lease identity";
      let release,reply=request(W.Release_file retained) in
      require(reply=W.Answered(Ok())) "actual retained lease release did not ACK";
      let released_previews=ref [] in
      let media=Journal_media_runtime.create ~read:(fun _->false)
        ~release_file:(fun lease->released_previews:=lease::!released_previews;true)
        ~release_consumer:(fun _->failwith "preview-only fixture emitted a display release")
        ~demand:(fun ~graph_generation:_ ~name:_ _ _->failwith "preview-only fixture emitted a display demand")
        ~acquire:(fun _ _->failwith "preview-only fixture acquired a display file")
        ~retry_asset:(fun ~graph_generation:_ _->failwith "preview-only fixture retried a network asset")
        ~changed:(fun _ _->())() in
      Journal_media_runtime.reset media ~graph_generation:(Some(W.import_data imported).graph_generation);
      Journal_media_runtime.imported media ~current:true imported;
      Journal_media_runtime.retire_coordinated_previews media;
      Journal_media_runtime.reset media ~graph_generation:None;
      require(List.length !released_previews=1)"binding cleanup and later reset released the same preview twice";
      require(List.exists(fun lease->W.file_lease_id lease=W.file_lease_id preview)!released_previews)
        "typed Media preview cleanup lost its original lease";
      let release_preview,reply=request(W.Release_file preview) in
      require(reply=W.Answered(Ok())) "actual preview lease release did not ACK";
      apply(C.step !state(C.Forget imported_ticket));apply(C.step !state(C.Forget acquire));
      apply(C.step !state(C.Forget release));apply(C.step !state(C.Forget release_preview));
      W.encode_asset_import_intent intent,(W.import_data imported).asset) in
    let source_page,source_reply=request(W.Recover_import_inputs{after=None;maximum_items=2;maximum_bytes=65536}) in
    let source_rows=match source_reply with W.Answered(Ok page)->page.inputs|_->failwith "actual Service source recovery failed" in
    require(Rrbvec.length source_rows=1)"actual source recovery lost its original input";
    let original_source=Rrbvec.nth source_rows 0 in
    require(W.encode_asset_import_intent original_source.intent=import_bytes && original_source.prepared<>None && not original_source.acknowledged)
      "actual source recovery changed original input or Prepared membership";
    let old_source_proof=Option.get original_source.prepared in
    apply(C.step !state(C.Forget source_page));
    apply (C.step !state C.Retry_bootstrap);
    require
      (Result.is_error (C.request !state session (W.Query (budget, W.Graph_info))))
      "retry admitted old session";
    wait (fun () ->
      Option.fold
        ~none:false
        ~some:(fun next -> not (W.equal_session next session))
        (current_session ()));
    let replacement = Option.get (current_session ()) in
    let restored_import=W.restore_asset_import_intent replacement import_bytes |> Result.get_ok in
    require(Result.is_error(C.request !state replacement(W.Acknowledge_import_source old_source_proof)))
      "old source proof authorized ACK across binding replacement";
    let source_check,source_reply=request_in replacement(W.Confirm_import_source restored_import) in
    let original_source=match source_reply with W.Answered(Ok(Some item))->item|_->failwith "cold read-only original source confirmation failed" in
    require(W.encode_asset_import_intent original_source.intent=import_bytes && not original_source.acknowledged)
      "cold source confirmation replaced input or fabricated ACK";
    let current_proof=Option.get original_source.prepared in
    require(W.import_source_proof_matches restored_import(W.prepared_import_adoption current_proof))
      "cold source proof lost the exact original input adoption identity";
    apply(C.step !state(C.Forget source_check));
    let source_ack,source_reply=request_in replacement(W.Acknowledge_import_source current_proof) in
    require(source_reply=W.Answered(Ok()))"actual source proof ACK failed";
    apply(C.step !state(C.Forget source_ack));
    let pending_sources,source_reply=request_in replacement(W.Recover_import_inputs{after=None;maximum_items=2;maximum_bytes=65536}) in
    require(match source_reply with W.Answered(Ok page)->Rrbvec.is_empty page.inputs && page.continuation=None|_->false)
      "actual source ACK retained pending membership or fabricated More";
    apply(C.step !state(C.Forget pending_sources));
    let original_check,source_reply=request_in replacement(W.Confirm_import_source restored_import) in
    require(match source_reply with W.Answered(Ok(Some item))->item.acknowledged && item.prepared<>None
      && W.encode_asset_import_intent item.intent=import_bytes|_->false)
      "actual ACK erased the original Prepared proof or complete input";
    apply(C.step !state(C.Forget original_check));
    let restored_ticket,restored_reply=request_in replacement(W.Import restored_import) in
    let restored_imported=match restored_reply with W.Answered(Ok(W.Imported imported))->imported
      |_->failwith "new binding could not reconcile the original staged import after picker removal" in
    require((W.import_data restored_imported).asset=original_import_asset) "import reconciliation changed original descriptor/source bytes";
    require((W.import_data restored_imported).operation=source.operation && (W.import_data restored_imported).target=source.target)
      "import reconciliation changed original operation or target";
    let preview=W.import_preview restored_imported |> Option.get in
    require(Sys.file_exists(W.file_path preview)) "reconciled import lost durable staged source";
    let released,reply=request_in replacement(W.Release_file preview) in
    require(reply=W.Answered(Ok())) "new-binding source preview did not physically release";
    apply(C.step !state(C.Forget restored_ticket));apply(C.step !state(C.Forget released));
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

let test_read_completion_rechecks_graph_owner () =
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
                 | Service.Coordination_snapshot value -> remember_baseline baseline value
                 | _ -> ())
               updates
           | _ -> ());
         let wait stage predicate =
           let deadline = Unix.gettimeofday () +. 4. in
           while (not (predicate ())) && Unix.gettimeofday () < deadline do
             Mailbox.Private.deliver client ~max_events:64;
             Thread.delay 0.001
           done;
           require (predicate ()) ("Service completion ownership race did not settle: " ^ stage)
         in
         let send request =
           match Mailbox.send client request with
           | Accepted id -> id
           | _ -> failwith "race request not admitted"
         in
         let registration = 900000L in
         let id = send (Service.Register_coordination registration) in
         wait "registration" (fun () -> Hashtbl.mem responses id);
         ignore
           (send (Service.Client_command (Restore_local_account { user_id = "user-1" })));
         (* The worker can publish Open before this test consumes the retained
            registration result. Exercise that real delivery order explicitly. *)
         wait "live graph open before retained registration" (fun () ->
           Option.exists (fun value ->
             List.exists (fun (_, state) ->
               state.Logseq_db_worker.phase = Logseq_db_worker.Graph_open)
               value.Service.baseline.state.residents) !baseline);
         (match Hashtbl.find responses id with
          | Completed (Service.Coordination_registered value) -> remember_baseline baseline value
          | _ -> assert false);
         wait "initial graph open" (fun () ->
           match !baseline with
           | Some value ->
             List.exists
               (fun (_, state) ->
                  state.Logseq_db_worker.phase = Logseq_db_worker.Graph_open)
               value.baseline.state.residents
           | _ -> false);
         let owner = Option.get (Option.get !baseline).baseline.state.sync.selected in
         let read=send(query_request client !baseline owner registration
           (uuid "99000000-0000-4000-8000-000000000001") ~maximum_bytes:Worker_pure_data.maximum_response_bytes
           (Read.Outline_block{uuid=Test_support.authoritative_block_uuid;revision=None})) in
         wait "initial block read" (fun () -> Hashtbl.mem responses read);
         let revision =
           match Hashtbl.find responses read with
           |Completed(Service.Coordination_queried{answer=Read.Query_answer(_,Read.Outline_block _,Ok(Worker_pure_data.V2_present_block{revision;_}));_})
             -> revision
           | _ -> failwith "race fixture block missing"
         in
         Atomic.set armed true;
         let module Wire=Logseq_db_worker_contract.Worker_pure_mutation in
         let wire=Wire.create_mutation ~origin:(Uri.of_string "https://api.logseq.io")
           ~user:"user-1" ~graph:Test_support.graph_uuid
           ~mutation_id:(uuid "99000000-0000-4000-8000-000000000003")
           (Wire.Save_block{block=Test_support.authoritative_block_uuid;title="Synthetic held writer";
             preconditions={blocks=[Test_support.authoritative_block_uuid,revision];pages=[];scopes=[]}})
           |>Result.get_ok |>fun intent->Wire.Mutation_intent intent in
         let writer=send(Service.Coordination_mutation{registration;owner;
           request_id=uuid "99000000-0000-4000-8000-000000000002";intent=wire})in
         wait "writer entered DB gate" (fun () -> Atomic.get entered);
         let read=send(query_request client !baseline owner registration
           (uuid "99000000-0000-4000-8000-000000000004") Read.Graph_info)in
         (* Cancelling the outer writer releases its Service lane, not its
            accepted durable DB operation. Keep that operation held while the
            second lane is waiting on the real snapshot mutex. *)
         Mailbox.cancel client ~request_id:writer;

         wait "read request fiber started" (fun () ->
           (Mailbox.Private.metrics (Mailbox.Private.pack_client client))
             .active_request_fibers
           > 0);
         require
           (not (Hashtbl.mem responses read))
           "read did not wait behind actual writer";
         ignore (send (Service.Client_command Return_to_graph_picker));
         wait "graph picker published" (fun () ->
           match !baseline with
           | Some value -> value.baseline.state.sync.selected = None
           | _ -> false);
         Atomic.set release true;
         wait "retired read completion" (fun () -> Hashtbl.mem responses read);
         require
           (match Hashtbl.find responses read with
            | Failed _ -> true
            | _ -> false)
           "retired graph read completion still crossed Service's authority gate";
         (
           wait "cancelled writer completion" (fun () -> Hashtbl.mem responses writer);
           require
             (Hashtbl.find responses writer = Mailbox.Cancelled)
             "cancelled durable attempt was reported as known rollback";
           Atomic.set armed false;
           ignore (send (Service.Client_command (Select_graph Test_support.graph_uuid)));
           wait "replacement graph open" (fun () ->
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
                  ; request_id = uuid "99000000-0000-4000-8000-000000000004"
                  ; intent = wire
                  })
           in
           wait "same intent reconciliation" (fun () -> Hashtbl.mem responses retry);
           match Hashtbl.find responses retry with
           | Completed
               (Service.Coordination_mutation_result
                  { outcome =
                      Wire.Committed committed
                  ; _
                  }) ->
             require
               (committed.status = Worker_pure_data.V2_applied)
               "unknown write replay invented Already_applied/current revision";
             require
               (committed.before
                <> committed.after)
               "unknown accepted write lost original commit evidence"
           | _ -> failwith "durable unknown did not reconcile across close/reopen")))
;;

let test_host_durable_recovery_confirmation_ack () =
  let module Host=Journal_worker_coordination_host in
  with_client ~statuses:true ~prepare:prepare_atomic_append_fixture(fun client->
    let jobs=Queue.create() in
    let host=Host.create ~client ~client_id ~managed_origin:"https://api.logseq.io" ~user_id:"user-1"
      ~enqueue:(fun job->Queue.add job jobs) ~changed:(fun _->()) |> Result.get_ok in
    let consumed=ref 0 in
    Mailbox.on_event client(fun event->let delivery=Host.on_event host event in
      if delivery.R.disposition=R.Consumed then incr consumed);
    let pump()=Mailbox.Private.deliver client ~max_events:64;
      let count=Queue.length jobs in for _=1 to count do (Queue.take jobs)() done in
    let wait predicate=let deadline=Unix.gettimeofday()+.6. in
      while not(predicate()) && Unix.gettimeofday()<deadline do pump();Thread.delay 0.001 done;
      require(predicate()) "typed durable lifecycle did not settle" in
    ignore(Mailbox.send client(Service.Client_command(Restore_local_account{user_id="user-1"})));
    wait(fun()->Option.exists(fun projection->Option.is_some(W.selected projection)
      && List.exists(fun resident->resident.W.phase=W.Open)(W.residents projection))
      (C.projection(Host.view host)));
    let presentation=Option.get(Option.bind(C.projection(Host.view host))W.selected) in
    let session=W.presentation_session presentation in
    let call_in : type a. W.session -> a W.request -> a W.reply = fun session operation->
      let before= !consumed in
      let ticket=Host.request host session operation |> Result.get_ok in
      let result=ref None in
      Host.watch host ticket ~f:(fun reply->result:=Some reply);
      require(!result=None) "typed durable callback recursively completed admission";
      wait(fun()-> !result<>None);
      require(!consumed=before+1) "typed lifecycle response has duplicate or missing owner";
      Option.get !result in
    let call : type a. a W.request -> a W.reply = fun operation->call_in session operation in
    let value : type a. a W.reply -> a = function W.Answered(Ok value)->value|_->failwith "typed lifecycle operation failed" in
    let budget=W.read_budget session ~maximum_items:8 ~maximum_bytes:16384 |> Result.get_ok in
    let read()=value(call(W.Query(budget,W.Outline_block{uuid=Test_support.authoritative_block_uuid;revision=None}))) in
    let revision=match read() with Worker_pure_data.V2_present_block{revision;_}->revision|_->assert false in
    let intent=W.mutation_intent session ~mutation_id:(uuid "9f000000-0000-4000-8000-000000001000")
      (W.Save_block{block=Test_support.authoritative_block_uuid;title="Typed applied readback";
        preconditions={blocks=[Test_support.authoritative_block_uuid,revision];pages=[];scopes=[]}}) |> Result.get_ok in
    let receipt=match value(call(W.Mutate intent)) with W.Submission_committed receipt->receipt|_->failwith "typed write lost proof" in
    require(Result.is_error(Host.request host session(W.Acknowledge_intent(W.Mutation_intent intent)))) "typed unconfirmed commit admitted ACK";
    let recover()=value(call(W.Recover_mutations{after=None;maximum_items=8;maximum_bytes=W.maximum_mutation_recovery_bytes})) in
    let page=recover() in
    require(Rrbvec.length page.items=1) "typed recovery lost the persisted intent";
    require(match(Rrbvec.nth page.items 0).progress with W.Committed_pending_presentation actual->
      W.receipt_revisions actual=W.receipt_revisions receipt|_->false) "typed recovery replaced original proof";
    let confirmation=value(call(W.Confirm(presentation,receipt))) in
    let ui_applied=match W.confirmation_primary confirmation with
      | W.Confirmed_block{lookup=Worker_pure_data.V2_present_block{value;_};_}->value.block.title="Typed applied readback"
      | _->false in
    require ui_applied "canonical DTO was not applied to the consuming projection";
    ignore(value(call(W.Acknowledge_intent(W.Mutation_intent intent))));
    require(C.intent_progress(Host.view host)(W.Mutation_intent intent)=None) "actual typed ACK did not retire pure ownership";
    require(Rrbvec.is_empty(recover()).items) "actual typed ACK did not settle database recovery entry";
    let before=read() in
    require(match value(call(W.Mutate intent)) with W.Submission_committed original->
      W.receipt_revisions original=W.receipt_revisions receipt|_->false) "typed ACK removed original idempotency proof";
    require(read()=before) "typed same-intent reconciliation executed a second write";
    let revision=match read() with Worker_pure_data.V2_present_block{revision;_}->revision|_->assert false in
    let status=Test_support.status_uuid 2 in
    let status_intent=W.mutation_intent session ~mutation_id:(uuid "9f000000-0000-4000-8000-000000001001")
      (W.Set_task_status{block=Test_support.authoritative_block_uuid;status;
        preconditions={blocks=[Test_support.authoritative_block_uuid,revision];pages=[];scopes=[]}}) |> Result.get_ok in
    let status_receipt=match value(call(W.Mutate status_intent)) with
      | W.Submission_committed receipt->receipt|_->failwith "real typed status commit failed" in
    let status_confirmation=value(call(W.Confirm(presentation,status_receipt))) in
    require(match W.confirmation_primary status_confirmation with
      | W.Confirmed_block{lookup=Worker_pure_data.V2_present_block{value;_};_}->value.task_status=Some status
      | _->false) "real canonical DTO lost committed status UUID";
    ignore(value(call(W.Acknowledge_intent(W.Mutation_intent status_intent))));
    require(Rrbvec.is_empty(recover()).items) "real status ACK retained pending recovery entry";
    let completed_appends=ref Rrbvec.empty in
    List.iteri(fun index day->
      let root_id=uuid(Printf.sprintf "9f000000-0000-4000-8000-%012d" (2000+index*10)) in
      let child_id=uuid(Printf.sprintf "9f000000-0000-4000-8000-%012d" (2001+index*10)) in
      let append=W.append_intent session ~mutation_id:(uuid(Printf.sprintf "9f000000-0000-4000-8000-%012d" (2002+index*10)))
        ~block_id:root_id ~day:(W.journal_day day |> Result.get_ok) ~title:"Atomic Service root 中文"
        ~task_status:(Some status) ~children:(Rrbvec.singleton Worker_pure_data.{block_id=child_id;title="Atomic Service child";
          task_status=Some(Test_support.status_uuid 3);children=Rrbvec.empty}) |> Result.get_ok in
      let receipt=match value(call(W.Append append)) with
        | W.Submission_committed receipt->receipt|_->failwith "actual Append did not commit atomically" in
      require(Rrbvec.length(W.receipt_targets receipt)=2) "Append receipt lost complete immutable targets";
      let confirmation=value(call(W.Confirm(presentation,receipt))) in
      let summary=match W.confirmation_primary confirmation with W.Confirmed_block summary->summary
        |_->failwith "Append canonical primary was not the admitted root" in
      require(match summary.lookup,summary.page with
        | Worker_pure_data.V2_present_block{value;_},Some(Worker_pure_data.V2_present_page{page;_})->
          value.block.uuid=root_id && value.block.title="Atomic Service root 中文" && value.task_status=Some status
          && value.block.parent=page.uuid && value.block.page=page.uuid
          && (if index=0 then page.title="2026-11-02" else
            page.uuid=uuid "9f000000-0000-4000-8000-000000002100" && page.title="Existing Web day title")
        |_->false) "Append lost settings format or adopted the candidate instead of the existing Web page";
      require(List.exists(fun(item:Worker_pure_data.child_member)->item.value.block.uuid=child_id
        && item.value.task_status=Some(Test_support.status_uuid 3))summary.items)
        "Append separated or lost its child status write";
      ignore(value(call(W.Acknowledge_intent(W.receipt_intent receipt))));
      require(Rrbvec.is_empty(recover()).items) "actual Append ACK did not settle its durable recovery item";
      require(match value(call((match W.restore_durable_intent session(W.encode_durable_intent(W.Append_intent append)) |> Result.get_ok with W.Append_intent intent->W.Append intent|Mutation_intent _->failwith "stored Append lost its family"))) with
        | W.Submission_committed again->W.receipt_revisions again=W.receipt_revisions receipt
        |_->false) "Append retry lost the original commit proof";
      require(value(call(W.Query(budget,W.Block_summary{block=root_id;after=None})))=summary)
        "Append retry duplicated or changed the complete canonical tree";
      completed_appends:=Rrbvec.push_back !completed_appends(W.encode_durable_intent(W.Append_intent append),receipt,root_id,summary)) [20261102;20261103];
    let rejected_append=W.append_intent session
      ~mutation_id:(uuid "9f000000-0000-4000-8000-000000002199")
      ~block_id:Test_support.authoritative_block_uuid
      ~day:(W.journal_day 20261102 |> Result.get_ok) ~title:"Conflicting existing block"
      ~task_status:None ~children:Rrbvec.empty |> Result.get_ok in
    require(match value(call(W.Append rejected_append)) with W.Submission_rejected _->true|_->false)
      "existing block Append conflict was not a known non-commit";
    require(match C.intent_progress(Host.view host)(W.Append_intent rejected_append) with
      |Some(W.Rejected _)->true|_->false) "Rejected Append lost its original lifecycle family";
    ignore(value(call(W.Acknowledge_intent(W.Append_intent rejected_append))));
    require(C.intent_progress(Host.view host)(W.Append_intent rejected_append)=None
      && Rrbvec.is_empty(recover()).items)
      "Rejected Append without a receipt could not settle its original proof";
    (* Child business ordering against the actual Service and persisted intents.
       UI application here uses the production pure block projection; mounted
       application tests separately verify the rendered composer barrier. *)
    let module Child=Journal_graph_mutation_confirmation.Pure_insertion in
    let parent_summary=value(call(W.Query(budget,W.Block_summary
      {block=Test_support.authoritative_block_uuid;after=None}))) in
    let parent_revision,page=match parent_summary.lookup,parent_summary.page with
      | Worker_pure_data.V2_present_block{revision;_},Some(Worker_pure_data.V2_present_page{page;_})->revision,page
      | _->failwith "real Child parent unavailable" in
    let child=uuid "9f000000-0000-4000-8000-000000001003" in
    let mutation_id=uuid "9f000000-0000-4000-8000-000000001004" in
    let command:Journal_graph_projection.create_child=
      {mutation_id=W.Uuid.to_string mutation_id;calendar_generation=1L;
       block_id=W.Uuid.to_string child;parent_block_id=W.Uuid.to_string Test_support.authoritative_block_uuid;
       expected_parent_revision=parent_revision;sibling_order="a";source="Typed real child";
       task_state=Journal_model.Status(W.Uuid.to_string status);status_confirmation=true;status_intent_revision=0L;
       creation_time=Journal_time.create ~instant_unix_ms:1_788_192_000_000L ~local_day:20260901
         ~local_minute_of_day:0 |> Result.get_ok} in
    let insert=W.Insert_blocks{parent=Test_support.authoritative_block_uuid;
      roots=[{uuid=child;title=command.source;children=[]}];
      preconditions={blocks=[Test_support.authoritative_block_uuid,parent_revision];pages=[];
        scopes=[Worker_pure_data.V2_children_scope Test_support.authoritative_block_uuid,parent_summary.scope_revision]}} in
    let initial,action=Child.start ~command ~page ~resolved_status:(Some status) ~insert |> Result.get_ok in
    let writes=ref 0 and acks=ref 0 and applied=ref None and proofs=ref [] in
    let rec drive fuel state action =
      require(fuel>0) "actual Child lifecycle failed to settle";
      let next,action=match action with
        | Child.Write(index,round) ->
          incr writes;
          let stage=Child.stage state index in
          let durable=Child.stage_intent session stage |> Result.get_ok in
          let intent=match durable with W.Mutation_intent intent->intent|_->assert false in
          let state=Child.bind state ~index ~round ~intent:(W.Mutation_intent intent) ~presentation |> Option.get in
          let receipt=match value(call(W.Mutate intent)) with
            | W.Submission_committed receipt->receipt|_->failwith "real Child lost durable commit" in
          proofs:=(intent,receipt):: !proofs;
          Child.receive state ~index ~round(W.Confirmed(value(call(W.Confirm(presentation,receipt)))))
        | Read_child round ->
          Child.read_child state ~round(value(call(W.Query(budget,W.Block_summary{block=child;after=None}))))
        | Read_parent(round,summary) ->
          ignore(value(call(W.Query(budget,W.Outline_block{uuid=Test_support.authoritative_block_uuid;revision=None}))));
          let block,revision,page=match summary.lookup,summary.page with
            | Worker_pure_data.V2_present_block{value;revision},Some(Worker_pure_data.V2_present_page{page;_})->value.block,revision,page
            | _->failwith "real Child canonical DTO absent" in
          applied:=Some(Journal_graph_projection.block_on_page ~page ~revision
            ~child_count:(List.length summary.items) ~time_context:{localtime=Unix.gmtime} block |> Result.get_ok);
          Child.projection_ready state ~round
        | Present round ->
          require(Option.exists(fun block->Journal_model.source block=command.source) !applied)
            "Child ACK preceded production projection application";
          Child.applied state ~round presentation
        | Acknowledge(index,round,intent,_) ->
          require(!applied<>None) "actual Child intent acknowledged without a consumer";
          ignore(value(call(W.Acknowledge_intent intent)));incr acks;
          require(Rrbvec.is_empty(recover()).items) "settled Child prefix retained recovery obligation";
          Child.acknowledged state ~index ~round(Ok())
        | Complete->state,Complete
        | Wait message->failwith("actual Child stalled: "^message)
        | Ignore->failwith "actual Child dropped its current continuation" in
      match action with Child.Complete->next|_->drive(fuel-1)next action in
    ignore(drive 24 initial action);
    require(!writes=2 && !acks=2) "real Child bypassed Insert/Status or per-stage ACK";
    let final=value(call(W.Query(budget,W.Outline_block{uuid=child;revision=None}))) in
    require(match final with Worker_pure_data.V2_present_block{value;_}->value.block.title=command.source && value.task_status=Some status|_->false)
      "real Child chain did not preserve source/status";
    List.iter(fun(intent,receipt)->
      require(match value(call(W.Mutate intent)) with
        | W.Submission_committed original->W.receipt_revisions original=W.receipt_revisions receipt
        | _->false) "Child ACK removed original commit proof") !proofs;
    require(value(call(W.Query(budget,W.Outline_block{uuid=child;revision=None})))=final)
      "Child original-intent reconciliation wrote a duplicate";

    let revision=match read() with Worker_pure_data.V2_present_block{revision;_}->revision|_->assert false in
    let deletion=W.mutation_intent session ~mutation_id:(uuid "9f000000-0000-4000-8000-000000001002")
      (W.Delete_blocks{root=Test_support.authoritative_block_uuid;
        preconditions={blocks=[Test_support.authoritative_block_uuid,revision];pages=[];scopes=[]}}) |> Result.get_ok in
    let deleted_receipt=match value(call(W.Mutate deletion)) with
      | W.Submission_committed receipt->receipt|_->failwith "real typed deletion failed" in
    let deleted_confirmation=value(call(W.Confirm(presentation,deleted_receipt))) in
    require(match W.confirmation_primary deleted_confirmation with
      | W.Confirmed_absence{uuid;_}->W.Uuid.equal uuid Test_support.authoritative_block_uuid
      | _->false) "typed deletion did not deliver exact canonical absence";
    ignore(value(call(W.Acknowledge_intent(W.Mutation_intent deletion))));
    require(Rrbvec.is_empty(recover()).items) "real deletion ACK retained pending recovery entry";
    require(match value(call(W.Mutate deletion)) with
      | W.Submission_committed original->W.receipt_revisions original=W.receipt_revisions deleted_receipt
      | _->false) "deletion reconciliation lost its original idempotent proof";
    require(match read() with Worker_pure_data.V2_missing_block{uuid;_}->W.Uuid.equal uuid Test_support.authoritative_block_uuid|_->false)
      "same-intent deletion reconciliation changed canonical absence";


    ignore(Mailbox.send client(Service.Client_command Return_to_graph_picker));
    wait(fun()->Option.exists(fun projection->W.selected projection=None)(C.projection(Host.view host)));
    ignore(Mailbox.send client(Service.Client_command(Select_graph Test_support.graph_uuid)));
    wait(fun()->Option.exists(fun projection->
      match W.selected projection with
      | Some current->let fresh=W.presentation_session current in
        not(W.equal_session fresh session)
        && List.exists(fun resident->resident.W.phase=W.Open && W.equal_session resident.session fresh)(W.residents projection)
      | None->false)(C.projection(Host.view host)));
    let current=Option.get(Option.bind(C.projection(Host.view host))W.selected) in
    let fresh=W.presentation_session current in
    Rrbvec.iter(fun(bytes,original,root_id,summary)->
      let append=match W.restore_durable_intent fresh bytes |> Result.get_ok with W.Append_intent intent->intent|Mutation_intent _->failwith "recovered Append lost its family" in
      let receipt=match value(call_in fresh(W.Append append)) with
        | W.Submission_committed receipt->receipt|_->failwith "reopened Append did not reconcile" in
      require(W.receipt_revisions receipt=W.receipt_revisions original)
        "reopened Append replaced original evidence with the new read generation";
      let confirmation=value(call_in fresh(W.Confirm(current,receipt))) in
      require(match W.confirmation_primary confirmation with
        | W.Confirmed_block value->value.lookup=summary.W.lookup && value.page=summary.page && value.items=summary.items
        | _->false) "reopened Append changed the original complete source/status tree";
      require(W.receipt_targets receipt=W.receipt_targets original
        && Rrbvec.exists(W.Uuid.equal root_id)(W.receipt_targets receipt)) "reopened Append changed stable targets";
      ignore(value(call_in fresh(W.Acknowledge_intent(W.receipt_intent receipt))))) !completed_appends;
    ignore(Host.shutdown host);
    wait(fun()->C.shutdown_state(Host.view host)=C.Stopped))
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

let test_visible_media_listing_uses_typed_reads () =
  let module Host=Journal_worker_coordination_host in
  let module Media=Journal_media_runtime in
  with_client ~favorites:true ~assets:true (fun client->
    let jobs=Queue.create() in
    let host=Host.create ~client ~client_id ~managed_origin:"https://api.logseq.io" ~user_id:"user-1"
      ~enqueue:(fun f->Queue.add f jobs) ~changed:(fun _->()) |> Result.get_ok in
    Mailbox.on_event client(fun event->ignore(Host.on_event host event));
    let pump()=Mailbox.Private.deliver client ~max_events:64;
      let count=Queue.length jobs in for _=1 to count do (Queue.take jobs)() done in
    let wait predicate=let deadline=Unix.gettimeofday()+.6. in
      while not(predicate()) && Unix.gettimeofday()<deadline do pump();Thread.delay 0.001 done;
      require(predicate()) "typed visible media listing did not settle" in
    ignore(Mailbox.send client(Service.Client_command(Restore_local_account{user_id="user-1"})));
    wait(fun()->Option.exists(fun p->List.exists(fun r->r.W.phase=W.Open)(W.residents p))(C.projection(Host.view host)));
    let owner:Service.timeline_scope={startup={account_generation=1;presentation_generation=1};graph_id=Test_support.graph_uuid;graph_generation=1} in
    let runtime=ref None and typed_reads=ref 0 and seen=ref [] and finished=ref false and last=ref None and held=ref None and retiring=ref false and late_returned=ref false in
    let root=W.Uuid.to_string(journal_page 1) in
    let read(Media.Read request)=
      let ticket=Host.plan_query_when_available host ~owner ~maximum_items:(min 1 request.maximum_items) ~maximum_bytes:65536 request.query |> Result.get_ok in
      (match request.query with W.Assets _ -> incr typed_reads | _ -> ());
      let number= !typed_reads in
      Host.watch_read host ticket ~f:(fun origin reply->
        require(Option.exists(fun(session,_)->Host.validate_session ~owner host session=Ok())origin) "media listing borrowed its response origin";
        match reply with
        | W.Answered(Ok value)->
          let result=request.outcome value in
          (match request.query with
          | W.Assets _ ->
          last:=Some result;
          if !retiring then (
            require(not(Media.receive_read(Option.get !runtime)result)) "in-flight result revived reset scope";
            late_returned:=true)
          else if number=1 then held:=Some result else (
          require(Media.receive_read(Option.get !runtime) result) "owned typed media page was lost";
          require(not(Media.receive_read(Option.get !runtime) result)) "media page consumed twice";
          if Option.is_some value.next then Queue.add(fun()->Media.next(Option.get !runtime) ~root)jobs
          else finished:=true)
          | _ -> ignore (Media.receive_read (Option.get !runtime) result))
        | _->failwith "real typed media listing failed");true in
    let media=Media.create ~read
      ~demand:(host_asset_demand host ~owner
        ~receive:(fun ticket demand->ignore(Media.receive_demand(Option.get !runtime)ticket demand)))
      ~release_consumer:(host_asset_release host)
      ~acquire:(fun _ _->failwith "metadata listing unexpectedly acquired a rendered file")
      ~release_file:(fun _->failwith "metadata listing unexpectedly released a rendered file")
      ~retry_asset:(fun ~graph_generation:_ _->failwith "metadata listing unexpectedly retried a network asset")
      ~changed:(fun _ (view:Media.view)->
        require(view.error=None) "typed media projection failed";
        seen:=List.rev_append(List.map(fun(item:Media.item)->item.asset.uuid)view.items)!seen) () in
    runtime:=Some media;
    Media.reset media ~graph_generation:(Some 1);
    Media.root_visible media ~root true;
    wait(fun()->Option.is_some !held);
    Media.resync media;
    require(Media.receive_read media(Option.get !held)) "superseded media read lost its owning terminal";
    require(!typed_reads=2) "typed completion left the replacement listing queued without pumping";
    require(not(Media.receive_read media(Option.get !held))) "superseded media terminal consumed twice";
    wait(fun()-> !finished);
    require(!typed_reads>=3) "media fixture did not exercise sealed pagination";
    require(List.sort_uniq W.Uuid.compare !seen=List.init 3(fun n->uuid(Printf.sprintf "9c000000-0000-4000-8000-%012d"(901+n))))
      "visible media listing lost a real external descriptor";
    retiring:=true;
    Media.resync media;
    Media.reset media ~graph_generation:(Some 2);
    wait(fun()-> !late_returned);
    require(not(Media.receive_read media (Option.get !last))) "old media result revived reset scope";
    ignore(Host.shutdown host);wait(fun()->C.shutdown_state(Host.view host)=C.Stopped))
;;

let test_offline_asset_scans_use_typed_reads () =
  let module Host=Journal_worker_coordination_host in
  let module Assets=Journal_asset_runtime in
  with_client ~favorites:true ~assets:true (fun client->
    let jobs=Queue.create() in
    let host=Host.create ~client ~client_id ~managed_origin:"https://api.logseq.io" ~user_id:"user-1"
      ~enqueue:(fun f->Queue.add f jobs) ~changed:(fun _->()) |> Result.get_ok in
    Mailbox.on_event client(fun event->ignore(Host.on_event host event));
    let pump()=Mailbox.Private.deliver client ~max_events:64;
      let count=Queue.length jobs in for _=1 to count do (Queue.take jobs)() done in
    let wait predicate=let deadline=Unix.gettimeofday()+.6. in
      while not(predicate()) && Unix.gettimeofday()<deadline do pump();Thread.delay 0.001 done;
      require(predicate()) "typed offline asset scan did not settle" in
    ignore(Mailbox.send client(Service.Client_command(Restore_local_account{user_id="user-1"})));
    wait(fun()->Option.exists(fun p->List.exists(fun r->r.W.phase=W.Open)(W.residents p))(C.projection(Host.view host)));
    let owner:Service.timeline_scope={startup={account_generation=1;presentation_generation=1};graph_id=Test_support.graph_uuid;graph_generation=1} in
    let runtime=ref None and typed_reads=ref 0 and status=ref None and asset_continuations=ref 0 and asset_rows=ref [] in
    let read(Assets.Read request)=
      (match request.query with W.Assets {after=Some _;_}->incr asset_continuations|_->());
      let ticket=Host.plan_query_when_available host ~owner ~maximum_items:(min 1 request.maximum_items) ~maximum_bytes:65536 request.query |> Result.get_ok in
      incr typed_reads;
      Host.watch_read host ticket ~f:(fun origin reply->
        require(Option.exists(fun(session,_)->Host.validate_session ~owner host session=Ok())origin) "asset scan borrowed its response origin";
        match reply with
        | W.Answered(Ok value)->
          (match request.query with
           | W.Assets _->asset_rows:=List.rev_append (List.map(fun(a:Logseq_db_types.Asset_descriptor.t)->a.uuid)value.items) !asset_rows
           | _->());
          let result=request.outcome value in
          require(Assets.receive_read(Option.get !runtime)~request_id:request.request_id result)
            "owned typed scan result was lost";
          require(not(Assets.receive_read(Option.get !runtime)~request_id:request.request_id result))
            "typed scan consumed the same result twice"
        | _->failwith "real typed offline asset read failed");true in
    let assets=Assets.create ~read
      ~demand:(host_asset_demand host ~owner
        ~receive:(fun ticket demand->ignore(Assets.receive_demand(Option.get !runtime)ticket demand)))
      ~release_consumer:(host_asset_release host)
      ~changed:(fun _ recent favorites->status:=Some(recent,favorites)) () in
    runtime:=Some assets;
    Assets.refresh assets ~graph_generation:1 ~today:20260901 ~settings:Journal_asset_policy.default_settings;
    wait(fun()->match !status with Some(recent,favorites)->
      recent.Journal_asset_policy.enumeration=Complete && favorites.enumeration=Complete|_->false);
    require(!typed_reads>=3) "offline scan did not execute real catalog and asset query families";
    require(!asset_continuations>=2) (Printf.sprintf "real asset More did not retain its sealed continuation (after=%d)" !asset_continuations);
    require(List.sort_uniq W.Uuid.compare !asset_rows = List.init 3(fun n->uuid(Printf.sprintf "9c000000-0000-4000-8000-%012d" (901+n))))
      "asset pagination lost a real external descriptor";
    Assets.shutdown assets;ignore(Host.shutdown host);wait(fun()->C.shutdown_state(Host.view host)=C.Stopped))
;;

let test_dependency_point_reads_use_typed_owner () =
  let module Host = Journal_worker_coordination_host in
  with_client (fun client ->
    let jobs = Queue.create () in
    let host =
      Host.create
        ~client
        ~client_id
        ~managed_origin:"https://api.logseq.io"
        ~user_id:"user-1"
        ~enqueue:(fun f -> Queue.add f jobs)
        ~changed:(fun _ -> ())
      |> Result.get_ok
    in
    let consumed = ref 0 in
    Mailbox.on_event client (fun event ->
      if (Host.on_event host event).R.disposition = R.Consumed then incr consumed);
    let pump () =
      Mailbox.Private.deliver client ~max_events:64;
      let count = Queue.length jobs in
      for _ = 1 to count do
        (Queue.take jobs) ()
      done
    in
    let wait predicate =
      let deadline = Unix.gettimeofday () +. 6. in
      while (not (predicate ())) && Unix.gettimeofday () < deadline do
        pump ();
        Thread.delay 0.001
      done;
      require (predicate ()) "typed dependency point query did not settle"
    in
    ignore
      (Mailbox.send
         client
         (Service.Client_command (Restore_local_account { user_id = "user-1" })));
    wait (fun () ->
      Option.exists
        (fun p -> List.exists (fun r -> r.W.phase = W.Open) (W.residents p))
        (C.projection (Host.view host)));
    let owner : Service.timeline_scope =
      { startup = { account_generation = 1; presentation_generation = 1 }
      ; graph_id = Test_support.graph_uuid
      ; graph_generation = 1
      }
    in
    let query : type a. int -> a W.query -> (a, W.error) result =
      fun maximum_bytes query ->
      let result = ref None in
      let before = !consumed in
      let ticket = Host.plan_query_when_available host ~owner ~maximum_items:1
        ~maximum_bytes query |> Result.get_ok in
      Host.watch_read host ticket ~f:(fun origin reply -> result := Some (origin, reply));
      require (!result = None) "point callback ran synchronously before business admission";
      wait (fun () -> !result <> None);
      require (!consumed = before + 1)
        "dependency point response was not consumed exactly once";
      let origin, reply = Option.get !result in
      require
        (Option.exists
           (fun (session, _) -> Host.validate_session ~owner host session = Ok ()) origin)
        "point dependency inferred its origin after delivery";
      match reply with
      | W.Answered result -> result
      | _ -> failwith "dependency read was not answered"
    in
    require
      (match
         query
           65536
           (W.Outline_block
              { uuid = Test_support.authoritative_block_uuid; revision = None })
       with
       | Ok (Worker_pure_data.V2_present_block { value; revision }) ->
         value.block.uuid = Test_support.authoritative_block_uuid && revision <> ""
       | _ -> false)
      "typed dependency lost full block identity or revision";
    require
      (match
         query 65536 (W.Page { uuid = Test_support.page_uuid; revision = None })
       with
       | Ok (Worker_pure_data.V2_present_page { page; revision }) ->
         page.uuid = Test_support.page_uuid && revision <> ""
       | _ -> false)
      "typed dependency lost its full page DTO";
    require
      (match
         query
           64
           (W.Outline_block
              { uuid = Test_support.authoritative_block_uuid; revision = None })
       with
       | Error W.Response_budget_exceeded -> true
       | _ -> false)
      "point read bypassed encoded budget validation";
    ignore (Host.shutdown host);
    wait (fun () -> C.shutdown_state (Host.view host) = C.Stopped))
;;

(* A real Service authority control can retire an offline binding without
   changing its user or physical graph. The old pure event only represented
   terminal bootstrap revocation, so it could not express this live handover. *)
let test_live_authority_invalidation_rebinds () =
  let module Host = Journal_worker_coordination_host in
  with_client (fun client ->
    let jobs = Queue.create () in
    let host =
      Host.create
        ~client
        ~client_id
        ~managed_origin:"https://api.logseq.io"
        ~user_id:"user-1"
        ~enqueue:(fun f -> Queue.add f jobs)
        ~changed:(fun _ -> ())
      |> Result.get_ok
    in
    Mailbox.on_event client (fun event -> ignore (Host.on_event host event));
    let pump () =
      Mailbox.Private.deliver client ~max_events:64;
      let count = Queue.length jobs in
      for _ = 1 to count do
        (Queue.take jobs) ()
      done
    in
    let wait predicate =
      let deadline = Unix.gettimeofday () +. 6. in
      while (not (predicate ())) && Unix.gettimeofday () < deadline do
        pump ();
        Thread.delay 0.001
      done;
      require (predicate ()) "authority handover did not settle"
    in
    let current () =
      Option.bind
        (C.projection (Host.view host))
        (fun p ->
           List.find_map
             (fun r -> if r.W.phase = W.Open then Some r.session else None)
             (W.residents p))
    in
    ignore
      (Mailbox.send
         client
         (Service.Client_command (Restore_local_account { user_id = "user-1" })));
    wait (fun () -> current () <> None);
    let old = Option.get (current ()) in
    ignore
      (Mailbox.send
         client
         (Service.Client_command
            (Reconcile_authenticated_user { user_id = Some "user-1" })));
    wait (fun () ->
      match C.bootstrap (Host.view host), current () with
      | W.Binding_revoked _, _ -> true
      | _, Some session -> not (W.equal_session old session)
      | _ -> false);
    let session =
      match current () with
      | Some value -> value
      | None ->
        failwith "same-user live authority left the offline binding permanently revoked"
    in
    require
      (not (W.equal_session old session))
      "authority handover reused its revoked registration";
    let budget =
      W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
    in
    let ticket =
      Host.request host session (W.Query (budget, W.Graph_info)) |> Result.get_ok
    in
    let completed = ref false in
    Host.watch host ticket ~f:(function
      | W.Answered (Ok _) -> completed := true
      | _ -> failwith "replacement binding cannot execute a real read");
    wait (fun () -> !completed);
    require
      (Host.validate_session host old = Error W.Revoked_session)
      "old authority session recovered data admission";
    ignore (Host.shutdown host);
    wait (fun () -> C.shutdown_state (Host.view host) = C.Stopped))
;;

let test_changefeed_business_waits_for_ui_application () =
  let module Host = Journal_worker_coordination_host in
  let module Business = Journal_graph_runtime in
  with_client ~statuses:true (fun client ->
    let jobs = Queue.create () in
    let process_notice=ref(fun (_:W.changefeed_notice)->()) in
    let previous_notice_view=ref None in
    let host =
      Host.create
        ~client
        ~client_id
        ~managed_origin:"https://api.logseq.io"
        ~user_id:"user-1"
        ~enqueue:(fun f -> Queue.add f jobs)
        ~changed:(fun view ->
          let notices=C.changefeed_updates ~previous:!previous_notice_view view in
          previous_notice_view:=Some view;
          Rrbvec.iter (fun notice-> !process_notice notice) notices)
      |> Result.get_ok
    in
    let acks = ref 0 and acknowledged_batches=Hashtbl.create 16 in
    Mailbox.on_event client (fun event ->
      let delivery = Host.on_event host event in
      match event, delivery.R.disposition with
      | ( Mailbox.Response
            { outcome =
                Completed
                  (Service.Coordination_changes_acknowledged{result=Ok value;_})
            ; _
            }
        , R.Consumed ) -> incr acks;Hashtbl.replace acknowledged_batches (W.change_ack_through value) ()
      | _ -> ());
    let pump () =
      Mailbox.Private.deliver client ~max_events:64;
      let count = Queue.length jobs in
      for _ = 1 to count do
        (Queue.take jobs) ()
      done
    in
    let wait predicate =
      let deadline = Unix.gettimeofday () +. 6. in
      while (not (predicate ())) && Unix.gettimeofday () < deadline do
        pump ();
        Thread.delay 0.001
      done;
      require (predicate ()) "typed Changes business/client did not settle"
    in
    ignore
      (Mailbox.send
         client
         (Service.Client_command (Restore_local_account { user_id = "user-1" })));
    let session () =
      Option.bind
        (C.projection (Host.view host))
        (fun p ->
           List.find_map
             (fun r -> if r.W.phase = W.Open then Some r.session else None)
             (W.residents p))
    in
    wait (fun () -> Option.is_some (session ()));
    let session = Option.get (session ()) in
    let owner : Service.timeline_scope =
      { startup = { account_generation = 1; presentation_generation = 1 }
      ; graph_id = Test_support.graph_uuid
      ; graph_generation = 1
      }
    in
    let business =
      Business.create
        ~validate_session:(Host.validate_session ~owner host)
        ~on_change:(Host.post host)
        ()
    in
    let calendar =
      Journal_calendar.Sampler.create
        ~clock:(fun () -> 1788307200.)
        ~localtime:Unix.gmtime
        ()
    in
    Business.set_calendar
      business
      (Journal_calendar.Sampler.sample calendar |> Result.get_ok);
    let ui_title = ref None
    and detail_loaded = ref false
    and held = ref None
    and hold_once = ref true in
    let expected_failure = ref false
    and fail_budget_once = ref false
    and saw_failure = ref false in
    let more_seen = ref false in
    let active = ref false
    and notices = ref 0
    and generation = ref 1000L
    and batch : W.change_batch option ref = ref None in
    let latest_blocks=Hashtbl.create 4 and delete_conflict=ref None and deleted=ref false in
    let rec ui responses =
      List.iter
        (fun (response : Business.response) ->
           match response.payload with
           | Business.Mutation_settled(intent,_,payload) ->
             ui [{Business.payload}];
             let ticket=Host.request host session(W.Acknowledge_intent intent) |> Result.get_ok in
             Host.watch host ticket ~f:(function
               | W.Answered(Ok())->Business.acknowledge_mutation business intent
               | _->failwith "actual business mutation ACK failed")
           | Business.Detail_loaded { detail; _ } ->
             Hashtbl.replace latest_blocks (Journal_model.id detail.root) detail.root;
             detail_loaded := true;
             ui_title := Some (Journal_model.source detail.root)
           | Children_reconciled detail ->
             Hashtbl.replace latest_blocks (Journal_model.id detail.root) detail.root;
             ui_title := Some (Journal_model.source detail.root)
           | Block_updated { block; _ } ->
             Hashtbl.replace latest_blocks (Journal_model.id block) block;
             ui_title := Some (Journal_model.source block)
           | Delete_conflict{block;_}->delete_conflict:=Some block
           | Subtree_deleted _->deleted:=true
           | Rejected _ | Feed_failed _ | Open_failed _
           | Task_statuses_changed { error = Some _; _ } ->
             if !expected_failure
             then saw_failure := true
             else failwith "typed business change application rejected valid data"
           | _ -> ())
        responses
    in
    let rec deliver output =
      List.iter send output.Business.requests;
      ui output.responses
    and send request =
      let application =
        Business.application_for_request business ~request_id:request
      in
      match Business.worker_read business request with
      | Some (Business.Read read) ->
        let maximum_bytes =
          if !fail_budget_once && application <> None
          then (
            fail_budget_once := false;
            1)
          else 65536
        in
        let maximum_items =
          match read.query with
          | W.Changes _ -> 1
          | _ -> read.maximum_items
        in
        let ticket =
          Host.plan_query host ~owner ~maximum_items ~maximum_bytes read.query
          |> Result.get_ok
        in
        Host.watch_read host ticket ~f:(fun origin reply ->
          match reply with
          | W.Answered (Ok value) ->
            finished request application origin (Journal_graph_runtime.Query_result(read.query,value))
          | W.Answered (Error (W.Stale_read _)) ->
            finished request application origin Business.Changes_retired
          | W.Answered (Error W.Response_budget_exceeded) when !expected_failure ->
            finished
              request
              application
              origin
              (Business.Read_failed
                 { code = Logseq_db_worker.Error.Response_too_large
                 ; message = "Actual encoded read budget failure" })
          | _ -> failwith "real typed Changes business query failed")
      | Some (Business.Acknowledge read) ->
        let ticket =
          Host.request
            host
            (W.change_batch_session read.batch)
            (W.Acknowledge_changes read.batch)
          |> Result.get_ok
        in
        Host.watch_read host ticket ~f:(fun origin reply ->
          match reply with
          | W.Answered (Ok value) -> finished request None origin (Business.Changes_acknowledged value)
          | _ -> failwith "real typed Changes business ACK failed")
      | Some (Business.Confirm_readback read) ->
        (match Host.reconcile_mutation host ~presentation:read.presentation read.intent |> Result.get_ok with
         |C.Submission_ticket _->failwith "business readback unexpectedly resubmitted its committed intent"
         |C.Confirmation_ticket ticket->
           Host.watch_read host ticket ~f:(fun origin->function
             |W.Answered(Ok confirmation)->
               (match W.confirmation_primary confirmation with
                |W.Confirmed_block summary->finished request application origin(Business.Query_result(read.query,summary))
                |_->failwith "business confirmation target missing")
             |_->failwith "business canonical read failed"))
      | None ->
        let presentation=Option.get(Option.bind(C.projection(Host.view host))W.selected) in
        let intent=Business.worker_intent business request session |> Result.get_ok in
        require(Business.bind_mutation business request ~presentation ~intent) "business intent did not bind";
        let rec watch = function
          |C.Submission_ticket ticket->Host.watch host ticket ~f:(function
            |W.Answered(Ok(W.Submission_committed _))->
              watch(Host.reconcile_mutation host ~presentation intent |> Result.get_ok)
            |W.Answered(Ok(W.Submission_rejected error))->
              deliver(Business.receive_mutation business request(W.Rejected error))
            |W.Answered(Ok W.Submission_unknown)->
              deliver(Business.receive_mutation business request W.Outcome_unknown)
            |_->failwith "actual business mutation did not settle")
          |C.Confirmation_ticket ticket->Host.watch host ticket ~f:(function
            |W.Answered(Ok confirmation)->deliver(Business.receive_mutation business request(W.Confirmed confirmation))
            |_->failwith "actual business mutation did not confirm") in
        watch(Host.reconcile_mutation host ~presentation intent |> Result.get_ok)
    and finished request application origin result =
      let application, discard =
        match result with
        | Business.Query_result(W.Changes _,value) ->
          if value.next <> None then more_seen := true;
          let view = Host.view host in
          if
            C.change_application_started view value
            && C.change_application_error view value = None
          then None, true
          else (
            let token =
              Host.begin_change_application host value ~root:request
              |> Result.get_ok
            in
            require
              (Business.set_change_application
                 business
                 ~request_id:request
                 token)
              "business application root was not owned";
            batch := Some value;
            Some token, false)
        | _ -> application, false
      in
      if discard
      then Business.abandon business request
      else (
        let child =
          match Business.worker_read business request with
          | Some(Business.Read{query=W.Changes _;_}) | Some(Business.Acknowledge _) -> false
          | _ -> true
        in
        let output =
          Business.receive_worker_read
            ?origin
            business
            ~request_id:request
            result
        in
        List.iter send output.requests;
        let apply () =
          ui output.responses;
          Option.iter
            (fun token ->
               Host.post
                 host
                 (C.Change_consumer_applied (token, request, Ok ())))
            application
        in

        if !active && !hold_once && child && application <> None
        then (
          hold_once := false;
          held := Some apply)
        else apply ())
    in
    send (Business.start business);
    deliver
      (Business.submit
         business
         (Load_detail
            { block_id = W.Uuid.to_string Test_support.authoritative_block_uuid
            ; after = None
            ; limit = 1
            ; request_generation = 900L
            }));
    wait (fun () -> !detail_loaded);
    active := true;
    (process_notice
     := fun notice ->
          if Result.is_ok(Host.validate_session host ~owner notice.W.notice_session) then (
            incr notices;
            generation := Int64.succ !generation;
            deliver (Business.reconcile_signal business ~request_generation:!generation notice.notice)));
    let write n title =
      let revision = ref None in
      let budget =
        W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
      in
      let ticket =
        Host.request
          host
          session
          (W.Query
             ( budget
             , W.Outline_block
                 { uuid = Test_support.authoritative_block_uuid; revision = None } ))
        |> Result.get_ok
      in
      Host.watch host ticket ~f:(function
        | W.Answered (Ok (Worker_pure_data.V2_present_block value)) -> revision := Some value.revision
        | _ -> failwith "write revision query failed");
      wait (fun () -> !revision <> None);
      let intent =
        W.mutation_intent
          session
          ~mutation_id:(uuid (Printf.sprintf "9d000000-0000-4000-8000-%012d" (7000 + n)))
          (W.Save_block
             { block = Test_support.authoritative_block_uuid
             ; title
             ; preconditions =
                 { blocks =
                     [ Test_support.authoritative_block_uuid, Option.get !revision ]
                 ; pages = []
                 ; scopes = []
                 }
             })
        |> Result.get_ok
      in
      let done_ = ref false in
      let ticket = Host.request host session (W.Mutate intent) |> Result.get_ok in
      Host.watch host ticket ~f:(function
        | W.Answered (Ok (W.Submission_committed _)) -> done_ := true
        | _ -> failwith "business window write failed");
      wait (fun () -> !done_)
    in
    write 1 "Business change A";
    wait (fun () -> !held <> None);
    require (!acks = 0) "real ACK preceded the held UI application";
    require
      (not (C.change_application_ready (Host.view host) (Option.get !batch)))
      "held UI consumer became ready";
    write 2 "Business change B";
    wait (fun () -> !notices >= 2);
    require (!acks = 0) "a newer push ACKed an unapplied older consumer";
    write 3 "Business change C";
    wait (fun () -> !notices >= 3);
    Queue.add (Option.get !held) jobs;
    held := None;
    wait (fun () -> !acks >= 3 && !ui_title = Some "Business change C");
    require !more_seen "real byte/item-bounded Changes did not exercise More";
    require
      (C.change_application_error (Host.view host) (Option.get !batch) = None)
      "real applied consumers retained a failure";
    (* Original Capture/reconcile/status and stale-delete combinations, using
       the production business reducer and the actual typed Service throughout. *)
    let operation : type a. a W.request -> a = fun request->
      let ticket=Host.request host session request |> Result.get_ok in
      let result=ref None in Host.watch host ticket ~f:(fun reply->result:=Some reply);
      wait(fun()-> !result<>None);
      match Option.get !result with W.Answered(Ok value)->value|_->failwith "combination fixture failed" in
    let target=uuid "9d000000-0000-4000-8000-000000008000" in
    let target_id=W.Uuid.to_string target in
    let append=W.append_intent session ~mutation_id:(uuid "9d000000-0000-4000-8000-000000008001")
      ~block_id:target ~day:(W.journal_day 20260902 |> Result.get_ok) ~title:"Captured regression block"
      ~task_status:None ~children:Rrbvec.empty |> Result.get_ok in
    let receipt=match operation(W.Append append)with W.Submission_committed value->value|_->failwith "capture seed failed" in
    let presentation=Option.get(Option.bind(C.projection(Host.view host))W.selected)in
    ignore(operation(W.Confirm(presentation,receipt)));
    ignore(operation(W.Acknowledge_intent(W.Append_intent append)));
    deliver(Business.submit business(Load_detail{block_id=target_id;after=None;limit=32;request_generation=910L}));
    wait(fun()->Hashtbl.mem latest_blocks target_id);
    let save_target n title=
      let budget=W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok in
      let revision=match operation(W.Query(budget,W.Outline_block{uuid=target;revision=None}))with
        |Worker_pure_data.V2_present_block value->value.revision|_->failwith "captured target missing" in
      let intent=W.mutation_intent session ~mutation_id:(uuid(Printf.sprintf "9d000000-0000-4000-8000-%012d" n))
        (W.Save_block{block=target;title;preconditions={blocks=[target,revision];pages=[];scopes=[]}}) |> Result.get_ok in
      match operation(W.Mutate intent)with W.Submission_committed _->()|_->failwith "concurrent target save failed" in
    save_target 8002 "Reconciled capture";
    wait(fun()->Journal_model.source(Hashtbl.find latest_blocks target_id)="Reconciled capture");
    let reconciled=Hashtbl.find latest_blocks target_id in
    let actual=operation(W.Query((W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok),
      W.Outline_block{uuid=target;revision=None}))in
    require(match actual with Worker_pure_data.V2_present_block value->value.revision=Journal_model.revision reconciled|_->false)
      "changefeed reconciliation emitted an obsolete target revision";
    write 5 "Unrelated target change";
    let status=Test_support.status_uuid 3 in
    deliver(Business.submit business(Set_task_state{mutation_id="9d000000-0000-4000-8000-000000008003";
      block_id=target_id;expected_revision=Journal_model.revision reconciled;task_state=Journal_model.Status(W.Uuid.to_string status)}));
    wait(fun()->Journal_model.task_state(Hashtbl.find latest_blocks target_id)=Journal_model.Status(W.Uuid.to_string status));
    let stale=Hashtbl.find latest_blocks target_id in
    save_target 8004 "Concurrent edit before delete deadline";
    let deletion revision id=Business.submit business(Delete_subtree{mutation_id=id;block_id=target_id;expected_revision=revision})in
    deliver(deletion(Journal_model.revision stale)"9d000000-0000-4000-8000-000000008005");
    wait(fun()-> !delete_conflict<>None);
    let refreshed=Option.get !delete_conflict in
    require(Journal_model.source refreshed="Concurrent edit before delete deadline")
      "delete conflict retained stale canonical source";
    deliver(deletion(Journal_model.revision refreshed)"9d000000-0000-4000-8000-000000008006");
    wait(fun()-> !deleted);
    deliver(Business.submit business(Load_detail{block_id=W.Uuid.to_string Test_support.authoritative_block_uuid;
      after=None;limit=1;request_generation=911L}));
    wait(fun()-> !ui_title=Some "Unrelated target change");
    expected_failure := true;
    fail_budget_once := true;
    write 4 "Business change D";
    wait (fun () ->
      !saw_failure && Option.exists(fun value->C.change_application_error(Host.view host)value<>None)!batch);
    let failed_batch=Option.get !batch in
    require(not(Hashtbl.mem acknowledged_batches failed_batch.through))
      "an actual failed read acknowledged its unapplied window";
    active := false;
    ui_title := None;
    detail_loaded := false;
    Business.reset business;
    wait (fun () -> Hashtbl.mem acknowledged_batches failed_batch.through);
    require
      (!ui_title = None)
      "retired consumer callbacks revived the discarded business scope";
    ignore (Host.shutdown host);
    wait (fun () -> C.shutdown_state (Host.view host) = C.Stopped))
;;

let with_observation_service ?epoch_ms ?prepare ?change_max_items ?(observe_push=fun _->()) f =
  with_client ?epoch_ms ?prepare ?change_max_items (fun client ->
    let replies = Hashtbl.create 16
    and baseline = ref None
    and notices = ref Rrbvec.empty in
    Mailbox.on_event client (fun event ->
      (match event with Mailbox.Push {payload;_}->observe_push payload|_->());
      match event with
      | Response { request_id; outcome; _ } -> Hashtbl.replace replies request_id outcome
      | Push { payload = Service.Coordination_updates updates; _ } ->
        List.iter
          (function
            | Service.Coordination_snapshot value -> remember_baseline baseline value
            | _ -> ())
          updates
      | Push { payload = Service.Coordination_observations updates; _ } ->
        notices := Rrbvec.append !notices updates
      | _ -> ());
    let wait predicate =
      let deadline = Unix.gettimeofday () +. 5. in
      while (not (predicate ())) && Unix.gettimeofday () < deadline do
        Mailbox.Private.deliver client ~max_events:64;
        Thread.delay 0.001
      done;
      require (predicate ()) "real observation Service did not settle"
    in
    let send value =
      match Mailbox.send client value with
      | Accepted id -> id
      | _ -> failwith "observation Service request not admitted"
    in
    let call value =
      let id = send value in
      wait (fun () -> Hashtbl.mem replies id);
      Hashtbl.find replies id
    in
    ignore (call (Service.Client_command (Restore_local_account { user_id = "user-1" })));
    let registration = 910000L in
    (match call (Service.Register_coordination registration) with
     | Completed (Service.Coordination_registered value) -> remember_baseline baseline value
     | _ -> failwith "observation baseline registration failed");
    wait (fun () ->
      match !baseline with
      | Some value ->
        List.exists
          (fun (_, graph) -> graph.Logseq_db_worker.phase = Logseq_db_worker.Graph_open)
          value.baseline.state.residents
      | None -> false);
    let owner = Option.get (Option.get !baseline).baseline.state.sync.selected in
    f client ~call ~send ~wait ~replies ~notices ~baseline ~owner ~registration)
;;

let prepare_enriched_read_data ~count ~title support =
  let module Storage = Logseq_db_storage.Logseq_sqlite_storage in
  let module Session = Logseq_db_storage.Storage_session in
  let path =
    Filename.concat
      support
      ("logseq-db-worker/synced-graphs/"
       ^ W.Uuid.to_string Test_support.graph_uuid
       ^ "/db.sqlite")
  in
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
       let open Datascript in
       let tag = Temp_id "budget-tag" in
       let page =
         Lookup_ref ("block/uuid", Uuid (W.Uuid.to_string Test_support.page_uuid))
       in
       let changes =
         Rrbvec.init count (fun n ->
           let block = Temp_id ("budget-block-" ^ string_of_int n) in
           [ Add
               ( block
               , "block/uuid"
               , Uuid (W.Uuid.to_string (Test_support.mutation_uuid (10000 + n))) )
           ; Add (block, "block/title", String "Small fixture body")
           ; Add (block, "block/parent", Ref_to page)
           ; Add (block, "block/page", Ref_to page)
           ; Add (block, "block/order", String (Printf.sprintf "b%08d" n))
           ; Add (block, "block/created-at", Int64 1704067200000L)
           ; Add (block, "block/updated-at", Int64 1704067200000L)
           ; Add (block, "block/tags", Ref_to tag)
           ]
           |> Rrbvec.of_list)
         |> Rrbvec.concat_map Fun.id
         |> Rrbvec.to_list
       in
       let staged =
         Session.stage_transact
           session
           ~authoritative_before:database
           (Add
              (tag, "block/uuid", Uuid (W.Uuid.to_string (Test_support.mutation_uuid 9999)))
            :: Add (tag, "block/name", String "budget-fixture-tag")
            :: Add (tag, "block/title", String title)
            :: changes)
         |> Result.get_ok
       in
       Session.commit_staged session staged |> Result.get_ok)
;;

let service_read : type a.
  (Service.request,Service.response,Service.push)Mailbox.client -> Service.coordination_baseline option -> Service.timeline_scope -> int64
  -> call:(Service.request -> Service.response Mailbox.outcome)
  -> request_id:W.Uuid.t -> maximum_items:int -> maximum_bytes:int -> a Read.query
  -> (a,Read.error)result =
  fun client baseline owner registration ~call ~request_id ~maximum_items ~maximum_bytes query->
  let source=observation_read client baseline owner registration
    ~maximum_items ~maximum_bytes query in
  match call(Service.Coordination_query{registration;owner;request_id;read=source})with
  |Mailbox.Completed(Service.Coordination_queried response)
    when response.request_id=request_id && response.registration=registration && response.owner=owner->
    let Read.Query_answer(actual_budget,actual_query,result)=response.answer in
    (match Read.query_result_equality query actual_query with
     |Some Read.Refl when Read.equal_packed_query source(Read.For_worker.pack_query actual_budget actual_query)->result
     |_->failwith "Actual Service returned another query or budget")
  |_->failwith "Actual typed Service read did not complete"
;;

let test_enriched_response_budget ()=
  let title=String.make 4096 't'in
  with_observation_service ~prepare:(prepare_enriched_read_data ~count:195 ~title)
    (fun client ~call ~send:_ ~wait:_ ~replies:_ ~notices:_ ~baseline ~owner ~registration->
      let module Ids=Set.Make(W.Uuid)in
      let expected=List.init 195(fun n->Test_support.mutation_uuid(10000+n))
        |>List.fold_left(fun set id->Ids.add id set)Ids.empty in
      let serial=ref 41000 in
      let read :type a. a Read.query->a=fun query->incr serial;
        service_read client !baseline owner registration ~call
          ~request_id:(Test_support.mutation_uuid !serial) ~maximum_items:200
          ~maximum_bytes:Worker_pure_data.maximum_response_bytes query |> Result.get_ok in
      let check_record seen (value:Worker_pure_data.block_record)=
        if not(Ids.mem value.block.uuid expected)then seen else(
          require(value.tag_titles=[title]) "adaptive page truncated enriched tag DTO";
          require(not(Ids.mem value.block.uuid seen)) "adaptive structural pages repeated a member";
          Ids.add value.block.uuid seen)in
      let rec children after pages seen=
        require(pages<16) "enriched children pagination did not terminate";
        let query=Read.Child_members{parent=Test_support.page_uuid;after;revision=None}in
        let value=read query in
        require(Read.encoded_value_bytes query value<=Worker_pure_data.maximum_response_bytes)
          "enriched children exceeded final DTO budget";
        let seen=List.fold_left(fun seen(item:Worker_pure_data.child_member)->check_record seen item.value)seen value.items in
        match value.next with
        |None->require(pages>0 && Ids.equal seen expected) "adaptive children lost tagged members"
        |Some _->require(value.next<>after) "child cursor did not advance";children value.next(pages+1)seen in
      let rec tree after pages seen=
        require(pages<16) "enriched Tree pagination did not terminate";
        let query=Read.Tree{page=Test_support.page_uuid;maximum_depth=1;after;revision=None}in
        let value=read query in
        require(Read.encoded_value_bytes query value<=Worker_pure_data.maximum_response_bytes)
          "enriched Tree exceeded final DTO budget";
        let seen=List.fold_left(fun seen(item:Worker_pure_data.tree_member)->check_record seen item.value)seen value.items in
        match value.next with
        |None->require(pages>0 && Ids.equal seen expected) "adaptive Tree lost tagged members"
        |Some _->require(value.next<>after) "Tree cursor did not advance";tree value.next(pages+1)seen in
      children None 0 Ids.empty;tree None 0 Ids.empty)
;;

let test_encoded_utf8_budget_boundary ()=
  let title=String.concat ""(List.init 300(fun _->"日\"\n"))in
  with_observation_service ~prepare:(prepare_enriched_read_data ~count:1 ~title)
    (fun client ~call ~send:_ ~wait:_ ~replies:_ ~notices:_ ~baseline ~owner ~registration->
      let query=Read.Outline_block{uuid=Test_support.mutation_uuid 10000;revision=None}in
      let read n maximum_bytes=service_read client !baseline owner registration ~call
        ~request_id:(Test_support.mutation_uuid(42000+n)) ~maximum_items:1 ~maximum_bytes query in
      let value=read 0 Worker_pure_data.maximum_response_bytes |> Result.get_ok in
      (match value with Worker_pure_data.V2_present_block{value;_}->
        require(value.tag_titles=[title]) "actual UTF-8 tag title was not resolved"|_->failwith "UTF-8 block missing");
      let size=Read.encoded_value_bytes query value in
      let exact=read 1 size |> Result.get_ok in
      require(Read.encoded_value_bytes query exact=size) "exact final byte budget was not preserved";
      require(match read 2(size-1)with Error Read.Response_budget_exceeded->true|_->false)
        "UTF-8 plus escaped JSON N-1 did not fail explicitly")
;;

let test_canonical_target_summary_query ()=
  let target = Test_support.mutation_uuid 16000 in
  let prepare support=Eio_main.run(fun _->Eio.Switch.run(fun sw->
    prepare_enriched_read_data ~count:1000 ~title:"Unrelated sibling tag" support;
    let module D = Logseq_overlay_db.Database in
    let module O = Logseq_overlay_db.Types in
    let inspection =
      D.inspect_mirror ~application_support_directory:support ~graph_id:Test_support.graph_uuid
      |> Result.get_ok
    in
    let db =
      D.open_
        ~sw
        (Test_support.dependencies ~behavior:"canonical target summary")
        inspection
        ~graph_name:"Target summary"
      |> Result.get_ok
    in
    Fun.protect
      ~finally:(fun () -> D.close db |> Result.get_ok)
      (fun () ->
         let children =
           List.init 201 (fun n ->
             O.
               { uuid = Test_support.mutation_uuid (17000 + n)
               ; title = Printf.sprintf "Canonical child %d" n
               ; children = []
               })
         in
         let expected =
           Test_support.insert_precondition
             db
             ~parent:Test_support.page_uuid
             ~behavior:"canonical target summary"
         in
         D.commit_local
           db
           ~expected
           (O.Insert_blocks
              { mutation_id = Test_support.mutation_uuid 15999
              ; parent = Test_support.page_uuid
              ; tree = { uuid = target; title = "Canonical target"; children }
              ; asset = None
              })
         |> Result.get_ok
         |> ignore)
)) in
  with_observation_service ~prepare
    (fun client ~call ~send:_ ~wait:_ ~replies:_ ~notices:_ ~baseline ~owner ~registration->
      let serial=ref 43000 in
      let inspect ?(maximum_items=Worker_pure_data.default_page_size) ?(maximum_bytes=Worker_pure_data.maximum_response_bytes) after=
        incr serial;let query=Read.Block_summary{block=target;after}in
        let result=service_read client !baseline owner registration ~call
          ~request_id:(Test_support.mutation_uuid !serial) ~maximum_items ~maximum_bytes query in
        query,result in
      let query,result=inspect ~maximum_items:200 ~maximum_bytes:16384 None in
      let adapted=result |> Result.get_ok in
      require(Read.encoded_value_bytes query adapted<=16384 && adapted.items<>[]
        && List.length adapted.items<200 && Option.is_some adapted.next)
        "metadata-heavy summary did not shrink complete DTOs with a real continuation";
      List.iteri(fun index(item:Worker_pure_data.child_member)->
        require(item.value.block.uuid=Test_support.mutation_uuid(17000+index)
          && item.value.block.title=Printf.sprintf "Canonical child %d" index)
          "adaptive target page truncated or skipped canonical DTO")adapted.items;
      let _,first=inspect None in let first=Result.get_ok first in
      require(List.length first.items=Worker_pure_data.default_page_size) "bounded direct summary children";
      let revision=match first.lookup with
        |Worker_pure_data.V2_present_block{value;revision}->
          require(value.block.title="Canonical target") "canonical target title";revision
        |_->failwith "canonical target missing"in
      (match first.page with Some(Worker_pure_data.V2_present_page{page;_})->
        require(page.uuid=Test_support.page_uuid) "owning page is canonical"|_->failwith "owning page missing");
      let old_cursor=first.next in require(Option.is_some old_cursor) "target child continuation missing";
      let rec collect count items (value:Read.block_summary)=
        require(count<8 && List.length value.items<=Worker_pure_data.default_page_size) "summary pages lost their bound";
        require(value.generation=first.generation && value.projection_revision=first.projection_revision)
          "summary pages mixed snapshot versions";
        let items=Rrbvec.append items(Rrbvec.of_list value.items)in
        match value.next with
        |None->count,items
        |Some _->let _,next=inspect value.next in collect(count+1)items(Result.get_ok next)in
      let pages,items=collect 1 Rrbvec.empty first in
      require(pages=5 && Rrbvec.length items=201) "canonical summary did not return all 201 children";
      Rrbvec.iteri(fun index(item:Worker_pure_data.child_member)->
        require(item.value.block.uuid=Test_support.mutation_uuid(17000+index)) "canonical child order changed")items;
      let request_id=Test_support.mutation_uuid 43999 in
      require(match call(mutation_request client !baseline owner registration ~request_id ~mutation_id:request_id
        (W.Save_block{block=target;title="Changed canonical title";
          preconditions={blocks=[target,revision];pages=[];scopes=[]}}))with
        |Mailbox.Completed(Service.Coordination_mutation_result{outcome=Logseq_db_worker_contract.Worker_pure_mutation.Committed _;_})->true
        |_->false) "actual canonical target update failed";
      let _,stale=inspect old_cursor in
      require(match stale with Error(Read.Stale_read _)->true|_->false)
        "old canonical continuation admitted a mixed projection")
;;

(* Pure registry retirement already passes; the defect is the absent production
   Db -> runner -> registry call after the actual unregister joins. Exercise that
   public Service boundary without injecting cleanup ACKs or registry state. *)
let test_service_binding_retirement_reclaims_observation_history () =
  with_observation_service(fun client ~call ~send:_ ~wait:_ ~replies ~notices:_ ~baseline ~owner ~registration ->
    for round=0 to 8199 do
      let registration=Int64.add registration(Int64.of_int round) in
      if round>0 then require(match call(Service.Register_coordination registration) with
        |Completed(Service.Coordination_registered _)->true|_->false)
        "actual observation binding could not be registered again";
      let id=uuid(Printf.sprintf "9d000000-0000-4000-8000-%012d" (100000+round)) in
      require(match call(Service.Coordination_observe{registration;owner;observation_id=id;request_id=id;
        read=observation_read client !baseline owner registration Read.Graph_info}) with
        |Completed(Service.Coordination_observed _)->true|_->false)
        (Printf.sprintf "actual binding retirement exhausted observation history at round %d" (round+1));
      require(call(Service.Release_coordination registration)=Completed(Service.Coordination_released registration))
        "actual observation unregister did not join its resource owner";
      Hashtbl.clear replies
    done)
;;

let test_service_writer_fence_waits_for_canceled_protected_commit () =
  let armed=Atomic.make false and entered=Atomic.make false and released=Atomic.make false in
  let epoch_ms()=
    if Atomic.get armed then (Atomic.set entered true;
      while not(Atomic.get released)do Eio.Fiber.yield() done);
    1_700_000_000_000L in
  Fun.protect ~finally:(fun()->Atomic.set released true)(fun()->
    with_observation_service ~epoch_ms(fun client ~call ~send ~wait ~replies ~notices:_ ~baseline ~owner ~registration->
      let module Wire=Logseq_db_worker_contract.Worker_pure_mutation in
      let id n=uuid(Printf.sprintf "9f000000-0000-4000-8000-%012d" (9000+n)) in
      let read owner n=call(query_request client !baseline owner registration(id n)
        (Read.Outline_block{uuid=Test_support.authoritative_block_uuid;revision=None}))in
      let revision=match read owner 1 with
        |Mailbox.Completed(Service.Coordination_queried{answer=Read.Query_answer(_,Read.Outline_block _,Ok(Worker_pure_data.V2_present_block{revision;_}));_})->revision
        |_->failwith "writer fence source read failed"in
      let intent n title=Wire.create_mutation ~origin:(Uri.of_string "https://api.logseq.io")
        ~user:"user-1" ~graph:owner.graph_id ~mutation_id:(id n)
        (Wire.Save_block{block=Test_support.authoritative_block_uuid;title;
          preconditions={blocks=[Test_support.authoritative_block_uuid,revision];pages=[];scopes=[]}})
        |>Result.get_ok |>fun intent->Wire.Mutation_intent intent in
      let original=intent 2 "Protected writer actually committed" in
      Atomic.set armed true;
      let writer=send(Service.Coordination_mutation{registration;owner;request_id=id 3;intent=original}) in
      wait(fun()->Atomic.get entered);
      Mailbox.cancel client ~request_id:writer;
      let scope=fst(List.find(fun((scope:Service.asset_scope),_)->scope.graph_id=owner.graph_id)
        (Option.get !baseline).baseline.state.residents) in
      let fence=send(Service.Coordination_quiesce_writers{registration;owner=scope;request_id=id 4}) in
      let rejected=call(Service.Coordination_mutation{registration;owner;request_id=id 5;intent=intent 6 "Must not enter held DB"}) in
      require(match rejected with Mailbox.Completed(Service.Coordination_mutation_result{outcome=Wire.Unknown;_})->true|_->false)
        "writer fence admitted another durable operation into the held database";
      require(not(Hashtbl.mem replies fence)) "writer fence ACK preceded actual canceled protected commit";
      Atomic.set armed false;Atomic.set released true;
      wait(fun()->Hashtbl.mem replies fence);
      require(match Hashtbl.find replies fence with
        |Mailbox.Completed(Service.Coordination_writers_quiesced value)->
          value.registration=registration && value.owner=scope && value.request_id=id 4
        |_->false) "writer fence failed to join actual protected I/O and callback barrier";
      require(match read owner 7 with Mailbox.Failed _->true
        |Completed(Service.Coordination_queried{answer=Read.Query_answer(_,_,Error _);_})->true|_->false)
        "old graph incarnation resumed admission after writer fence";
      ignore(call(Service.Client_command Return_to_graph_picker));
      ignore(call(Service.Client_command(Select_graph owner.graph_id)));
      wait(fun()->List.exists(fun((next:Service.asset_scope),graph)->next.graph_id=owner.graph_id
        && next.graph_generation<>owner.graph_generation && graph.Logseq_db_worker.phase=Graph_open)
        (Option.get !baseline).baseline.state.residents);
      let fresh=Option.get(Option.get !baseline).baseline.state.sync.selected in
      require(match read fresh 8 with
        |Mailbox.Completed(Service.Coordination_queried{answer=Read.Query_answer(_,Read.Outline_block _,Ok(Worker_pure_data.V2_present_block{value;_}));_})->
          value.block.title="Protected writer actually committed"
        |_->false) "new incarnation lost actual canceled commit or inherited the old admission fence"))
;;

let test_service_import_rejects_retired_registration () =
  with_client(fun client->
    let replies=Hashtbl.create 16 and baseline=ref None in
    Mailbox.on_event client(function
      |Mailbox.Response{request_id;outcome;_}->Hashtbl.replace replies request_id outcome
      |Push{payload=Service.Coordination_updates updates;_}->List.iter(function Service.Coordination_snapshot value->remember_baseline baseline value|_->())updates
      |_->());
    let wait predicate=
      let deadline=Unix.gettimeofday()+.4. in
      while not(predicate()) && Unix.gettimeofday()<deadline do Mailbox.Private.deliver client ~max_events:64;Thread.delay 0.001 done;
      require(predicate()) "typed Import registration fixture did not settle" in
    let call request=let id=match Mailbox.send client request with Accepted id->id|_->failwith "typed Import fixture admission" in
      wait(fun()->Hashtbl.mem replies id);Hashtbl.find replies id in
    ignore(call(Service.Client_command(Restore_local_account{user_id="user-1"})));
    let issuer=Worker_effect_authority.issuer ~managed_origin:"https://api.logseq.io" ~user_id:"user-1"
      ~runtime_epoch:(Mailbox.runtime_epoch client) ~worker_generation:(Mailbox.worker_generation client) |> Result.get_ok in
    let module I=(val issuer:Worker_effect_authority.ISSUER) in
    (match call(I.bootstrap_request() |> Result.get_ok)with
      |Completed(Service.Coordination_registered value)->remember_baseline baseline value|_->failwith "typed Import baseline request failed");
    wait(fun()->Option.exists(fun value->List.exists(fun(_,graph)->graph.Logseq_db_worker.phase=Graph_open)value.Service.baseline.state.residents)!baseline);
    let raw=Option.get !baseline in
    let projection=match I.bootstrap(Service.Coordination_registered raw)with Ok(W.Ready value)->value|_->failwith "typed Import baseline invalid" in
    let session=(List.hd(W.residents projection)).session in
    let path=Filename.temp_file "journal-retired-import-synthetic-" ".png" in
    Fun.protect ~finally:(fun()->if Sys.file_exists path then Sys.remove path)(fun()->
      Out_channel.with_open_bin path(fun output->output_string output "file");
      let source:Logseq_db_types.Asset_import.t={operation=uuid "9c000000-0000-4000-8000-000000001885";
        asset=uuid "9c000000-0000-4000-8000-000000001886";target=Test_support.authoritative_block_uuid;replace_reference=None;
        local_mutation=uuid "9c000000-0000-4000-8000-000000001887";metadata_mutation=uuid "9c000000-0000-4000-8000-000000001888";
        source_file=path;title="Retired registration import";file_type="png"} in
      let intent=W.asset_import_intent session source |> Result.get_ok in
      let queued=I.request session ~request_id:(W.request_id source.operation)(W.Import intent) |> Result.get_ok in
      ignore(call(Service.Release_coordination raw.registration));
      require((match call queued with Mailbox.Failed _->true|_->false))
        "retired coordination registration still prepared a queued typed Import"))
;;

(* This crosses actual Service/Db/runner lifetimes and reopens the source store.
   A pure reducer cannot establish that source bytes or the Prepared checkpoint
   survived closing their physical owners. No unprepared recovery is claimed. *)
(* The facade's unregister implementation owns actual cache/DB/IO joins; Core
   has no physical lease result from which to reproduce an optimistic ACK. *)
let test_revoked_hidden_lease_blocks_unregister_ack () =
  with_client(fun client->
    let replies=Hashtbl.create 16 and baseline=ref None and manager=ref None in
    Mailbox.on_event client(function
      |Mailbox.Response{request_id;outcome;_}->Hashtbl.replace replies request_id outcome
      |Push{payload=Service.Coordination_updates updates;_}->List.iter(function
        |Service.Coordination_snapshot value->remember_baseline baseline value|_->())updates
      |Push{payload=Service.Client_state_changed value;_}->manager:=Some value.snapshot
      |_->());
    let wait label predicate=let deadline=Unix.gettimeofday()+.4. in
      while not(predicate()) && Unix.gettimeofday()<deadline do Mailbox.Private.deliver client ~max_events:64;Thread.delay 0.001 done;
      require(predicate())label in
    let call request=let id=match Mailbox.send client request with Accepted id->id|_->failwith "retirement fixture admission" in
      wait "actual retirement command did not settle"(fun()->Hashtbl.mem replies id);Hashtbl.find replies id in
    ignore(call(Service.Client_command(Restore_local_account{user_id="user-1"})));
    (match call(Service.Register_coordination 7991L)with
     |Completed(Service.Coordination_registered value)->remember_baseline baseline value|_->failwith "retirement baseline");
    ignore(call(Service.Client_command(Configure_resident_graphs[Test_support.graph_uuid;second_graph])));
    wait "two retirement residents did not open"(fun()->Option.exists(fun value->
      List.length value.Service.baseline.state.residents=2 && List.for_all(fun(_,state)->state.Logseq_db_worker.phase=Graph_open)
        value.baseline.state.residents)!baseline);
    let scope=List.find_map(fun((scope:Service.asset_scope),_)->if scope.graph_id=second_graph then Some scope else None)
      (Option.get !baseline).baseline.state.residents |> Option.get in
    let owner:Service.timeline_scope={startup={account_generation=scope.account.account_generation;
      presentation_generation=scope.account.presentation_generation};graph_id=scope.graph_id;graph_generation=scope.graph_generation} in
    let source_file=Filename.temp_file "journal-unregister-synthetic-" ".png" in
    Fun.protect ~finally:(fun()->if Sys.file_exists source_file then Sys.remove source_file)(fun()->
      Out_channel.with_open_bin source_file(fun output->output_string output "file");
      let source:Logseq_db_types.Asset_import.t={operation=uuid "9c000000-0000-4000-8000-000000003885";
        asset=uuid "9c000000-0000-4000-8000-000000003886";target=Test_support.authoritative_block_uuid;replace_reference=None;
        local_mutation=uuid "9c000000-0000-4000-8000-000000003887";metadata_mutation=uuid "9c000000-0000-4000-8000-000000003888";
        source_file;title="Retired hidden preview";file_type="png"} in
      let imported=match call(Service.Import_asset_at(owner,source))with
        |Completed(Service.Asset_imported(Ok value))->value|_->failwith "actual hidden import failed" in
      let handle,path=imported.preview |> Option.get in
      require(Sys.file_exists path)"physical preview missing before revocation";
      ignore(call(Service.Client_command(Reconcile_authenticated_user{user_id=None})));
      wait "actual account authority was not revoked"(fun()->Option.exists(fun(value:Service.snapshot)->
        not value.startup.authenticated && value.startup.account_generation<>scope.account.account_generation)!manager);
      require(match call(Service.Release_coordination 7991L)with Mailbox.Failed _->true|_->false)
        "unregister ACK escaped while an actual old hidden native lease remained live";
      require(Sys.file_exists path)"failed unregister discarded retained renderer bytes";
      require(call(Service.Release_asset_file{scope;handle})=Completed Service.Client_command_completed)
        "revoked exact hidden lease lost physical cleanup authority";
      require(call(Service.Release_coordination 7991L)=Completed(Service.Coordination_released 7991L))
        "unregister did not retry its original physical cleanup after actual release";
      require(not(Sys.file_exists path))"successful unregister left old scoped resource bytes live"))
;;

let test_prepared_import_survives_worker_lifetime () =
  with_client_sessions (fun start ->
    let source_file=Filename.temp_file "journal-restarted-import-synthetic-" ".png" in
    Fun.protect ~finally:(fun()->if Sys.file_exists source_file then Sys.remove source_file)(fun()->
      Out_channel.with_open_bin source_file(fun output->output_string output "file");
      let source:Logseq_db_types.Asset_import.t=
        {operation=uuid "9c000000-0000-4000-8000-000000002885";
         asset=uuid "9c000000-0000-4000-8000-000000002886";
         target=Test_support.authoritative_block_uuid;replace_reference=None;
         local_mutation=uuid "9c000000-0000-4000-8000-000000002887";
         metadata_mutation=uuid "9c000000-0000-4000-8000-000000002888";
         source_file;title="Prepared across actual worker restart";file_type="png"} in
      let lifetime saved =
        let client=start() in
        let replies=Hashtbl.create 16 and baseline=ref None in
        Mailbox.on_event client(function
          |Mailbox.Response{request_id;outcome;_}->Hashtbl.replace replies request_id outcome
          |Push{payload=Service.Coordination_updates updates;_}->
            List.iter(function Service.Coordination_snapshot value->remember_baseline baseline value|_->())updates
          |_->());
        let wait predicate=
          let deadline=Unix.gettimeofday()+.5. in
          while not(predicate()) && Unix.gettimeofday()<deadline do
            Mailbox.Private.deliver client ~max_events:64;Thread.delay 0.001 done;
          require(predicate()) "restarted Import actual Service did not settle" in
        let call request=
          let id=match Mailbox.send client request with Accepted id->id|_->failwith "restarted Import admission" in
          wait(fun()->Hashtbl.mem replies id);Hashtbl.find replies id in
        ignore(call(Service.Client_command(Restore_local_account{user_id="user-1"})));
        let issuer=Worker_effect_authority.issuer ~managed_origin:"https://api.logseq.io" ~user_id:"user-1"
          ~runtime_epoch:(Mailbox.runtime_epoch client) ~worker_generation:(Mailbox.worker_generation client) |> Result.get_ok in
        let module I=(val issuer:Worker_effect_authority.ISSUER) in
        (match call(I.bootstrap_request() |> Result.get_ok)with
         |Completed(Service.Coordination_registered value)->remember_baseline baseline value
         |_->failwith "restarted Import bootstrap failed");
        wait(fun()->Option.exists(fun value->List.exists(fun(_,graph)->
          graph.Logseq_db_worker.phase=Graph_open)value.Service.baseline.state.residents)!baseline);
        let projection=match I.bootstrap(Service.Coordination_registered(Option.get !baseline))with
          |Ok(W.Ready value)->value|_->failwith "restarted Import baseline invalid" in
        let session=(List.find(fun resident->W.graph_id resident.W.session=Test_support.graph_uuid)(W.residents projection)).session in
        let sequence=ref 0 in
        let request : type a. a W.request -> a W.reply = fun operation ->
          incr sequence;
          let request_id=W.request_id(uuid(Printf.sprintf "9c000000-0000-4000-8000-%012d" (3000 + !sequence))) in
          let raw=I.request session ~request_id operation |> Result.get_ok in
          match call raw with
          |Completed response->I.reply session ~request_id operation response |> Result.get_ok
          |Failed message->failwith("restarted Import request failed: "^message)
          |_->failwith "restarted Import request interrupted" in
        let children ()=
          let budget=W.read_budget session ~maximum_items:100 ~maximum_bytes:65536 |> Result.get_ok in
          match request(W.Query(budget,W.Children{parent=source.target;after=None}))with
          |W.Answered(Ok value)->require(value.next=None) "synthetic Import child count was partial";value.items
          |_->failwith "restarted Import children unavailable" in
        let before=children() in
        let intent=match saved with None->W.asset_import_intent session source |> Result.get_ok
          |Some(encoded,_,_)->W.restore_asset_import_intent session encoded |> Result.get_ok in
        let imported=match request(W.Import intent)with
          |W.Answered(Ok(W.Imported imported))->imported
          |W.Answered(Error(W.Service_failed message))->failwith("restarted Import failed: "^message)
          |_->failwith "restarted Import did not reconcile Prepared" in
        let preview=W.import_preview imported |> Option.get in
        require(Sys.file_exists(W.file_path preview)) "restarted Import lost physically staged source";
        require((W.import_data imported).operation=source.operation && (W.import_data imported).target=source.target)
          "restarted Import replaced original operation/target";
        let after=children() in
        require(List.exists(fun block->W.block_uuid block=source.asset)after)
          "actual Import did not materialize its asset child";
        (match saved with
         |None->require(List.length after=List.length before+1) "first Import duplicated asset children"
         |Some(_,asset,count)->
           require((W.import_data imported).asset=asset) "restarted Import changed original descriptor";
           require(List.length before=count && List.length after=count) "restarted Import replayed local insertion");
        require(request(W.Release_file preview)=W.Answered(Ok())) "restarted Import physical release was not acknowledged";
        W.encode_asset_import_intent intent,(W.import_data imported).asset,List.length after
      in
      let saved=lifetime None in
      Sys.remove source_file;
      ignore(lifetime(Some saved))))
;;

let test_service_observation_lifecycle () =
  with_observation_service
    (fun client ~call ~send:_ ~wait ~replies:_ ~notices ~baseline ~owner ~registration ->
       let logical = uuid "9d000000-0000-4000-8000-000000000001" in
       let rid n=uuid(Printf.sprintf "9d000000-0000-4000-8000-%012d" n) in
       let source=observation_read client !baseline owner registration
         (Read.Outline_block{uuid=Test_support.authoritative_block_uuid;revision=None}) in
       let observe =
         Service.Coordination_observe
           { registration
           ; owner
           ; observation_id = logical
           ; request_id=rid 2
           ; read=source
           }
       in
       let revision =
         match call observe with
         | Completed
             (Service.Coordination_observed
                { epoch = 0L
                ; answer=Read.Query_answer(_,Read.Outline_block _,Ok(Worker_pure_data.V2_present_block { revision; _ }))
                ; _
                }) -> revision
         | _ -> failwith "real initial observation did not sample its predecessor"
       in
       require
         (match call observe with
          | Completed (Service.Coordination_observed { epoch = 0L; _ }) -> true
          | _ -> false)
         "duplicate Observe did not retain original registration";
       let retry_request=rid 10 in
       require
         (match call(Service.Coordination_observe {registration;owner;observation_id=logical;
           request_id=retry_request;read=source}) with
          | Completed(Service.Coordination_observed {epoch=0L;request_id;_})->request_id=retry_request
          | _->false)
         "retried Observe lost current RPC correlation";
       require
         (call
            (Service.Client_command
               (Configure_resident_graphs [ Test_support.graph_uuid; second_graph ]))
          = Mailbox.Completed Service.Client_command_completed)
         "synthetic resident configuration failed";
       wait (fun () ->
         match !baseline with
         | Some value ->
           List.length value.baseline.state.residents = 2
           && List.for_all
                (fun (_, graph) ->
                   graph.Logseq_db_worker.phase = Logseq_db_worker.Graph_open)
                value.baseline.state.residents
         | None -> false);
       require
         (call (Service.Client_command (Focus_resident_graph second_graph))
          = Mailbox.Completed Service.Client_command_completed)
         "synthetic focus change failed";
       wait (fun () ->
         match !baseline with
         | Some value ->
           Option.exists
             (fun (selected : Service.timeline_scope) -> selected.graph_id = second_graph)
             value.baseline.state.sync.selected
         | None -> false);
       require
         (match
            call
              (Service.Coordination_refresh_observation
                 { registration
                 ; owner
                 ; observation_id = logical
                 ; request_id = (rid 9)
                 })
          with
          | Completed
              (Service.Coordination_observed
                 { answer=Read.Query_answer(_,Read.Outline_block _,Ok(Worker_pure_data.V2_present_block { revision = actual; _ }))
                 ; _
                 }) -> actual = revision
          | _ -> false)
         "focus retired a surviving resident observation";
       let write n revision title =
         call(mutation_request client !baseline owner registration ~request_id:(rid n) ~mutation_id:(rid(n+100))
           (W.Save_block{block=Test_support.authoritative_block_uuid;title;
             preconditions={blocks=[Test_support.authoritative_block_uuid,revision];pages=[];scopes=[]}})) in
       require
         (match write 3 revision "Observed write" with
          | Completed
              (Service.Coordination_mutation_result{outcome=Logseq_db_worker_contract.Worker_pure_mutation.Committed _;_}) -> true
          | _ -> false)
         "observation synthetic mutation failed";
       wait (fun () ->
         Rrbvec.exists
           (function
             | Service.Observation_invalidated value ->
               value.registration_id = registration
               && value.observation_id = logical
               && value.epoch > 0L
             | _ -> false)
           !notices);
       let refreshed =
         call
           (Service.Coordination_refresh_observation
              { registration
              ; owner
              ; observation_id = logical
              ; request_id = (rid 4)
              })
       in
       let current_revision =
         match refreshed with
         | Completed
             (Service.Coordination_observed
                { epoch
                ; answer=Read.Query_answer(_,Read.Outline_block _,Ok(Worker_pure_data.V2_present_block { value; revision }))
                ; _
                }) ->
           require
             (epoch > 0L && value.block.title = "Observed write")
             "Refresh lost epoch/data";
           revision
         | _ -> failwith "real observation refresh failed"
       in
       let finalize=Service.Coordination_finalize_observation{registration;owner;observation_id=logical} in
       require(match call finalize with Failed _->true|_->false)
         "actual Service finalized a live observation before physical release";
       let release =
         Service.Coordination_release_observation
           { registration; owner; observation_id = logical }
       in
       require
         (match call release with
          | Completed (Service.Coordination_observation_released _) -> true
          | _ -> false)
         "release did not acknowledge listener/read retirement";
       require
         (match call release with
          | Completed (Service.Coordination_observation_released _) -> true
          | _ -> false)
         "release ACK was not idempotent";
       require
         (match call observe with
          | Failed _ -> true
          | _ -> false)
         "retired logical observation was allocated again";
       require(match call finalize with Completed(Service.Coordination_observation_finalized value)->
         value.registration=registration && value.owner=owner && value.observation_id=logical|_->false)
         "actual creator/release ACK did not permit observation finalization";
       require(match call finalize with Completed(Service.Coordination_observation_finalized _)->true|_->false)
         "uncertain finalization retry was not idempotent";
       notices := Rrbvec.empty;
       require
         (match write 5 current_revision "After observation release" with
          | Completed
              (Service.Coordination_mutation_result{outcome=Logseq_db_worker_contract.Worker_pure_mutation.Committed _;_}) -> true
          | _ -> false)
         "post-release synthetic write did not commit";
       for _ = 1 to 12 do
         Mailbox.Private.deliver client ~max_events:64;
         Thread.delay 0.001
       done;
       require
         (Rrbvec.is_empty !notices)
         "released observation published a later invalidation";
       let cancelled = uuid "9d000000-0000-4000-8000-000000000006" in
       require
         (match
            call
              (Service.Coordination_release_observation
                 { registration; owner; observation_id = cancelled })
          with
          | Completed (Service.Coordination_observation_released _) -> true
          | _ -> false)
         "release before registration did not create a fence";
       require
         (match
            call
              (Service.Coordination_observe
                 { registration
                 ; owner
                 ; observation_id = cancelled
                 ; request_id=rid 2
                 ; read=source
                 })
          with
          | Failed _ -> true
          | _ -> false)
         "late observation escaped its pre-registration release";
       ignore (call (Service.Release_coordination registration)))
;;

let test_service_empty_observation_is_retained () =
  with_observation_service
    (fun
        _client
         ~call
         ~send:_
         ~wait
         ~replies:_
         ~notices
         ~baseline
         ~owner
         ~registration
       ->
       let target = uuid "9d000000-0000-4000-8000-000000005000" in
       let logical = uuid "9d000000-0000-4000-8000-000000005001" in
       let rid n=uuid(Printf.sprintf "9d000000-0000-4000-8000-%012d" n) in
       let point=observation_read _client !baseline owner registration
         (Read.Outline_block{uuid=target;revision=None}) in
       require
         (match
            call
              (Service.Coordination_observe
                 { registration
                 ; owner
                 ; observation_id = logical
                 ; request_id=rid 5002
                 ; read=point
                 })
          with
          | Completed
              (Service.Coordination_observed
                 { answer=Read.Query_answer(_,Read.Outline_block _,Ok(Worker_pure_data.V2_missing_block { uuid; _ }))
                 ; _
                 }) -> uuid = target
          | _ -> false)
         "empty initial sample was not observable";
       let read n query=call(query_request _client !baseline owner registration (rid n) query) in
       let page_revision=match read 5003(Read.Page{uuid=Test_support.page_uuid;revision=None})with
         |Completed(Service.Coordination_queried{answer=Read.Query_answer(_,Read.Page _,Ok(Worker_pure_data.V2_present_page{revision;_}));_})->revision
         |_->failwith "observation insert page revision unavailable" in
       let scope_revision=match read 5004(Read.Child_members{parent=Test_support.page_uuid;revision=None;after=None})with
         |Completed(Service.Coordination_queried{answer=Read.Query_answer(_,Read.Child_members _,Ok children);_})->children.scope_revision
         |_->failwith "observation insert children revision unavailable" in
       require(match call(mutation_request _client !baseline owner registration ~request_id:(rid 5005) ~mutation_id:(rid 5006)
         (W.Insert_blocks{parent=Test_support.page_uuid;
           roots=[{uuid=target;title="First observed block";children=[]}];
           preconditions={blocks=[];pages=[Test_support.page_uuid,page_revision];
             scopes=[Worker_pure_data.V2_children_scope Test_support.page_uuid,scope_revision]}})) with
         |Completed(Service.Coordination_mutation_result{outcome=Logseq_db_worker_contract.Worker_pure_mutation.Committed _;_})->true
         |_->false) "synthetic first insertion did not commit";
       wait (fun () ->
         Rrbvec.exists
           (function
             | Service.Observation_invalidated value -> value.observation_id = logical
             | _ -> false)
           !notices);
       require
         (match
            call
              (Service.Coordination_refresh_observation
                 { registration
                 ; owner
                 ; observation_id = logical
                 ; request_id = (rid 5007)
                 })
          with
          | Completed
              (Service.Coordination_observed
                 { answer=Read.Query_answer(_,Read.Outline_block _,Ok(Worker_pure_data.V2_present_block { value; _ }))
                 ; _
                 }) ->
            value.block.uuid = target && value.block.title = "First observed block"
          | _ -> false)
         "missing sample discarded the interest before first value";
       ignore (call (Service.Release_coordination registration)))
;;

let test_service_observation_read_failure_retains_interest () =
  with_observation_service
    (fun
        _client
         ~call
         ~send:_
         ~wait
         ~replies:_
         ~notices
         ~baseline
         ~owner
         ~registration
       ->
       let logical = uuid "9e000000-0000-4000-8000-000000000001" in
       let rid n=uuid(Printf.sprintf "9e000000-0000-4000-8000-%012d" n) in
       let query=Read.Outline_block{uuid=Test_support.authoritative_block_uuid;revision=None} in
       let read n=match call(query_request _client !baseline owner registration (rid n)
         ~maximum_bytes:Worker_pure_data.maximum_response_bytes query)with
         |Completed(Service.Coordination_queried{answer=Read.Query_answer(_,Read.Outline_block _,Ok(Worker_pure_data.V2_present_block{revision;_} as value));_})->
           revision,Read.encoded_value_bytes query value
         |_->failwith "observation recovery source read failed" in
       let _,encoded_bytes=read 2 in
       let budget=encoded_bytes+128 in
       require(budget<60000) "recovery fixture envelope unexpectedly large";
       let write n title=
         let revision,_=read(n+100)in
         require(match call(mutation_request _client !baseline owner registration ~request_id:(rid n) ~mutation_id:(rid(n+200))
           (W.Save_block{block=Test_support.authoritative_block_uuid;title;
             preconditions={blocks=[Test_support.authoritative_block_uuid,revision];pages=[];scopes=[]}}))with
           |Completed(Service.Coordination_mutation_result{outcome=Logseq_db_worker_contract.Worker_pure_mutation.Committed _;_})->true
           |_->false) "synthetic observation recovery write failed" in
       let too_large = String.make (budget + 1024) 'L' in
       write 3 too_large;
       let initial =
         call
           (Service.Coordination_observe
              { registration
              ; owner
              ; observation_id = logical
              ; request_id=rid 4
              ; read=observation_read _client !baseline owner registration ~maximum_bytes:budget
                  (Read.Outline_block{uuid=Test_support.authoritative_block_uuid;revision=None})
              })
       in
       require
         (match initial with
          | Completed
              (Service.Coordination_observed
                 { answer=Read.Query_answer(_,Read.Outline_block _,Error Read.Response_budget_exceeded)
                 ; _
                 }) -> true
          | _ -> false)
         "oversized initial sample did not report a read failure";
       let refresh n =
         call
           (Service.Coordination_refresh_observation
              { registration
              ; owner
              ; observation_id = logical
              ; request_id = rid n
              })
       in
       let recover n text =
         notices := Rrbvec.empty;
         write n text;
         wait (fun () ->
           Rrbvec.exists
             (function
               | Service.Observation_invalidated value -> value.observation_id = logical
               | _ -> false)
             !notices);
         require
           (match refresh (n + 10) with
            | Completed
                (Service.Coordination_observed
                   { answer=Read.Query_answer(_,Read.Outline_block _,Ok(Worker_pure_data.V2_present_block { value; _ }))
                   ; _
                   }) -> value.block.title = text
            | _ -> false)
           "read failure silently discarded its observation interest"
       in
       recover 5 "Recovered initial observation";
       write 6 too_large;
       require
         (match refresh 17 with
          | Completed
              (Service.Coordination_observed
                 { answer=Read.Query_answer(_,Read.Outline_block _,Error Read.Response_budget_exceeded)
                 ; _
                 }) -> true
          | _ -> false)
         "Refresh did not preserve its read error";
       recover 8 "Recovered refreshed observation";
       ignore (call (Service.Release_coordination registration)))
;;
let test_service_unallocated_observation_cleanup_after_close () =
  with_observation_service(fun client ~call ~send:_ ~wait ~replies:_ ~notices:_ ~baseline ~owner ~registration ->
    let logical=uuid "9d000000-0000-4000-8000-000000000990" in
    ignore(call(Service.Client_command Return_to_graph_picker));
    wait(fun ()->match !baseline with
      | Some value->value.baseline.state.sync.residents=[] && value.baseline.state.residents=[]
      | _ -> false);
    require(match call(Service.Coordination_release_observation {registration;owner;observation_id=logical}) with
      | Completed(Service.Coordination_observation_released value)->value.observation_id=logical
      | _ -> false) "unallocated observation could not settle after graph close";
    ignore(call(Service.Client_command(Select_graph Test_support.graph_uuid)));
    wait(fun ()->match !baseline with
      | Some value -> List.exists(fun (_,state)->state.Logseq_db_worker.phase=Graph_open) value.baseline.state.residents
          && Option.is_some value.baseline.state.sync.selected
      | _ -> false);
    let reopened=Option.get(Option.get !baseline).baseline.state.sync.selected in
    let observe observation_id request_id=Service.Coordination_observe
      {registration;owner=reopened;observation_id;request_id;
       read=observation_read client !baseline reopened registration Read.Graph_info} in
    require(match call(observe logical (uuid "9d000000-0000-4000-8000-000000000991")) with
      | Failed _->true|_->false) "canceled logical ID allocated in a reopened generation";
    require(match call(observe (uuid "9d000000-0000-4000-8000-000000000992")
      (uuid "9d000000-0000-4000-8000-000000000993")) with
      | Completed(Service.Coordination_observed _)->true|_->false)
      "cleanup of one unknown ID incorrectly fenced the reopened graph";
    ignore(call(Service.Release_coordination registration)))
;;

let test_service_unknown_recovery_is_read_only ?(large=false) () =
  let module D=Logseq_overlay_db.Database in
  let module Types=Logseq_overlay_db.Types in
  let module Wire=Logseq_db_worker_contract.Worker_pure_mutation in
  let mutation_id=uuid "9f000000-0000-4000-8000-000000000900" in
  let encoded=ref "" and pending=ref None in
  let prepare support=Eio_main.run(fun _->Eio.Switch.run(fun sw->
    let inspection=D.inspect_mirror ~application_support_directory:support ~graph_id:Test_support.graph_uuid |> Result.get_ok in
    let database=D.open_ ~sw (Test_support.dependencies ~behavior:"pending recovery fixture") inspection ~graph_name:"pending recovery" |> Result.get_ok in
    Fun.protect ~finally:(fun()->ignore(D.close database)) (fun()->
      let snapshot=D.current_snapshot database |> Result.get_ok in
      let revision=Fun.protect ~finally:(fun()->D.release_snapshot snapshot)(fun()->
        match D.get_outline_blocks snapshot [Test_support.authoritative_block_uuid] |> Result.get_ok with
        | [Types.Present_block{revision;_}]->revision|_->failwith "pending fixture block missing") in
      let preconditions=Worker_pure_data.{blocks=[Test_support.authoritative_block_uuid,Types.Block_state_revision.to_string revision];pages=[];scopes=[]} in
      let command,mutation=if large then (
        let children=List.init 5(fun n->Worker_pure_data.{uuid=uuid(Printf.sprintf "9f000000-0000-4000-8000-%012d" (910+n));
          title=String.make 60000 '"';children=[]}) in
        let root=Worker_pure_data.{uuid=uuid "9f000000-0000-4000-8000-000000000909";title="Never automatically replay";children} in
        let tree=Types.{uuid=root.uuid;title=root.title;children=List.map(fun (child:Worker_pure_data.block_tree)->
          {uuid=child.uuid;title=child.title;children=[]})children} in
        Wire.Insert_blocks{parent=Test_support.authoritative_block_uuid;roots=[root];preconditions},
        Types.Insert_blocks{mutation_id;parent=Test_support.authoritative_block_uuid;tree;asset=None})
      else Wire.Save_block{block=Test_support.authoritative_block_uuid;title="Never automatically replay";preconditions},
        Types.Save_block{mutation_id;block=Test_support.authoritative_block_uuid;title="Never automatically replay"} in
      let wire=Wire.create_mutation ~mutation_id ~origin:(Uri.of_string "https://api.logseq.io") ~user:"user-1" ~graph:Test_support.graph_uuid command
        |> Result.get_ok |>fun intent->Wire.Mutation_intent intent in
      pending:=Some wire;encoded:=Wire.encode wire;
      if large then require(String.length !encoded>Worker_pure_data.maximum_response_bytes && String.length !encoded<=Worker_pure_data.maximum_request_bytes)
        "large recovery fixture must be a valid intent exceeding the ordinary read cap";
      let expected=D.write_precondition ~blocks:[Test_support.authoritative_block_uuid,revision] ~pages:[] ~scopes:[] |> Result.get_ok in
      ignore(D.persist_local_intent database ~namespace:(Wire.namespace wire) ~payload: !encoded ~expected mutation |> Result.get_ok)))) in
  with_observation_service ~prepare (fun client ~call ~send:_ ~wait:_ ~replies:_ ~notices:_ ~baseline ~owner ~registration->
    let request_id=uuid "9f000000-0000-4000-8000-000000000901" in
    let recover()=match call(Service.Coordination_recover_mutations{registration;owner;request_id;
      after=None;maximum_items=8;maximum_bytes=(if large then Wire.maximum_recovery_bytes else 16384)}) with
      | Mailbox.Completed(Service.Coordination_mutations_recovered{page;_})->page
      | _->failwith "pending recovery failed" in
    let page=recover() in
    require(Rrbvec.length page.items=1 && Wire.encode(Rrbvec.nth page.items 0).intent= !encoded
      && (Rrbvec.nth page.items 0).outcome=Wire.Unknown) "recovery inferred a pending write outcome";
    require(match call(Service.Coordination_acknowledge_mutation{registration;owner;request_id;
      presentation=(Option.get !baseline).baseline.presentation;intent=Option.get !pending;original=None}) with
      | Mailbox.Failed _->true|_->false) "Unknown intent could be acknowledged away";
    require(Rrbvec.length(recover()).items=1) "Unknown ACK or recovery dropped pending identity";
    require(match call(query_request client !baseline owner registration request_id
      (Read.Outline_block{uuid=Test_support.authoritative_block_uuid;revision=None}))with
      |Mailbox.Completed(Service.Coordination_queried{answer=Read.Query_answer(_,Read.Outline_block _,Ok(Worker_pure_data.V2_present_block{value;_}));_})->
        value.block.title<>"Never automatically replay"
      |_->false) "recovery automatically executed Unknown intent")
;;

let prepare_reusable_asset support =
  let module D=Logseq_overlay_db.Database in
  let module O=Logseq_overlay_db.Types in
  Eio_main.run(fun _->Eio.Switch.run(fun sw->
    let inspection=D.inspect_mirror ~application_support_directory:support ~graph_id:Test_support.graph_uuid |> Result.get_ok in
    let database=D.open_ ~sw (Test_support.dependencies ~behavior:"reusable asset") inspection ~graph_name:"reusable asset" |> Result.get_ok in
    Fun.protect ~finally:(fun()->ignore(D.close database))(fun()->
      let version=Logseq_db_types.Asset_descriptor.version ~checksum:(String.make 64 'a') ~file_type:"png" |> Result.get_ok in
      let parent=Test_support.page_uuid in
      let expected=Test_support.insert_precondition database ~parent ~behavior:"reusable asset" in
      ignore(D.commit_local database ~expected(O.Insert_blocks{
        mutation_id=Test_support.mutation_uuid 981;parent;
        tree={uuid=Test_support.mutation_uuid 980;title="Reusable attachment";children=[]};
        asset=Some{replace_reference=None;version;size=4L}}) |> Result.get_ok))))
;;

let test_service_durable_recovery_and_ack () =
  let module Wire=Logseq_db_worker_contract.Worker_pure_mutation in
  let changes=ref 0 in
  let observe_push=function Service.Graph_push(Worker_pure_data.Changes_available _)->incr changes
    |Graph_pushes values->List.iter(function _,Worker_pure_data.Changes_available _->incr changes|_->())values
    |_->() in
  with_observation_service ~prepare:prepare_reusable_asset ~observe_push(fun client ~call ~send:_ ~wait ~replies:_ ~notices:_ ~baseline ~owner ~registration->
    let id n=uuid(Printf.sprintf "9f000000-0000-4000-8000-%012d" n) in
    let owner=ref owner in
    let presentation ()=(Option.get !baseline).Service.baseline.presentation in
    let read n=match call(query_request client !baseline !owner registration(id n)
      (Read.Outline_block{uuid=Test_support.authoritative_block_uuid;revision=None}))with
      |Mailbox.Completed(Service.Coordination_queried{answer=Read.Query_answer(_,Read.Outline_block _,Ok(Worker_pure_data.V2_present_block{revision;value}));_})->revision,value.block.title
      |_->failwith "durable lifecycle source read failed"in
    let recover ?(maximum_bytes=16384) ?(maximum_items=1) n after=call(Service.Coordination_recover_mutations
      {registration;owner= !owner;request_id=id n;after;maximum_items;maximum_bytes}) in
    let page n after=match recover n after with
      | Mailbox.Completed(Service.Coordination_mutations_recovered{request_id;page}) when request_id=id n->
        require(Wire.recovery_page_bytes page<=16384) "recovery exceeded complete byte budget";page
      | _->failwith "real durable recovery did not return its bounded page" in
    require(Rrbvec.is_empty(page 1 None).items) "new fixture has unexpected pending intents";
    let rev,_=read 2 in
    let intent n revision title=Wire.create_mutation ~origin:(Uri.of_string "https://api.logseq.io")
      ~user:"user-1" ~graph:(!owner).graph_id ~mutation_id:(id n)
      (Wire.Save_block{block=Test_support.authoritative_block_uuid;title;
        preconditions={blocks=[Test_support.authoritative_block_uuid,revision];pages=[];scopes=[]}})
      |>Result.get_ok |>fun intent->Wire.Mutation_intent intent in
    let first=intent 10 rev "Durable first" in
    let mutate n intent=match call(Service.Coordination_mutation
      {registration;owner= !owner;request_id=id n;intent}) with
      | Mailbox.Completed(Service.Coordination_mutation_result{outcome;_})->outcome
      | _->failwith "durable lifecycle mutation did not settle" in
    let original=match mutate 11 first with
      | Wire.Committed response->Wire.committed_point first response |> Result.get_ok
      | _->failwith "first durable fixture write failed" in
    let rejected=intent 20 rev "Stale rejected" in
    require(match mutate 21 rejected with Wire.Rejected _->true|_->false) "stale durable write was not rejected";
    let current,_=read 3 in
    let second=intent 30 current "Durable second" in
    require(match mutate 31 second with Wire.Committed _->true|_->false) "second durable write failed";
    let collect n =
      let rec loop n after count items=
        require(count<8) "recovery continuation did not terminate";
        let current=page n after in
        require(Rrbvec.length current.items<=1) "recovery exceeded item budget";
        let items=Rrbvec.append items current.items in
        match current.next with None->items|Some next->loop(n+1)(Some next)(count+1)items in
      loop n None 0 Rrbvec.empty in
    let before=read 4 in
    let recovered=collect 40 in
    require(Rrbvec.length recovered=3) "bounded recovery skipped committed or rejected intent";
    let first_page=page 44 None in
    let byte_budget=Wire.recovery_page_bytes first_page in
    (match recover ~maximum_bytes:byte_budget ~maximum_items:3 45 None with
     | Mailbox.Completed(Service.Coordination_mutations_recovered{page;_})->
       require(Rrbvec.length page.items=1 && page.next=first_page.next)
         "byte-bounded prefix skipped the next complete row or forged completeness"
     | _->failwith "byte-bounded recovery prefix failed");
    require(read 5=before) "read-only recovery replayed a mutation";
    require(match recover ~maximum_bytes:1 6 None with Mailbox.Failed _->true|_->false)
      "oversized first recovery item was silently skipped";
    let old_presentation=presentation() in
    let old_generation=(!owner).graph_generation in
    ignore(call(Service.Client_command Return_to_graph_picker));
    ignore(call(Service.Client_command(Select_graph(!owner).graph_id)));
    wait(fun()->match !baseline with Some b->List.exists(fun((scope:Service.asset_scope),graph)->
      scope.graph_id=(!owner).graph_id && scope.graph_generation<>old_generation
      && graph.Logseq_db_worker.phase=Logseq_db_worker.Graph_open)b.baseline.state.residents|None->false);
    owner:=Option.get(Option.get !baseline).baseline.state.sync.selected;
    let restored=collect 50 in
    require(Rrbvec.length restored=3) "reopening lost unsettled durable intents";
    let item=Rrbvec.fold_left(fun found (item:Wire.recovery_item)->
      if item.intent=first then Some item else found)None restored |> Option.get in
    let restored_point=match item.outcome with
      | Wire.Committed proof->Wire.committed_point first proof |> Result.get_ok
      | _->failwith "recovered commit lost original proof" in
    require(restored_point=original) "recovery rewrote original commit generation or revisions";
    let ack n presentation intent original=call(Service.Coordination_acknowledge_mutation
      {registration;owner= !owner;presentation;request_id=id n;intent;original}) in
    let proof=original.generation,original.before,original.after in
    require(match ack 60 old_presentation first(Some proof) with Mailbox.Failed _->true|_->false)
      "old presentation acknowledged a committed intent";
    require(match ack 61 (presentation()) first None with Mailbox.Failed _->true|_->false)
      "committed intent was acknowledged as a rejection";
    require(match ack 62 (presentation()) first(Some("wrong","wrong","wrong")) with Mailbox.Failed _->true|_->false)
      "wrong immutable proof acknowledged intent";
    require(Rrbvec.length(collect 70)=3) "invalid ACK removed recovery ownership";
    require(match call(Service.Coordination_confirm{registration;owner= !owner;presentation=presentation();
      request_id=id 80;intent=first;original=proof;
      read=observation_read client !baseline !owner registration ~maximum_items:Worker_pure_data.default_page_size
        ~maximum_bytes:(Option.get !baseline).limits.response_budget_bytes
        (Read.Block_summary{block=Test_support.authoritative_block_uuid;after=None})}) with
      | Mailbox.Completed(Service.Coordination_confirmed{answer=Read.Query_answer(_,Read.Block_summary _,Ok _);_})->true|_->false)
      "reopened intent could not confirm its original proof";
    let acknowledged n result=require(match result with
      | Mailbox.Completed(Service.Coordination_mutation_acknowledged{request_id})->request_id=id n|_->false)
      "durable ACK did not return its exact completion" in
    acknowledged 81 (ack 81 (presentation()) first(Some proof));
    acknowledged 82 (ack 82 (presentation()) rejected None);
    acknowledged 84 (ack 84 (presentation()) rejected None);
    acknowledged 83 (ack 83 (presentation()) first(Some proof));
    require(Rrbvec.length(collect 90)=1) "ACK removed the wrong intent or retained settled rows";
    let revision_before=read 7 in
    require(match mutate 100 first with Wire.Committed response->
      Wire.committed_point first response=Ok original|_->false)
      "ACK deleted immutable original commit proof";
    require(read 8=revision_before) "same-intent reconciliation after ACK replayed the write";
    let block=Test_support.reference_source_uuid in
    let revision=match call(query_request client !baseline !owner registration(id 110)
      (Read.Outline_block{uuid=block;revision=None})) with
      |Completed(Service.Coordination_queried{answer=Read.Query_answer(_,Read.Outline_block _,Ok(Worker_pure_data.V2_present_block{revision;_}));_})->revision
      |_->failwith "asset reference source missing" in
    let asset=Test_support.mutation_uuid 980 in
    let linked=Wire.create_mutation ~origin:(Uri.of_string "https://api.logseq.io") ~user:"user-1"
      ~graph:(!owner).graph_id ~mutation_id:(id 111)
      (Wire.Set_asset_reference{block;previous=None;asset;
        preconditions={blocks=[block,revision];pages=[];scopes=[]}}) |> Result.get_ok
      |> fun value->Wire.Mutation_intent value in
    let before= !changes in
    require(match mutate 112 linked with Wire.Committed _->true|_->false)
      "real Service did not execute asset reference mutation";
    wait(fun()-> !changes>before);
    require(match call(query_request client !baseline !owner registration(id 113)
      (Read.Assets{roots=[block];recursive=false;after=None})) with
      |Completed(Service.Coordination_queried{answer=Read.Query_answer(_,Read.Assets _,Ok page);_})->
        List.exists(fun(value:Logseq_db_types.Asset_descriptor.t)->value.uuid=asset)page.items
      |_->false) "real typed Assets read missed committed reference")
;;

let test_service_changefeed_has_one_owner () =
  let pulses=ref 0 and resyncs=ref 0 in
  let observe_push=function
    |Service.Graph_push(Worker_pure_data.Changes_available _)->incr pulses
    |Graph_push(Worker_pure_data.Resync_required _)->incr pulses;incr resyncs
    |Graph_pushes values->List.iter(function
      |_,Worker_pure_data.Changes_available _->incr pulses
      |_,Worker_pure_data.Resync_required _->incr pulses;incr resyncs)values
    |_->() in
  with_observation_service ~change_max_items:16 ~observe_push
    (fun client ~call ~send:_ ~wait ~replies:_ ~notices:_ ~baseline ~owner ~registration ->
      let id n=uuid(Printf.sprintf "9d000000-0000-4000-8000-%012d" (6000+n)) in
      let active=ref registration in
      let query registration n query=call(query_request client !baseline owner registration(id n) ~maximum_items:32 query)in
      let generation=match query registration 0 Read.Graph_info with
        |Completed(Service.Coordination_queried{answer=Read.Query_answer(_,Read.Graph_info,Ok info);_})->info.generation
        |_->failwith "changefeed fixture graph info"in
      let write n title=
        let revision=match query !active (n+100)(Read.Outline_block{uuid=Test_support.authoritative_block_uuid;revision=None})with
          |Completed(Service.Coordination_queried{answer=Read.Query_answer(_,Read.Outline_block _,Ok(Worker_pure_data.V2_present_block{revision;_}));_})->revision
          |_->failwith "changefeed write revision"in
        let before= !pulses in
        require(match call(mutation_request client !baseline owner !active ~request_id:(id n) ~mutation_id:(id n)
          (W.Save_block{block=Test_support.authoritative_block_uuid;title;
            preconditions={blocks=[Test_support.authoritative_block_uuid,revision];pages=[];scopes=[]}}))with
          |Completed(Service.Coordination_mutation_result{outcome=Logseq_db_worker_contract.Worker_pure_mutation.Committed _;_})->true
          |_->false) "real changefeed write failed";
        wait(fun()-> !pulses>before)in
      let pull registration n after : Read.change_batch = match query registration n(Read.Changes{generation;after})with
        |Completed(Service.Coordination_queried{request_id;answer=Read.Query_answer(_,Read.Changes _,Ok batch);_})->
          require(request_id=id n) "cached Changes kept an old RPC correlation";batch
        |_->failwith "scoped coordinated changefeed pull failed"in
      let ack registration n batch=call(Service.Coordination_acknowledge_changes{registration;owner;request_id=id n;batch})in
      let acknowledged registration n batch=require(match ack registration n batch with
        |Completed(Service.Coordination_changes_acknowledged{request_id;result=Ok value;_})->
          request_id=id n && Read.change_ack_generation value=batch.W.generation && Read.change_ack_through value=batch.through
        |_->false) "owned applied window did not receive its actual ACK"in
      let data(batch:W.change_batch)=batch.through,batch.windows,batch.next in
      let empty=pull registration 12 None in
      require(empty.windows=[] && empty.next=None) "fresh physical changefeed was not empty";
      acknowledged registration 13 empty;
      write 20 "Owned change window A";
      let first=pull registration 1 None in
      require(first.windows<>[]) "actual write produced no retained change window";
      write 21 "Owned change window B";
      require(data(pull registration 4 None)=data first) "unapplied batch was replaced";
      let foreign=Int64.succ registration in
      require(match query foreign 5(Read.Changes{generation;after=None})with
        |Completed(Service.Coordination_query_revoked value)->
          value.registration=foreign && value.owner=owner && value.request_id=id 5
        |_->false)
        "another binding remained an active second changefeed owner";
      acknowledged registration 6 first;
      acknowledged registration 7 first;
      let second=pull registration 8(Some first.through)in
      require(second.through<>first.through && second.windows<>[]) "ACK lost the second actual write window";
      ignore(call(Service.Release_coordination registration));
      let replacement=Int64.succ registration in
      require(match call(Service.Register_coordination replacement)with
        |Completed(Service.Coordination_registered _)->true|_->false) "replacement binding did not register";
      active:=replacement;
      let adopted=pull replacement 9 None in
      require(data adopted=data second) "binding retirement discarded an unapplied physical window";
      require(match ack registration 10 second with Failed _->true|_->false) "old binding consumed the replacement window";
      acknowledged replacement 11 adopted;
      write 3000 "held retention window";
      let held=pull replacement 3001 None in
      for n=3002 to 3258 do write n(Printf.sprintf "retention change %d" n)done;
      require(!resyncs>0) "unacknowledged physical change windows grew without explicit resync";
      require(match ack replacement 3260 held with
        |Completed(Service.Coordination_changes_acknowledged{result=Error(Read.Resync_required _);_})->true
        |_->false) "retention overflow fabricated ACK of discarded physical history";
      let recovered=pull replacement 3261 None in
      require(List.for_all(fun(window:Worker_pure_data.change_window)->
        not(List.exists(fun(old:Worker_pure_data.change_window)->old.id=window.id)held.windows))recovered.windows)
        "overflow retained the discarded owned window";
      acknowledged replacement 3262 recovered;
      require(match query replacement 3263(Read.Changes{generation;after=Some held.through})with
        |Completed(Service.Coordination_queried{answer=Read.Query_answer(_,Read.Changes _,Error(Read.Resync_required _));_})->true
        |_->false) "overflow admitted an obsolete physical cursor";
      write 3264 "After retention reset";
      let after_reset=pull replacement 3265 None in
      require(List.length after_reset.windows=1) "retention reset swallowed or mixed the later publication";
      acknowledged replacement 3266 after_reset;
      (* The original oversized-publication case, through the actual Service. *)
      for n=3300 to 3363 do write n(Printf.sprintf "Before explicit reset %d" n)done;
      let old=pull replacement 3364 None in
      let parent=Test_support.page_uuid in
      let page_revision=match query replacement 3365(Read.Page{uuid=parent;revision=None})with
        |Completed(Service.Coordination_queried{answer=Read.Query_answer(_,Read.Page _,Ok(Worker_pure_data.V2_present_page{revision;_}));_})->revision
        |_->failwith "resync page missing" in
      let scope_revision=match query replacement 3366(Read.Child_members{parent;after=None;revision=None})with
        |Completed(Service.Coordination_queried{answer=Read.Query_answer(_,Read.Child_members _,Ok page);_})->page.scope_revision
        |_->failwith "resync children scope missing" in
      let before= !resyncs in
      let roots=[Worker_pure_data.{uuid=id 3400;title="Resync tree";
        children=List.init 32(fun n->{uuid=id(3401+n);title="Child";children=[]})}] in
      require(match call(mutation_request client !baseline owner replacement ~request_id:(id 3440) ~mutation_id:(id 3440)
        (W.Insert_blocks{parent;roots;preconditions={blocks=[];pages=[parent,page_revision];
          scopes=[Worker_pure_data.V2_children_scope parent,scope_revision]}}))with
        |Completed(Service.Coordination_mutation_result{outcome=Logseq_db_worker_contract.Worker_pure_mutation.Committed _;_})->true
        |_->false) "oversized publication insertion failed";
      wait(fun()-> !resyncs>before);
      let cleared=pull replacement 3441 None in
      require(cleared.windows=[] && cleared.next=None) "explicit resync retained obsolete windows";
      acknowledged replacement 3443 cleared;
      require(match query replacement 3442(Read.Changes{generation;after=Some old.through})with
        |Completed(Service.Coordination_queried{answer=Read.Query_answer(_,Read.Changes _,Error(Read.Resync_required _));_})->true
        |_->false) "explicit resync admitted a discarded cursor";
      write 3444 "After explicit reset";
      let later=pull replacement 3445 None in
      require(List.length later.windows=1) "explicit resync swallowed the next publication";
      acknowledged replacement 3446 later;
      ignore(call(Service.Release_coordination replacement)))
;;

(* Only the real Mailbox allocates the interleaved physical IDs. Core's public
   reducer cannot reproduce a runner lifetime-history admission limit. *)
let test_mixed_mailbox_requests_do_not_exhaust_history () =
  with_client(fun client->
    let events=Queue.create() and state=ref(C.initial ~client_id) in
    let runner=R.create ~client ~managed_origin:"https://api.logseq.io" ~user_id:"user-1"
      ~post:(fun event->Queue.add event events) ~publish:(fun _->()) |> Result.get_ok in
    let legacy_terminal=ref None and legacy_count=ref 0 and typed_count=ref 0 in
    Mailbox.on_event client(fun event->
      let delivered=R.on_event runner event in
      match event,delivered.disposition with
      |Mailbox.Response{request_id;_},R.Unowned_response->legacy_terminal:=Some request_id;incr legacy_count
      |Mailbox.Response _,R.Consumed->incr typed_count
      |_->());
    let apply transition=state:=transition.C.next;List.iter(R.submit runner)transition.instructions in
    let pump()=
      Mailbox.Private.deliver client ~max_events:128;
      let count=Queue.length events in
      for _=1 to count do apply(C.step !state(Queue.take events))done in
    let wait label predicate=
      let deadline=Unix.gettimeofday()+.8. in
      while not(predicate()) && Unix.gettimeofday()<deadline do pump();Thread.delay 0.0005 done;
      require(predicate())label in
    ignore(Mailbox.send client(Service.Client_command(Restore_local_account{user_id="user-1"})));
    let current_session()=Option.bind(C.projection(C.view !state))(fun projection->
      List.find_map(fun resident->if resident.W.phase=W.Open then Some resident.session else None)(W.residents projection)) in
    wait "mixed-request fixture did not bootstrap its actual Service" (fun()->current_session()<>None);
    let session=Option.get(current_session()) in
    let budget=W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok in
    for round=1 to 4100 do
      let legacy=match Mailbox.send client Service.Get_graph_state with
        |Mailbox.Accepted id->id|_->failwith "isolated legacy fixture admission failed" in
      wait "legacy terminal lost its exclusive owner" (fun()-> !legacy_terminal=Some legacy);
      let ticket,planned=C.request !state session(W.Query(budget,W.Graph_info)) |> Result.get_ok in
      apply planned;
      wait "typed terminal did not settle" (fun()->C.reply(C.view !state)ticket<>None);
      require(match C.reply(C.view !state)ticket with Some(W.Answered(Ok _))->true|_->false)
        (Printf.sprintf "normal mixed requests exhausted typed admission at round %d" round);
      apply(C.step !state(C.Forget ticket))
    done;
    require(!legacy_count>=4100 && !typed_count>=4100) "mixed requests did not reach both real owners";
    apply(C.step !state C.Shutdown_requested);
    wait "mixed-request owner did not unregister after draining" (fun()->C.shutdown_state(C.view !state)=C.Stopped))
;;

let test_host_recovers_only_pending_import_sources () =
  let module Host=Journal_worker_coordination_host in
  with_client ~statuses:true ~prepare:prepare_atomic_append_fixture(fun client ->
    let jobs=Queue.create() and active=ref None and confirmations=ref 0 in
    Mailbox.on_event client(fun event->
      (match event with Mailbox.Response{outcome=Completed(Service.Coordination_import_input_confirmed _);_}->incr confirmations|_->());
      Option.iter(fun host->ignore(Host.on_event host event)) !active);
    let pump()=Mailbox.Private.deliver client ~max_events:64;
      let count=Queue.length jobs in for _=1 to count do (Queue.take jobs)()done in
    let wait label condition=let deadline=Unix.gettimeofday()+.5. in
      while not(condition()) && Unix.gettimeofday()<deadline do pump();Unix.sleepf 0.001 done;
      require(condition())label in
    let create suffix =
      let host=Host.create ~client ~client_id:(uuid suffix) ~managed_origin:"https://api.logseq.io" ~user_id:"user-1"
        ~enqueue:(fun f->Queue.add f jobs) ~changed:(fun _->()) |> Result.get_ok in
      active:=Some host;
      if suffix="9f000000-0000-4000-8000-000000004001" then
        ignore(Mailbox.send client(Service.Client_command(Restore_local_account{user_id="user-1"})));
      wait ("source host did not bootstrap: "^suffix) (fun()->Option.exists(fun p->W.selected p<>None && List.exists(fun resident->resident.W.phase=W.Open)(W.residents p))(C.projection(Host.view host)));
      host in
    let old=create "9f000000-0000-4000-8000-000000004001" in
    let session=W.presentation_session(Option.get(Option.bind(C.projection(Host.view old))W.selected)) in
    let call : type a. a W.request -> a = fun operation->
      let ticket=Host.request old session operation |> Result.get_ok in
      let result=ref None in Host.watch old ticket ~f:(fun reply->result:=Some reply);
      wait "original source operation did not finish" (fun()-> !result<>None);
      match Option.get !result with W.Answered(Ok value)->value|_->failwith "real source operation failed" in
    let source_file=Filename.temp_file "journal-background-source-synthetic-" ".png" in
    Fun.protect ~finally:(fun()->if Sys.file_exists source_file then Sys.remove source_file)(fun()->
      Out_channel.with_open_bin source_file(fun output->output_string output "file");
      let source:Logseq_db_types.Asset_import.t={operation=uuid "9f000000-0000-4000-8000-000000004010";
        asset=uuid "9f000000-0000-4000-8000-000000004011";target=Test_support.authoritative_block_uuid;
        local_mutation=uuid "9f000000-0000-4000-8000-000000004012";
        metadata_mutation=uuid "9f000000-0000-4000-8000-000000004013";replace_reference=None;
        source_file;title="Prepared synthetic source";file_type="png"} in
      let intent=W.asset_import_intent session source |> Result.get_ok in
      let imported=match call(W.Import intent)with W.Imported value->value|_->failwith "source did not prepare" in
      Option.iter(fun lease->ignore(call(W.Release_file lease)))(W.import_preview imported);
      ignore(Host.shutdown old);wait "original source registration did not release" (fun()->C.shutdown_state(Host.view old)=C.Stopped);
      let current=create "9f000000-0000-4000-8000-000000004002" in
      require(C.import_source_proof(Host.view current)intent=None) "new host inherited fabricated evidence";
      let pending=Rrbvec.singleton intent in
      for _=1 to 3 do Host.recover_import_sources current pending ~failed:(fun _ _->failwith "source proof lookup failed")done;
      wait "background source lookup did not adopt real Prepared proof" (fun()->C.import_source_proof(Host.view current)intent<>None);
      for _=1 to 8 do Host.recover_import_sources current pending ~failed:(fun _ _->failwith "source proof lookup failed");pump()done;
      require(!confirmations=1) "repeated publication duplicated source proof reads";
      let fresh=W.presentation_session(Option.get(Option.bind(C.projection(Host.view current))W.selected))in
      let unknown={source with operation=uuid "9f000000-0000-4000-8000-000000004020";
        asset=uuid "9f000000-0000-4000-8000-000000004021";
        local_mutation=uuid "9f000000-0000-4000-8000-000000004022";
        metadata_mutation=uuid "9f000000-0000-4000-8000-000000004023"}in
      let unknown=W.asset_import_intent fresh unknown |> Result.get_ok in
      let pending=Rrbvec.of_list[intent;unknown]in
      Host.recover_import_sources current pending ~failed:(fun _ _->failwith "unknown source lookup failed");
      wait "missing input was not inspected" (fun()-> !confirmations=2);
      for _=1 to 8 do Host.recover_import_sources current pending ~failed:(fun _ _->failwith "unknown source lookup failed");pump()done;
      require(!confirmations=2 && C.import_source_proof(Host.view current)unknown=None)
        "None source proof replayed an Import or entered a query loop";
      let ticket=Host.request current fresh(W.Recover_import_inputs{after=None;maximum_items=8;maximum_bytes=65536}) |> Result.get_ok in
      let result=ref None in Host.watch current ticket ~f:(fun reply->result:=Some reply);
      wait "original input ledger could not be inspected" (fun()-> !result<>None);
      require(match Option.get !result with W.Answered(Ok page)->Rrbvec.length page.inputs=1
        && not(Rrbvec.nth page.inputs 0).acknowledged|_->false)
        "background source confirmation replayed Import or ACKed reviewed input";
      require(Sys.file_exists source_file) "read-only source lookup removed picker bytes";
      ignore(Host.shutdown current);wait "source provider registration did not release" (fun()->C.shutdown_state(Host.view current)=C.Stopped)))
;;

(* The real Service owns the authority proof. Core-only events cannot establish
   that response-first Mailbox delivery carries a checked revocation. *)
let test_retired_query_has_correlated_response () =
  with_client(fun client->
    let send request =
      let id=match Mailbox.send client request with Accepted id->id|_->failwith "revocation request admission" in
      let result=ref None in
      let deadline=Unix.gettimeofday()+.6. in
      while !result=None && Unix.gettimeofday()<deadline do
        Mailbox.For_testing.drain_events client ~max_events:64 |> List.iter(function
          |Mailbox.Response{request_id;outcome;_}when Id.Worker.Request_id.equal id request_id->result:=Some outcome
          |_->());Thread.delay 0.001
      done;
      Option.get !result in
    ignore(send(Service.Client_command(Restore_local_account{user_id="user-1"})));
    let issuer=Worker_effect_authority.issuer ~managed_origin:"https://api.logseq.io" ~user_id:"user-1"
      ~runtime_epoch:(Mailbox.runtime_epoch client) ~worker_generation:(Mailbox.worker_generation client) |> Result.get_ok in
    let module I=(val issuer:Worker_effect_authority.ISSUER) in
    let current()=match send(I.bootstrap_request() |> Result.get_ok)with
      |Mailbox.Completed response->(match I.bootstrap response with
        |Ok(W.Ready p)->List.find_map(fun r->if r.W.phase=W.Open then Some r.session else None)(W.residents p)
        |_->None)
      |_->None in
    let session=ref None in
    let deadline=Unix.gettimeofday()+.6. in
    while !session=None && Unix.gettimeofday()<deadline do session:=current();Thread.delay 0.001 done;
    let session=Option.get !session in
    let budget=W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok in
    let id=W.request_id(uuid "9c000000-0000-4000-8000-000000009901") in
    let request=I.request session ~request_id:id(W.Query(budget,W.Graph_info)) |> Result.get_ok in
    ignore(send(Service.Client_command(Reconcile_authenticated_user{user_id=Some "user-1"})));
    let response=match send request with
      |Mailbox.Completed response->response
      |_->failwith "retired query used an uncorrelated transport failure instead of an owned authority result" in
    require(I.reply session ~request_id:id(W.Query(budget,W.Graph_info))response=Ok(W.Answered(Error W.Revoked_session)))
      "authority result did not retain original query owner";
    let other=W.request_id(uuid "9c000000-0000-4000-8000-000000009902") in
    require(match I.reply session ~request_id:other(W.Query(budget,W.Graph_info))response with
      |Error(W.Protocol_mismatch _)->true|_->false) "foreign request forged a binding retirement proof";
    I.revoke();
    require(match I.reply session ~request_id:other(W.Query(budget,W.Graph_info))response with
      |Error(W.Protocol_mismatch _)->true|_->false) "revoked local issuer bypassed exact proof correlation")
;;

let () =
  test_cleanup_transport_causes();
  if Array.mem "--cleanup-causes-only" Sys.argv then exit 0;
  if Array.mem "--read-revocation-only" Sys.argv then (test_retired_query_has_correlated_response();exit 0);
  if Array.mem "--application-close-only" Sys.argv then (test_application_current_close ~replacement:false();test_application_current_close ~replacement:true();exit 0);
  test_application_current_close ~replacement:false();
  test_application_current_close ~replacement:true();
  if Array.mem "--read-owner-only" Sys.argv then (
    test_read_completion_rechecks_graph_owner ();
    print_endline "Real Service read completion owner race passed"; exit 0);
  if Array.mem "--change-owner-only" Sys.argv then (
    test_service_changefeed_has_one_owner();print_endline "Real Service changefeed owner cases passed";exit 0);
  if Array.mem "--read-boundaries-only" Sys.argv then (
    test_enriched_response_budget();test_encoded_utf8_budget_boundary();test_canonical_target_summary_query();
    print_endline "Migrated real typed read boundary cases passed";exit 0);
  if Array.mem "--changes-application-only" Sys.argv then (
    test_changefeed_business_waits_for_ui_application(); print_endline "Real typed Changes application barrier passed"; exit 0);
  if Array.mem "--source-recovery-only" Sys.argv then (
    test_host_recovers_only_pending_import_sources();print_endline "Exact pending source evidence recovery passed";exit 0);
  test_host_recovers_only_pending_import_sources();
  if Array.mem "--observation-retirement-only" Sys.argv then (
    test_service_binding_retirement_reclaims_observation_history();
    print_endline "8200 actual Service observation binding retirements passed";exit 0);
  test_service_binding_retirement_reclaims_observation_history();
  test_mixed_mailbox_requests_do_not_exhaust_history();
  if Array.exists((=)"--ownership-only")Sys.argv then (print_endline "4100 real mixed Mailbox rounds passed";exit 0);
  test_revoked_hidden_lease_blocks_unregister_ack();
  if Array.exists((=)"--retirement-only")Sys.argv then (print_endline "Actual revoked hidden lease / unregister / retry passed";exit 0);
  let host_only=Array.exists((=)"--host-handoff-only")Sys.argv in
  test_real_host_close_keeps_other_resident_and_reopens();
  if host_only then (print_endline "Real host close/observe/consume/reopen and exclusive responses passed";exit 0);
  test_service_writer_fence_waits_for_canceled_protected_commit ();
  test_prepared_import_survives_worker_lifetime ();
  test_service_import_rejects_retired_registration ();
  test_host_durable_recovery_confirmation_ack ();
  test_service_unknown_recovery_is_read_only ~large:true ();
  test_service_unknown_recovery_is_read_only ();
  test_enriched_response_budget ();
  test_encoded_utf8_budget_boundary ();
  test_canonical_target_summary_query ();
  test_service_durable_recovery_and_ack ();
  test_visible_media_listing_uses_typed_reads ();
  test_offline_asset_scans_use_typed_reads ();
  test_dependency_point_reads_use_typed_owner ();
  test_live_authority_invalidation_rebinds ();
  test_retired_query_has_correlated_response ();
  test_service_changefeed_has_one_owner ();
  test_service_unallocated_observation_cleanup_after_close ();
  test_service_observation_read_failure_retains_interest ();
  test_service_observation_lifecycle ();
  test_service_empty_observation_is_retained ();
  let observations_only = Array.exists (( = ) "--observations-only") Sys.argv in
  if not observations_only
  then (
    test_changefeed_business_waits_for_ui_application ();
    test_host_preserves_query_origin_before_forget ();
    test_client_to_typed_read ();
    test_read_completion_rechecks_graph_owner ());
  print_endline
    (if observations_only
     then "Worker coordination real observation Service passed"
     else "Worker coordination real client/read/cleanup passed")
;;
