module T = Logseq_db_worker_test_support.Test_support
module Scope = Logseq_db_worker.Sync_network_scope

let test_generation_cancellation () =
  let scope = Scope.create () in
  let account_cancelled = ref 0 in
  let old_graph_cancelled = ref 0 in
  let current_graph_cancelled = ref 0 in
  let account_operation =
    Scope.register scope ~account_generation:1 ~graph_generation:None ~cancel:(fun () ->
      incr account_cancelled)
  in
  ignore
    (Scope.register
       scope
       ~account_generation:1
       ~graph_generation:(Some 1)
       ~cancel:(fun () -> incr old_graph_cancelled)
     : Scope.operation_id);
  let current_graph_operation =
    Scope.register
      scope
      ~account_generation:1
      ~graph_generation:(Some 2)
      ~cancel:(fun () -> incr current_graph_cancelled)
  in
  Scope.cancel_obsolete scope ~account_generation:1 ~graph_generation:2;
  T.require (!old_graph_cancelled = 1) "obsolete graph operation was not cancelled";
  T.require (!account_cancelled = 0) "current account operation was cancelled";
  T.require (!current_graph_cancelled = 0) "current graph operation was cancelled";
  Scope.cancel_obsolete scope ~account_generation:1 ~graph_generation:2;
  T.require (!old_graph_cancelled = 1) "operation was cancelled more than once";
  Scope.cancel_graph scope ~account_generation:1 ~graph_generation:2;
  T.require (!current_graph_cancelled = 1) "current graph operation was not cancelled";
  Scope.complete scope current_graph_operation;
  Scope.cancel_all scope;
  T.require (!account_cancelled = 1) "account operation survived account cancellation";
  T.require (!current_graph_cancelled = 1) "graph operation was cancelled more than once";
  Scope.complete scope account_operation
;;

let test_account_cancellation () =
  let scope = Scope.create () in
  let cancelled = ref 0 in
  ignore
    (Scope.register scope ~account_generation:4 ~graph_generation:None ~cancel:(fun () ->
       incr cancelled)
     : Scope.operation_id);
  ignore
    (Scope.register
       scope
       ~account_generation:4
       ~graph_generation:(Some 9)
       ~cancel:(fun () -> incr cancelled)
     : Scope.operation_id);
  Scope.cancel_obsolete scope ~account_generation:5 ~graph_generation:0;
  T.require (!cancelled = 2) "account generation change retained network operations";
  T.require (Scope.active_count scope = 0) "cancelled operations remained active"
;;

let () =
  T.run
    "sync-network-scope"
    [ T.case "generation cancellation" test_generation_cancellation
    ; T.case "account cancellation" test_account_cancellation
    ]
;;
