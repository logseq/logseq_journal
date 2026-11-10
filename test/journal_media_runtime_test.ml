module R = Journal_media_runtime
module S = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module A = Logseq_db_types.Asset_descriptor
module G = Logseq_db_types.Graph_types
module Read = Worker_pure_read

let check condition message = if not condition then failwith message

let uuid n =
  G.Uuid.of_string (Printf.sprintf "89000000-0000-4000-8000-%012d" n) |> Result.get_ok
;;

module W = Journal_worker_coordination.Worker_api

type outgoing = Read of R.read_request | Command : R.ticket option * 'a W.request -> outgoing

let commands queue = Queue.to_seq queue |> Seq.filter_map (function
  | Command _ as command -> Some command | Read _ -> None)
;;

let take_command queue = match Queue.take queue with
  | Command _ as command -> command
  | Read _ -> failwith "expected a resource command"
;;

let take_read queue = match Queue.take queue with
  | Read request -> request
  | Command _ -> failwith "expected a typed read"
;;

module Resources=Coordination_test_fixture.Resources
let resource_source=Resources.create ~graph:(uuid 3) ~graph_generation:1 8100L
let producer=lazy(resource_source.Resources.issuer,resource_source.session)

type resource_ports =
  { demand : graph_generation:int -> name:string -> W.asset_priority -> A.t list -> W.asset_demand R.Coordination.ticket option
  ; acquire : R.ticket -> W.asset_file -> bool
  ; release_file : W.file_lease -> bool
  ; release_consumer : R.demand_registration -> bool
  ; retry_asset : graph_generation:int -> W.Uuid.t -> bool }

let resource_ports sent accepted =
  let submit request=if accepted() then (Queue.add request sent;true)else false in
  {demand=(fun ~graph_generation ~name priority assets -> if not(accepted())then None else
     Option.map(fun ticket->
       let consumer=W.asset_consumer resource_source.session ~name |> Result.get_ok in
       Queue.add(Command(None,W.Replace_asset_demand(consumer,priority,assets)))sent;ticket)
       (Resources.demand_ticket resource_source ~graph_generation ~name priority assets));
   acquire=(fun ticket file->submit(Command(Some ticket,W.Acquire_asset_file file)));
   release_file=(fun file->submit(Command(None,W.Release_file file)));
   release_consumer=(fun (ticket,demand)->match demand with
     |Some demand->submit(Command(None,W.Release_asset_demand demand))
     |None->if accepted() then (Resources.cancel_demand resource_source ticket;true)else false);
   retry_asset=(fun ~graph_generation asset->graph_generation=resource_source.scope.graph_generation && submit(Command(None,W.Retry_asset asset)))}

let consumer_name consumer =
  Hashtbl.to_seq resource_source.Resources.demands |> Seq.find_map(fun(name,(actual,_,_))->
    if W.equal_asset_consumer consumer actual then Some name else None) |> Option.get

let take_acquire sent = match take_command sent with
  |Command(Some ticket,W.Acquire_asset_file file)->ticket,file
  |_->failwith "expected an original typed file acquisition"

let file_reply runtime (ticket,file) handle path =
  R.receive_file runtime ticket (Some(Resources.lease resource_source file ~handle ~path))

let acquisition_handle (_,file) =
  let module I=(val resource_source.issuer:Worker_effect_authority.ISSUER) in
  match I.request resource_source.session ~request_id:(W.request_id(Resources.id resource_source))(W.Acquire_asset_file file) with
  |Ok(S.Acquire_asset_file{handle;_})->handle
  |_->failwith "actual acquire factory rejected its original capability"

let released_handle = function
  |Command(_,W.Release_file lease)->
    let module I=(val resource_source.issuer:Worker_effect_authority.ISSUER) in
    (match I.request (W.file_lease_session lease) ~request_id:(W.request_id(Resources.id resource_source))(W.Release_file lease) with
     |Ok(S.Release_asset_file{handle;_})->Some handle|_->failwith "actual release factory rejected its original lease")
  |_->None

let answer runtime (R.Read request as original) produce =
  let issuer, session = Lazy.force producer in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let budget = W.read_budget session ~maximum_items:request.maximum_items
    ~maximum_bytes:65536 |> Result.get_ok in
  let operation = W.Query (budget, request.query) in
  let id = R.read_request_id original in
  let response=match I.request session ~request_id:(W.request_id id)operation|>Result.get_ok with
    |S.Coordination_query source->S.Coordination_queried{registration=source.registration;owner=source.owner;
      request_id=source.request_id;answer=produce source.read}
    |_->failwith "Media fixture did not issue the original query"in
  match I.reply session ~request_id:(W.request_id id)operation response with
  | Ok (W.Answered (Ok value)) -> ignore (R.receive_read runtime (request.outcome value))
  | _ -> failwith "fixture response did not decode to the spec query value"
;;

let reject_read runtime (R.Read request) = R.reject_read runtime request.ticket

let reply runtime request ?next_cursor items =
  answer runtime request ((fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.asset_listing ~generation:("g") ~projection_revision:("p") ~items:(items) ~next:(Option.map(fun cursor->F.continuation ~owner:(F.read_budget_owner budget) ~budget ~key:(Read.query_key budget query) ~cursor)(next_cursor))) in match query with |Read.Assets _->F.answer budget query value |Read.Asset_descriptors ids->let listing=Result.get_ok value in F.answer budget query (Ok(F.asset_lookup_result ~generation:listing.generation ~projection_revision:listing.projection_revision ~items:(List.map(fun uuid->List.find_opt(fun descriptor->Read.Uuid.equal uuid descriptor.Logseq_db_types.Asset_descriptor.uuid) listing.items)ids))) |_->failwith "Synthetic sample query family mismatch"))
;;

let test_equal_media_notices_keep_effects () =
  let sent = Queue.create () in
  let changes = ref [] in
  let runtime =
    R.create
      ~read:(fun request -> Queue.add (Read request) sent; true)
      ~demand:(resource_ports sent (fun()->true)).demand
      ~acquire:(resource_ports sent (fun()->true)).acquire
      ~release_file:(resource_ports sent (fun()->true)).release_file
      ~release_consumer:(resource_ports sent (fun()->true)).release_consumer
      ~retry_asset:(resource_ports sent (fun()->true)).retry_asset
      ~changed:(fun root view -> changes := (root, view) :: !changes) ()
  in
  R.reset runtime ~graph_generation:(Some 1);
  let root = G.Uuid.to_string (uuid 1) in
  R.root_visible runtime ~root true;
  reply runtime (take_read sent) [];
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

let coordinated_read_retirement accepted () =
  let planned = ref []
  and retired = ref [] in
  let runtime =
    R.create
      ~read_planned:(fun id -> planned := id :: !planned)
      ~read_retired:(fun id -> retired := id :: !retired)
      ~read:(fun request ->
        check
          (List.mem (R.read_request_id request) !planned)
          "read callback ran before causal planning";
        accepted)
      ~demand:(resource_ports (Queue.create()) (fun()->true)).demand
      ~acquire:(resource_ports (Queue.create()) (fun()->true)).acquire
      ~release_file:(resource_ports (Queue.create()) (fun()->true)).release_file
      ~release_consumer:(resource_ports (Queue.create()) (fun()->true)).release_consumer
      ~retry_asset:(resource_ports (Queue.create()) (fun()->true)).retry_asset
      ~changed:(fun _ _ -> ())
      ()
  in
  R.reset runtime ~graph_generation:(Some 1);
  let root = G.Uuid.to_string (uuid 1) in
  R.root_visible runtime ~root true;
  let id = List.hd !planned in
  check (R.owns_read runtime id) "queued/accepted read lost its business identity";
  if accepted
  then R.reset runtime ~graph_generation:(Some 2)
  else R.root_visible runtime ~root false;
  check (not (R.owns_read runtime id)) "retired view retained its read ownership";
  check
    (List.mem id !retired)
    "explicit business retirement did not settle its causal consumer";
  let before = !retired in
  R.pump runtime;
  check (!retired = before) "a pruned request was retired again on a later pump"
;;

let () = test_equal_media_notices_keep_effects ()

let () =
  let sent = Queue.create () in
  let views = Hashtbl.create 2 in
  let changes = ref 0 in
  let runtime =
    R.create
      ~read:(fun request -> Queue.add (Read request) sent; true)
      ~demand:(resource_ports sent (fun()->true)).demand
      ~acquire:(resource_ports sent (fun()->true)).acquire
      ~release_file:(resource_ports sent (fun()->true)).release_file
      ~release_consumer:(resource_ports sent (fun()->true)).release_consumer
      ~retry_asset:(resource_ports sent (fun()->true)).retry_asset
      ~changed:(fun root view ->
        incr changes;
        Hashtbl.replace views root view) ()
  in
  R.reset runtime ~graph_generation:(Some 1);
  let root = G.Uuid.to_string (uuid 1) in
  R.root_visible runtime ~root true;
  check (not (Queue.is_empty sent)) "visible root must query its rendered assets";
  let query = take_read sent in
  check (match query with R.Read { maximum_items = 16;
      query = W.Assets { recursive = false; roots = [ u ]; after = None }; _ }
      when u = uuid 1 -> true | _ -> false) "media query must be direct and bounded";
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
  reply runtime query [ asset ];
  check (Queue.is_empty sent) "metadata alone cannot request binary download";
  check
    (List.length (Hashtbl.find views root).items = 1)
    "metadata reaches native presentation";
  R.asset_visible
    runtime
    ~root
    ~asset:(List.hd (Hashtbl.find views root).items).token
    true;
  let consumer=match take_command sent with
    |Command(_,W.Replace_asset_demand(consumer,W.Foreground,[_]))->consumer_name consumer
    |_->failwith "visible media demand must be foreground" in
  let scope=resource_source.Resources.scope in
  let before_waiting = !changes in
  R.notice runtime (Resources.notice resource_source (S.Asset_availability { consumer; asset = asset.uuid; descriptor=asset; availability = Queued }));
  check
    (!changes = before_waiting)
    "equal waiting availability must not republish the pending presentation";
  R.notice runtime (Resources.notice resource_source (S.Asset_availability { consumer; asset = asset.uuid; descriptor=asset; availability = Ready "cached" }));
  let acquisition=take_acquire sent in
  check(acquisition_handle acquisition="cached")
    "readiness retains the file";
  file_reply runtime acquisition "retained" "/cache/image.png";
  check
    ((List.hd (Hashtbl.find views root).items).presentation
     = Journal_media.File "/cache/image.png")
    "native view receives retained path";
  let before_ready_duplicate = !changes in
  R.notice runtime (Resources.notice resource_source (S.Asset_availability { consumer; asset = asset.uuid; descriptor=asset; availability = Ready "cached" }));
  check
    (!changes = before_ready_duplicate)
    "duplicate readiness must not republish a retained file";
  check (Queue.is_empty sent) "duplicate readiness must not reacquire the retained file";
  R.reset runtime ~graph_generation:None;
  let requests = commands sent |> List.of_seq in
  check
    (List.exists
       (fun command->released_handle command=Some "retained")
       requests)
    "navigation reset releases file";
  Queue.clear sent;
  R.reset runtime ~graph_generation:(Some 1);
  let receipt : Logseq_db_worker.import_receipt =
    { operation = uuid 8
    ; graph_generation = 1
    ; scope
    ; target = uuid 1
    ; asset=(A.create ~uuid:asset.uuid ~source:asset.source
        ~current_checksum:(Some(String.make 64 'a')) ~size:asset.size ~dimensions:asset.dimensions |> Result.get_ok)
    ; file_type = "png"
    ; preview = Some ("local-lease", "/staged/import.bin")
    }
  in
  let imported=Resources.imported resource_source receipt in
  R.imported runtime ~current:true imported;
  check (Queue.is_empty sent) "explicit import must not query or download";
  check
    (List.exists
       (fun (item : R.item) ->
          item.presentation = Journal_media.File "/staged/import.bin")
       (Hashtbl.find views root).items)
    "imported file appears immediately";
  let before_duplicate = !changes in
  R.imported runtime ~current:true imported;
  check
    (!changes = before_duplicate)
    "duplicate import must not republish the same file presentation";
  check (Queue.is_empty sent) "duplicate receipt must not release its live lease";
  R.reset runtime ~graph_generation:None;
  check
    (List.exists
       (fun command->released_handle command=Some "local-lease")
       (commands sent |> List.of_seq))
    "reset releases staged preview";
  Queue.clear sent;
  R.imported
    runtime
    ~current:false
    (Resources.imported resource_source {receipt with preview=Some("late-lease","/staged/late.bin")});
  check
    (List.exists
       (fun command->released_handle command=Some "late-lease")
       (commands sent |> List.of_seq))
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
      ~read:(fun request -> if !full then false else (Queue.add (Read request) sent; true))
      ~demand:(resource_ports sent (fun()->not !full)).demand
      ~acquire:(resource_ports sent (fun()->not !full)).acquire
      ~release_file:(resource_ports sent (fun()->not !full)).release_file
      ~release_consumer:(resource_ports sent (fun()->not !full)).release_consumer
      ~retry_asset:(resource_ports sent (fun()->not !full)).retry_asset
      ~changed:(fun root view -> Hashtbl.replace views root view) ()
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
  R.reset runtime ~graph_generation:(Some 1);
  let metadata root =
    R.root_visible ~owner:"row" runtime ~root true;
    reply runtime (take_read sent) [ asset ];
    (List.hd (Hashtbl.find views root).items).token
  in
  let root = G.Uuid.to_string (uuid 1) in
  let token = metadata root in
  R.asset_visible ~owner:"row" runtime ~root ~asset:token true;
  Queue.clear sent;
  R.notice runtime (Resources.notice resource_source (S.Asset_availability
       { consumer = token; asset = asset.uuid; descriptor=asset; availability = Ready "cached" }));
  let acquisition=take_acquire sent in
  file_reply runtime acquisition "preview-file" "/cache/image.png";
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
    commands sent
    |> Seq.filter (fun command->released_handle command=Some "preview-file")
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
      ~read:(fun request -> if !admitted then (Queue.add (Read request) sent; true) else false)
      ~demand:(resource_ports sent (fun()-> !admitted)).demand
      ~acquire:(resource_ports sent (fun()-> !admitted)).acquire
      ~release_file:(resource_ports sent (fun()-> !admitted)).release_file
      ~release_consumer:(resource_ports sent (fun()-> !admitted)).release_consumer
      ~retry_asset:(resource_ports sent (fun()-> !admitted)).retry_asset
      ~changed:(fun root view -> Hashtbl.replace views root view) ()
  in
  R.reset runtime ~graph_generation:(Some 1);
  runtime, sent, views, admitted
;;

let take_metadata sent =
  let rec take () = match Queue.take sent with
    | Read (R.Read { query = W.Assets _; _ } as request) -> request
    | _ -> take () in
  take ()
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

let block_value block : Worker_pure_data.block_lookup =
  Worker_pure_data.V2_present_block
    { value = { block; task_status = None; rendered_page_title = "Page"; tag_titles = [] }
    ; revision = "r" }
;;

let observe runtime (block : G.block) =
  let query = W.Outline_block { uuid = block.uuid; revision = None } in
  R.observe_query runtime ~request_id:(uuid 999) query;
  R.observe_query_result runtime ~request_id:(uuid 999) query (block_value block)
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
  match take_read sent with
  | (R.Read { query = W.Page { uuid = page; _ }; _ } as request) when page = uuid 900 ->
    answer runtime request ((fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_page { page = raw_page recycled; revision = "p" })) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))
  | _ -> failwith "page liveness must use one bounded owned Page query"
;;

let reply_block runtime sent (block : G.block) =
  match take_read sent with
  | (R.Read { query = W.Outline_block { uuid; _ }; _ } as request) when uuid = block.G.uuid ->
    answer runtime request ((fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((block_value block)) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))
  | _ -> failwith "holder/liveness must use its owned bounded Outline_block query"
;;

let window ?(structures = []) blocks : Worker_pure_data.change_window =
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
  match take_read sent with
  | (R.Read { query = W.Outline_block { uuid = block; _ }; _ } as request) when block = uuid n ->
    answer runtime request ((fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_block { uuid = block; revision = "deleted" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))
  | _ -> failwith "deletion must complete its owned bounded block lookup"
;;

let list_reads sent =
  Queue.to_seq sent |> Seq.filter (function
    | Read (R.Read { query = W.Assets _; _ }) -> true | _ -> false) |> Seq.length
;;

let file_commands sent =
  commands sent |> Seq.length
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

(* Resource retirement is owned by this adapter, outside the coordinator reducer.
   Its expected-owner read tickets already survive a binding handover. *)
let test_binding_retains_media_reads () =
  List.iter (fun accepted ->
    let r,q,views,admitted = fixture () in
    let module I = (val resource_source.Resources.issuer : Worker_effect_authority.ISSUER) in
    R.bind_coordinated_resources r I.binding;
    admitted := accepted;
    let root = G.Uuid.to_string (uuid 1) in
    R.root_visible ~owner:"timeline" r ~root true;
    R.root_visible ~owner:"detail" r ~root true;
    let original = if accepted then Some(take_read q) else None in
    admitted := false;
    R.retire_coordinated_resources r;
    Option.iter (fun request -> check (R.owns_read r (R.read_request_id request))
      "resource handover retired a live media read") original;
    R.root_visible ~owner:"timeline" r ~root false;
    admitted := true;
    R.bind_coordinated_resources r I.binding;
    let request = match original with Some request -> request | None -> take_read q in
    check (Queue.is_empty q) "shared visible owners duplicated a retained media read";
    reply r request [];
    check (Queue.is_empty q) "retained media completion unnecessarily restarted its listing";
    check ((Hashtbl.find views root).error = None) "binding handover published a media error";
    R.reset r ~graph_generation:(Some 2);
    check (not(R.owns_read r (R.read_request_id request))) "graph replacement kept old media ownership"
  ) [false;true]
;;

let test_binding_cleanup_precedes_waiting_reads () =
  let sent=Queue.create() and allow_reads=ref true and released=ref 0 and views=Hashtbl.create 2 in
  let ports=resource_ports sent (fun()->true) in
  let r=R.create
    ~read:(fun request->if !allow_reads then(Queue.add(Read request)sent;true)else false)
    ~demand:ports.demand ~acquire:ports.acquire ~release_file:ports.release_file
    ~release_consumer:(fun registration->incr released;ports.release_consumer registration)
    ~retry_asset:ports.retry_asset ~changed:(fun root view->Hashtbl.replace views root view) () in
  R.reset r ~graph_generation:(Some 1);
  let module I=(val resource_source.Resources.issuer:Worker_effect_authority.ISSUER) in
  R.bind_coordinated_resources r I.binding;
  let root=G.Uuid.to_string(uuid 1) in
  let asset=A.create ~uuid:(uuid 2)
    ~source:(Managed(Some(A.version ~checksum:(String.make 64 'a') ~file_type:"png" |> Result.get_ok)))
    ~current_checksum:None ~size:None ~dimensions:None |> Result.get_ok in
  loaded r sent root [asset];
  let token=(List.hd(Hashtbl.find views root).items).token in
  R.asset_visible r ~root ~asset:token true;
  Queue.clear sent;
  R.notice r (Resources.notice resource_source(S.Asset_availability
    {consumer=token;asset=asset.uuid;descriptor=asset;availability=Ready "cached"}));
  let acquisition=take_acquire sent in
  file_reply r acquisition "rebind-held" "/cache/rebind-held";
  Queue.clear sent;
  allow_reads:=false;
  R.root_visible r ~root:(G.Uuid.to_string(uuid 3)) true;
  R.retire_coordinated_resources r;
  check(!released>0) "waiting read blocked retired demand cleanup";
  check(commands sent |> Seq.exists(fun command->released_handle command=Some "rebind-held"))
    "waiting read blocked retired file cleanup";
  check(list_reads sent=0) "waiting read was admitted while rebinding"
;;

let test_binding_retains_shared_facts () =
  let r,q,views,admitted = fixture () in
  let module I = (val resource_source.Resources.issuer : Worker_effect_authority.ISSUER) in
  R.bind_coordinated_resources r I.binding;
  observe r (raw_block 1 60);
  observe r (raw_block 2 60);
  loaded r q (G.Uuid.to_string(uuid 1)) [];
  loaded r q (G.Uuid.to_string(uuid 2)) [];
  change r [80];
  let original = take_read q in
  check (Queue.is_empty q) "two roots did not share the missing ancestor read";
  admitted := false;
  R.retire_coordinated_resources r;
  check (R.owns_read r (R.read_request_id original)) "binding handover stranded shared ancestor consumers";
  R.root_visible r ~root:(G.Uuid.to_string(uuid 1)) false;
  check (R.owns_read r (R.read_request_id original)) "one hidden root canceled another root's shared read";
  Queue.add(Read original)q;
  admitted:=true;
  R.bind_coordinated_resources r I.binding;
  reply_block r q (raw_block 60 900);
  check(not(R.owns_read r (R.read_request_id original))) "retained ancestor completion was not consumed";
  check((Hashtbl.find views (G.Uuid.to_string(uuid 2))).error=None)
    "remaining shared consumer failed after a binding handover";
  let pending=take_metadata q in
  R.reset r ~graph_generation:None;
  check (not(R.owns_read r (R.read_request_id pending))) "account revocation retained media read";
  reply r pending [];
  check(Queue.is_empty q) "late read after account revocation restarted media work"
;;

let () =
  run_cases
    [ ("binding retains media reads",test_binding_retains_media_reads)
    ; ("binding cleanup precedes waiting reads",test_binding_cleanup_precedes_waiting_reads)
    ; ("binding retains shared facts",test_binding_retains_shared_facts)
    ; ("queued coordinated read retires on Hide",coordinated_read_retirement false)
    ; ("accepted coordinated read retires on reset",coordinated_read_retirement true)
    ; ( "stale initial holder facts refill without poisoning the root"
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
          R.notice r (Resources.notice resource_source (S.Asset_availability
               { consumer = token; asset = asset.uuid; descriptor=asset; availability = Ready "cached" }));
          let acquisition=take_acquire q in
          file_reply r acquisition "held" "/cache/held";
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
                   [ Worker_pure_data.V2_children_interest (uuid 900); Worker_pure_data.V2_page_tree_interest (uuid 900) ]
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
          R.observe_query r ~request_id:(uuid 998) (W.Outline_block { uuid = uuid 1; revision = None });
          for n = 10000 to 14100 do
            change r [ n ]
          done;
          R.observe_query_result r ~request_id:(uuid 998)
            (W.Outline_block { uuid = uuid 1; revision = None })
            (block_value (raw_block ~refs:[ uuid 70 ] 1 900));
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
    ; ( "dependency failure recovers once without user Retry"
      , fun () ->
          let r,q,v,_=fixture() in
          observe r(raw_block 1 60); loaded r q(G.Uuid.to_string(uuid 1))[];
          change r[80];
          (match take_read q with
           | (R.Read { query = W.Outline_block { uuid = block; _ }; _ } as request)
             when block=uuid 60 -> reject_read r request
           | _ -> failwith "missing ancestor must have one owned fact read");
          check(not(Queue.is_empty q)) "first dependency failure must recover in the background";
          let attempts=ref 0 in
          while not(Queue.is_empty q) && !attempts<8 do
            let request=take_read q in incr attempts;reject_read r request
          done;
          check(Queue.is_empty q) "persistent dependency failures entered an automatic loop";
          let root=G.Uuid.to_string(uuid 1) in
          check(Option.is_some(Hashtbl.find v root).error) "persistent dependency error disappeared";
          change r[81];R.pump r;
          check(Queue.is_empty q) "unrelated changes replayed exhausted dependency recovery"
      )
    ; ( "cached facts cannot reset a failed dependency budget"
      , fun () ->
          let r,q,_,_=fixture() in
          seed r q 1 [];
          observe r(raw_block 1 900);
          let fact_reads=ref 0 and listings=ref 0 in
          for _=1 to 3 do
            change r[1];
            let attempts=ref 0 in
            while not(Queue.is_empty q) && !attempts<20 do
              incr attempts;
              match Queue.take q with
              | Read (R.Read { query = W.Outline_block _; _ } as request) ->
                incr fact_reads; reject_read r request
              | Read (R.Read { query = W.Assets _; _ } as request) ->
                incr listings; reply r request []
              | _ -> ()
            done;
            check(Queue.is_empty q) "cached dependency recovery did not terminate"
          done;
          (* Each reapplication can request its root, but a successful asset
             listing cannot grant another dependency recovery on old facts. *)
          check(!fact_reads>=2 && !fact_reads<=3 && !listings=1) "cached old facts restarted failed dependency recovery"
      )
    ; ( "late owned raw response cannot revert reference facts"
      , fun () ->
          let r, q, _, _ = fixture () in
          seed r q 1 [];
          let query = W.Outline_block { uuid = uuid 1; revision = None } in
          R.observe_query r ~request_id:(uuid 997) query;
          R.observe_query r ~request_id:(uuid 998) query;
          R.observe_query_result r ~request_id:(uuid 998) query
            (block_value (raw_block ~refs:[ uuid 71 ] 1 900));
          R.observe_query_result r ~request_id:(uuid 997) query
            (block_value (raw_block ~refs:[ uuid 70 ] 1 900));
          change r [ 70 ];
          check (list_reads q = 0) "older owned response cannot restore removed ref";
          change r [ 71 ];
          check (list_reads q = 1) "newest observed ref still selects membership" )
    ; ( "unregistered raw response cannot inject dependencies"
      , fun () ->
          let r, q, _, _ = fixture () in
          seed r q 1 [];
          R.observe_query_result r ~request_id:(uuid 999)
            (W.Outline_block { uuid = uuid 1; revision = None })
            (block_value (raw_block ~refs:[ uuid 70 ] 1 900));
          change r [ 70 ];
          check (list_reads q = 0) "only registered current-scope facts are accepted" )
    ; ( "unrelated change does not stale in-flight root facts"
      , fun () ->
          let r, q, _, _ = fixture () in
          seed r q 1 [];
          R.observe_query r ~request_id:(uuid 998) (W.Outline_block { uuid = uuid 1; revision = None });
          change r [ 80 ];
          R.observe_query_result r ~request_id:(uuid 998)
            (W.Outline_block { uuid = uuid 1; revision = None })
            (block_value (raw_block ~refs:[ uuid 70 ] 1 900));
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
    ; ( "unknown ancestor is filled through bounded get_outline_block"
      , fun () ->
          let r, q, _, _ = fixture () in
          observe r (raw_block 1 60);
          loaded r q (G.Uuid.to_string (uuid 1)) [];
          (* Drain only dependency lookups, never manufacture a list-assets answer. *)
          let answer () =
            match take_read q with
            | (R.Read { query = W.Outline_block { uuid = block; _ }; _ } as request)
              when block = uuid 60 ->
              answer r request ((fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((block_value (raw_block 60 61))) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))
            | _ -> failwith "unknown ancestor requires a bounded Outline_block query"
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
                  [ Worker_pure_data.V2_children_interest (uuid 900); Worker_pure_data.V2_children_interest (uuid 60) ]
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
    ; ( "metadata failure recovers once without user Retry"
      , fun () ->
          let r,q,v,_=fixture() in seed r q 1[];membership_change r 1 70;
          let request=take_metadata q in reject_read r request;
          check(list_reads q=1) "first metadata failure did not recover automatically";
          let request=take_metadata q in reject_read r request;
          let root=G.Uuid.to_string(uuid 1) in R.root_visible r ~root true;R.pump r;
          check(list_reads q=0 && Option.is_some(Hashtbl.find v root).error)
            "persistent metadata error was hidden or retried indefinitely" )
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
    ; ( "successful File survives same-content metadata and resync"
      , fun () ->
          let r, q, v, _ = fixture () in
          let descriptor c =
            A.create
              ~uuid:(uuid 2)
              ~source:
                (Managed
                   (Some
                      (A.version ~checksum:(String.make 64 'a') ~file_type:"png"
                       |> Result.get_ok)))
              ~current_checksum:None
              ~size:(Some(Int64.of_int(Char.code c)))
              ~dimensions:None
            |> Result.get_ok
          in
          let asset = descriptor 'a'
          and root = G.Uuid.to_string (uuid 1) in
          seed r q 1 [ asset ];
          let token = (List.hd (Hashtbl.find v root).items).token in
          R.asset_visible r ~root ~asset:token true;
          Queue.clear q;
          R.notice r (Resources.notice resource_source (S.Asset_availability
               { consumer = token; asset = asset.uuid; descriptor=asset; availability = Ready "cached" }));
          let acquisition=take_acquire q in
          file_reply r acquisition "held" "/cache/held";
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
            (commands q
             |> Seq.exists (fun command->released_handle command=Some "held"))
            "real membership removal releases the retained File lease" )
    ]
;;

(* Runtime owns the imported receipt lease and the handoff to a normal media
   controller and open-preview references; neither pure reducer owns these. *)
let test_import_handoff preview =
  let sent = Queue.create ()
  and views = Hashtbl.create 1 in
  let runtime =
    R.create
      ~read:(fun request -> Queue.add (Read request) sent; true)
      ~demand:(resource_ports sent (fun()->true)).demand
      ~acquire:(resource_ports sent (fun()->true)).acquire
      ~release_file:(resource_ports sent (fun()->true)).release_file
      ~release_consumer:(resource_ports sent (fun()->true)).release_consumer
      ~retry_asset:(resource_ports sent (fun()->true)).retry_asset
      ~changed:(fun root view -> Hashtbl.replace views root view) ()
  in
  R.reset runtime ~graph_generation:(Some 1);
  let root = G.Uuid.to_string (uuid 1) in
  let scope=resource_source.Resources.scope in
  let asset =
    A.create
      ~uuid:(uuid 2)
      ~source:(Managed None)
      ~current_checksum:(Some (String.make 64 'a'))
      ~size:None
      ~dimensions:None
    |> Result.get_ok
  in
  let receipt : Logseq_db_worker.import_receipt =
    { operation = uuid 8
    ; graph_generation = 1
    ; scope
    ; target = uuid 1
    ; asset
    ; file_type = "png"
    ; preview = Some ("staged-lease", "/staged/original.png")
    }
  in
  let imported=Resources.imported resource_source receipt in
  R.imported runtime ~current:true imported;
  R.root_visible runtime ~root true;
  reply runtime (take_read sent) [ asset ];
  let requests = commands sent |> List.of_seq in
  let consumer =
    List.find_map
      (function
        | Command(_,W.Replace_asset_demand(consumer,_,_))->Some(consumer_name consumer)
        | _ -> None)
      requests
  in
  check (Option.is_some consumer) "imported metadata must start normal local demand";
  check
    ((List.hd (Hashtbl.find views root).items).presentation
     = Journal_media.File "/staged/original.png")
    "handoff keeps preview while acquisition is pending";
  let preview_token = (List.hd (Hashtbl.find views root).items).token in
  let show owner =
    R.preview_visible runtime ~owner ~slot:"selected-import" ~root ~asset:preview_token true
  and close owner =
    R.preview_visible runtime ~owner ~slot:"selected-import" ~root ~asset:preview_token false
  in
  (match preview with
   | `None -> ()
   | `Close | `Prune | `Multiple | `Hidden_close | `Hidden_prune -> show "row");
  if preview = `Multiple then show "detail";
  Queue.clear sent;
  let consumer = Option.get consumer in
  R.notice runtime (Resources.notice resource_source (S.Asset_availability
       { consumer; asset = asset.uuid; descriptor=asset; availability = Ready "normal-cache" }));
  let acquisition=take_acquire sent in
  check (W.asset_file_asset(snd acquisition)=asset.uuid)
    "normal file is acquired";
  file_reply runtime acquisition "normal-lease" "/cache/original.png";
  let release_count () =
    commands sent
    |> Seq.filter (fun command->released_handle command=Some "staged-lease")
    |> Seq.length
  in
  let preview_is_retained () =
    let item = List.hd (Hashtbl.find views root).items in
    check
      (item.token = preview_token
       && item.presentation = Journal_media.File "/staged/original.png"
       && release_count () = 0)
      "an open import preview keeps its token, path and lease during cache handoff"
  in
  (match preview with
   | `None -> ()
   | `Close ->
     preview_is_retained ();
     close "row";
     close "row"
   | `Prune ->
     preview_is_retained ();
     R.retain_owners runtime [ "default" ]
   | `Multiple ->
     preview_is_retained ();
     close "row";
     preview_is_retained ();
     close "detail"
   | `Hidden_close | `Hidden_prune ->
     R.root_visible runtime ~root false;
     preview_is_retained ();
     if preview = `Hidden_close then close "row" else R.retain_owners runtime [];
     check
       (release_count () = 1
        && (List.hd (Hashtbl.find views root).items).token <> preview_token)
       "the final preview owner releases its import even after the row is hidden");
  let items = (Hashtbl.find views root).items in
  if preview <> `Hidden_close && preview <> `Hidden_prune
  then (
    check
      (List.length items = 1
       && (List.hd items).presentation = Journal_media.File "/cache/original.png")
      "normal file replaces staged preview without duplicate items";
    check
      ((List.hd items).file_type = "png")
      "pending local image keeps its type after handoff");
  check
    (List.exists
       (fun command->released_handle command=Some "staged-lease")
       (commands sent |> List.of_seq))
    "normal acquisition releases staged preview";
  check (release_count () = 1) "handoff or final preview close releases its lease once";
  Queue.clear sent;
  R.reset runtime ~graph_generation:None;
  check
    (not
       (List.exists
          (fun command->released_handle command=Some "staged-lease")
          (commands sent |> List.of_seq)))
    "handoff releases staged preview only once"
;;

let () =
  run_cases
    [ "import handoff without preview", (fun () -> test_import_handoff `None)
    ; "open import preview survives handoff", (fun () -> test_import_handoff `Close)
    ; "import preview owner cleanup", (fun () -> test_import_handoff `Prune)
    ; "import handoff waits for final preview", (fun () -> test_import_handoff `Multiple)
    ; "hidden import preview close", (fun () -> test_import_handoff `Hidden_close)
    ; "hidden import preview owner cleanup", (fun () -> test_import_handoff `Hidden_prune)
    ]
;;

let () =
  let sent = Queue.create ()
  and views = Hashtbl.create 1 in
  let runtime =
    R.create
      ~read:(fun request -> Queue.add (Read request) sent; true)
      ~demand:(resource_ports sent (fun()->true)).demand
      ~acquire:(resource_ports sent (fun()->true)).acquire
      ~release_file:(resource_ports sent (fun()->true)).release_file
      ~release_consumer:(resource_ports sent (fun()->true)).release_consumer
      ~retry_asset:(resource_ports sent (fun()->true)).retry_asset
      ~changed:(fun root view -> Hashtbl.replace views root view) ()
  in
  R.reset runtime ~graph_generation:(Some 1);
  let scope=resource_source.Resources.scope in
  let asset =
    A.create
      ~uuid:(uuid 2)
      ~source:(Managed None)
      ~current_checksum:(Some (String.make 64 'a'))
      ~size:None
      ~dimensions:None
    |> Result.get_ok
  in
  let receipt : Logseq_db_worker.import_receipt =
    { operation = uuid 8
    ; graph_generation = 1
    ; scope
    ; target = uuid 1
    ; asset
    ; file_type = "png"
    ; preview = Some ("cancelled-preview", "/staged/original.png")
    }
  in
  let imported=Resources.imported resource_source receipt in
  let root = G.Uuid.to_string receipt.target in
  let notice =
    S.Upload_status
      { operation = receipt.operation
      ; asset = asset.uuid
      ; target = receipt.target
      ; title = "fixture"
      ; status = Cancelled
      }
  in
  R.imported runtime ~current:true imported;
  R.notice runtime (Resources.notice (Resources.create ~graph:(uuid 90) ~graph_generation:1 8190L) notice);
  check
    (List.length (Hashtbl.find views root).items = 1 && Queue.is_empty sent)
    "foreign scope cannot cancel imported preview";
  R.notice runtime (Resources.notice resource_source notice);
  check ((Hashtbl.find views root).items = []) "cancelled unpublished preview disappears";
  check
    (List.exists
       (fun command->released_handle command=Some "cancelled-preview")
       (commands sent |> List.of_seq))
    "cancellation releases its staged preview";
  Queue.clear sent;
  R.notice runtime (Resources.notice resource_source notice);
  check (Queue.is_empty sent) "duplicate cancellation releases no second lease"
;;
