module Account = Journal_sync_lifecycle.Account
module Dsl = Sync_dsl.Core
module Graph = Logseq_db_types.Managed_graph
module Uuid = Logseq_db_types.Graph_types.Uuid

let check label condition = if not condition then failwith label
let ok = function Ok value -> value | Error error -> failwith (Dsl.error_message error)

let graph index : Graph.t =
  { graph_id = Uuid.of_string (Printf.sprintf "71000000-0000-4000-8000-%012d" index) |> Result.get_ok
  ; name = string_of_int index
  ; schema = { major = 65; minor = 33; exact = true }
  ; encrypted = false
  }
;;

type fixture =
  { controller : Account.t
  ; account : Account.account
  ; starts : (Uuid.t * int64 * int64) list ref
  ; store_reused : bool list ref
  ; closed : Uuid.t list ref
  ; deleted : Uuid.t list ref
  ; start_error : Dsl.error option ref
  ; close_error : Dsl.error option ref
  ; fetches : int ref
  }

let fixture run =
  let root = Filename.temp_file "worker-account-migration" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () ->
      Array.iter (fun name -> Sys.remove (Filename.concat root name)) (Sys.readdir root);
      Unix.rmdir root)
    (fun () ->
      let account : Account.account = { origin="https://example.invalid"; account="synthetic"; root } in
      let starts=ref [] and closed=ref [] and deleted=ref [] in
      let store_reused=ref [] and previous_store=ref None in
      let start_error=ref None and close_error=ref None and fetches=ref 0 in
      let controller=Account.create ~maximum_services:3
        ~catalog:(fun ~account:_ ~check_current ~gate:_ ->
          incr fetches;
          Result.map (fun () -> List.init 3 (fun index -> graph (index+1))) (check_current ()))
        ~start:(fun ~account:_ ~account_generation ~graph_generation ~graph ~upload_store ~network:_ ~on_change:_ ->
          starts := !starts @ [graph.Graph.graph_id,account_generation,graph_generation];
          store_reused := !store_reused @ [Option.fold ~none:true ~some:((==) upload_store) !previous_store];
          previous_store := Some upload_store;
          match !start_error with
          | Some error -> Error error
          | None -> Ok (Account.service ~set_network:(fun _ -> Ok ()) ~close:(fun () ->
              closed := !closed @ [graph.graph_id];
              match !close_error with Some error -> Error error | None -> Ok ())))
        ~delete_local:(fun ~account:_ ~graph -> deleted := !deleted @ [graph.Graph.graph_id]; Ok ())
        ~on_change:(fun _ _ -> ()) |> ok in
      ok (Account.replace controller account);
      Fun.protect
        ~finally:(fun () -> close_error:=None; ok (Account.logout controller))
        (fun () -> run {controller;account;starts;store_reused;closed;deleted;start_error;close_error;fetches}))
;;

let startup_failure () =
  List.iter (fun error -> fixture (fun fixture ->
    ok (Account.restore_catalog fixture.controller [graph 1]);
    fixture.start_error := Some error;
    check "service startup preserves its concrete cause"
      (Account.select fixture.controller (graph 1).graph_id = Error error);
    check "failed bootstrap never publishes a service"
      (Account.service_count fixture.controller=0 && Account.selected fixture.controller=None);
    check "non-network failure does not trigger an automatic retry" (List.length !(fixture.starts)=1);
    fixture.start_error := None;
    ok (Account.select fixture.controller (graph 1).graph_id);
    let _,_,failed_generation=List.hd !(fixture.starts) in
    let _,_,opened_generation=List.nth !(fixture.starts) 1 in
    check "corrected startup uses a new execution generation" (opened_generation>failed_generation)))
    [Dsl.Storage_failure "local mirror is closed";
     Dsl.Protocol_failure "Graph schema 65.29 is not supported";
     Dsl.Crypto_failure "invalid graph key";
     Dsl.Activation_failure (Snapshot_parse_error "unsupported synthetic snapshot schema");
     Dsl.Authoritative_failure Authoritative_database_closed;
     Dsl.Authoritative_failure Authoritative_sync_token_conflict;
     Dsl.Authoritative_failure Authoritative_cursor_discontinuous;
     Dsl.Authoritative_failure (Authoritative_decode_failed "unsupported synthetic transaction")]
;;

let local_residents () =
  List.iter (fun count -> fixture (fun fixture ->
    let graphs=List.init count (fun index -> graph (index+1)) in
    ok (Account.restore_catalog fixture.controller graphs);
    List.iter (fun graph -> ok (Account.select fixture.controller graph.Graph.graph_id)) graphs;
    check "offline restoration does not fetch catalog" (!(fixture.fetches)=0);
    check "all cached residents started" (Account.service_count fixture.controller=count);
    check "last restored graph remains selected"
      (Account.selected fixture.controller=Some (List.nth graphs (count-1)).graph_id);
    let before= !(fixture.starts) in
    List.iter (fun graph -> ok (Account.select fixture.controller graph.Graph.graph_id)) graphs;
    check "focus never restarts a warm resident" (!(fixture.starts)=before);
    check "all residents borrow the same account store" (List.for_all Fun.id !(fixture.store_reused))))
    [1;2;3]
;;

let retirement_and_replacement () =
  fixture (fun fixture ->
    ok (Account.restore_catalog fixture.controller [graph 1;graph 2]);
    List.iter (fun graph -> ok (Account.select fixture.controller graph.Graph.graph_id)) [graph 1;graph 2];
    let _,account_generation,_=List.hd !(fixture.starts) in
    ok (Account.replace fixture.controller fixture.account);
    check "replacement physically closes every resident"
      (List.sort_uniq compare !(fixture.closed)=[(graph 1).graph_id;(graph 2).graph_id]);
    check "replacement clears selection and services"
      (Account.selected fixture.controller=None && Account.service_count fixture.controller=0);
    ok (Account.restore_catalog fixture.controller [graph 1]);
    ok (Account.select fixture.controller (graph 1).graph_id);
    let _,next_account,_=List.nth !(fixture.starts) 2 in
    check "replacement does not borrow the retired store" (next_account>account_generation && not(List.nth !(fixture.store_reused) 2));
    ok (Account.logout fixture.controller);
    check "logout closes the replacement resident" (List.length !(fixture.closed)=3))
;;

let deletion_waits_for_physical_close () =
  fixture (fun fixture ->
    ok (Account.restore_catalog fixture.controller [graph 1;graph 2]);
    List.iter (fun graph -> ok (Account.select fixture.controller graph.Graph.graph_id)) [graph 1;graph 2];
    let error=Dsl.Storage_failure "reader still owns the database" in
    fixture.close_error:=Some error;
    check "deletion exposes physical close failure"
      (Account.delete_local fixture.controller (graph 1).graph_id=Error error);
    check "no private deletion before physical close"
      (!(fixture.deleted)=[] && Account.service_count fixture.controller=2);
    check "unrelated selected graph stays live" (Account.selected fixture.controller=Some (graph 2).graph_id);
    fixture.close_error:=None;
    ok (Account.delete_local fixture.controller (graph 1).graph_id);
    check "exact target is deleted after close" (!(fixture.deleted)=[(graph 1).graph_id]);
    check "private deletion does not retire unrelated service"
      (Account.service_count fixture.controller=1 && Account.selected fixture.controller=Some (graph 2).graph_id))
;;

let revoked_account_blocks_producers () =
  fixture (fun fixture ->
    ok (Account.restore_catalog fixture.controller [graph 1;graph 2]);
    List.iter (fun graph -> ok (Account.select fixture.controller graph.Graph.graph_id)) [graph 1;graph 2];
    let error=Dsl.Storage_failure "hidden resource has not joined" in
    fixture.close_error:=Some error;
    check "logout reports unsettled cleanup" (Account.logout fixture.controller=Error error);
    let starts=List.length !(fixture.starts) and fetches= !(fixture.fetches) in
    check "revoked account cannot refresh" (Account.refresh fixture.controller=Error Dsl.Stale_context);
    check "revoked account cannot allocate a graph"
      (Account.select fixture.controller (graph 3).graph_id=Error Dsl.Stale_context);
    check "replacement cannot steal an unsettled owner" (Account.replace fixture.controller fixture.account=Error error);
    check "no catalog or graph producer after revocation"
      (List.length !(fixture.starts)=starts && !(fixture.fetches)=fetches);
    check "unsettled services retain original store ownership" (Account.service_count fixture.controller=2))
;;

let target_retirement_preserves_other_execution () =
  fixture (fun fixture ->
    ok (Account.restore_catalog fixture.controller [graph 1;graph 2]);
    List.iter (fun graph -> ok (Account.select fixture.controller graph.Graph.graph_id)) [graph 1;graph 2];
    let before=List.nth !(fixture.starts) 1 in
    ok (Account.release_graph fixture.controller (graph 1).graph_id);
    check "only target physically closes" (!(fixture.closed)=[(graph 1).graph_id]);
    ok (Account.select fixture.controller (graph 2).graph_id);
    check "unrelated execution is preserved" (List.length !(fixture.starts)=2 && List.nth !(fixture.starts) 1=before);
    ok (Account.select fixture.controller (graph 1).graph_id);
    let _,_,old_generation=List.hd !(fixture.starts) in
    let _,_,new_generation=List.nth !(fixture.starts) 2 in
    check "reopened graph has a fresh physical generation" (new_generation>old_generation))
;;

let () =
  List.iter (fun (name,run) -> run (); Printf.printf "PASS migrated %s\n%!" name)
    ["bootstrap and local restore failures",startup_failure;
     "cached residents and warm focus",local_residents;
     "all-resident retirement and replacement",retirement_and_replacement;
     "private deletion waits for close",deletion_waits_for_physical_close;
     "revoked account producer gate",revoked_account_blocks_producers;
     "target retirement preserves other execution",target_retirement_preserves_other_execution]
