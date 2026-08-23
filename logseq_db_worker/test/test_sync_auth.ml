module T = Logseq_db_worker_test_support.Test_support
module A = Logseq_db_worker.Sync_auth

let contains text needle =
  let rec loop offset =
    if offset + String.length needle > String.length text
    then false
    else if String.sub text offset (String.length needle) = needle
    then true
    else loop (offset + 1)
  in
  String.length needle = 0 || loop 0
;;

let next_id =
  let value = ref 0 in
  fun () ->
    incr value;
    Printf.sprintf "challenge-%d" !value
;;

let issue auth =
  A.issue
    auth
    ~purpose:Catalog_discovery
    ~user_id:"user-1"
    ~account_generation:7
    ~graph_generation:None
    ~connection_generation:None
;;

let test_correlates_and_consumes_exactly_once () =
  let auth = A.create ~next_id () in
  let challenge = issue auth in
  T.require (A.pending_count auth = 1) "challenge was not retained";
  let accepted =
    A.provide
      auth
      ~challenge_id:challenge.challenge_id
      ~user_id:"user-1"
      ~account_generation:7
      ~graph_generation:None
      ~connection_generation:None
      ~token:"secret-id-token"
  in
  (match accepted with
   | Ok (resolved, token) ->
     T.require
       (String.equal resolved.challenge_id challenge.challenge_id)
       "resolved the wrong challenge";
     T.require (String.equal token "secret-id-token") "token changed"
   | Error _ -> T.fail "valid token response was rejected");
  T.require (A.pending_count auth = 0) "accepted token remained pending";
  T.require
    (A.provide
       auth
       ~challenge_id:challenge.challenge_id
       ~user_id:"user-1"
       ~account_generation:7
       ~graph_generation:None
       ~connection_generation:None
       ~token:"duplicate"
     = Error Unknown_challenge)
    "duplicate token response was accepted";
  T.require
    (not (contains (A.diagnostics auth) "secret-id-token"))
    "diagnostics exposed secret token text"
;;

let test_rejects_wrong_identity_and_generation_without_consuming () =
  let auth = A.create ~next_id () in
  let challenge = issue auth in
  let provide ~user_id ~account_generation ~graph_generation ~connection_generation =
    A.provide
      auth
      ~challenge_id:challenge.challenge_id
      ~user_id
      ~account_generation
      ~graph_generation
      ~connection_generation
      ~token:"bounded-token"
  in
  T.require
    (provide
       ~user_id:"other-user"
       ~account_generation:7
       ~graph_generation:None
       ~connection_generation:None
     = Error User_mismatch)
    "wrong user was accepted";
  T.require
    (provide
       ~user_id:"user-1"
       ~account_generation:8
       ~graph_generation:None
       ~connection_generation:None
     = Error Account_generation_mismatch)
    "wrong account generation was accepted";
  T.require (A.pending_count auth = 1) "rejected response consumed challenge";
  A.cancel_all auth;
  T.require (A.pending_count auth = 0) "cancellation retained challenges"
;;

let test_graph_and_connection_fences () =
  let auth = A.create ~next_id () in
  let challenge =
    A.issue
      auth
      ~purpose:Websocket_connect
      ~user_id:"user-1"
      ~account_generation:4
      ~graph_generation:(Some 9)
      ~connection_generation:(Some 3)
  in
  let provide graph_generation connection_generation =
    A.provide
      auth
      ~challenge_id:challenge.challenge_id
      ~user_id:"user-1"
      ~account_generation:4
      ~graph_generation
      ~connection_generation
      ~token:"token"
  in
  T.require
    (provide (Some 8) (Some 3) = Error Graph_generation_mismatch)
    "late graph token was accepted";
  T.require
    (provide (Some 9) (Some 2) = Error Connection_generation_mismatch)
    "late connection token was accepted";
  T.require
    (match provide (Some 9) (Some 3) with
     | Ok _ -> true
     | Error _ -> false)
    "current graph and connection token was rejected"
;;

let () =
  test_correlates_and_consumes_exactly_once ();
  test_rejects_wrong_identity_and_generation_without_consuming ();
  test_graph_and_connection_fences ()
;;
