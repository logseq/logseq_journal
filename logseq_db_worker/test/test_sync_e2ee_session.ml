module T = Logseq_db_worker_test_support.Test_support
module S = Logseq_db_worker.Sync_e2ee_session
module Uuid = Logseq_db_worker.Graph_types.Uuid

let graph_id = Uuid.of_string "10000000-0000-4000-8000-000000000001" |> Result.get_ok

let test_cached_private_key_unlocks_without_password () =
  let decryptions = ref [] in
  let platform =
    S.
      { has_private_key = (fun ~user_id:_ -> true)
      ; unlock_private_key =
          (fun ~user_id:_ ~password:_ ~private_key_package:_ ->
            T.fail "cached private key requested a password")
      ; decrypt_graph_key =
          (fun ~user_id ~encrypted_graph_key ->
            decryptions := (user_id, encrypted_graph_key) :: !decryptions;
            Ok (String.make 32 'g'))
      }
  in
  let session = S.create ~platform ~user_id:"user-1" ~graph_id ~graph_name:"Encrypted" in
  let wrapped = {|["~#'","~bZ3JhcGgta2V5"]|} in
  let response =
    Yojson.Safe.to_string (`Assoc [ "encrypted-aes-key", `String wrapped ])
  in
  (match S.accept_graph_key_response session response with
   | Ok () -> ()
   | Error message -> T.fail "cached-key session failed: %s" message);
  T.require (S.phase session = Ready) "cached key did not become ready";
  T.require (S.graph_key session = Some (String.make 32 'g')) "graph key was not retained";
  T.require
    (!decryptions = [ "user-1", wrapped ])
    "platform received wrong bounded inputs"
;;

let test_missing_private_key_prompts_only_after_user_key_response () =
  let unlocked = ref None in
  let platform =
    S.
      { has_private_key = (fun ~user_id:_ -> false)
      ; unlock_private_key =
          (fun ~user_id ~password ~private_key_package ->
            unlocked := Some (user_id, password, private_key_package);
            Ok ())
      ; decrypt_graph_key =
          (fun ~user_id:_ ~encrypted_graph_key:_ -> Ok (String.make 32 'k'))
      }
  in
  let session = S.create ~platform ~user_id:"user-2" ~graph_id ~graph_name:"Secrets" in
  let wrapped = {|["~#'","~bZ3JhcGgta2V5"]|} in
  let graph_response =
    Yojson.Safe.to_string (`Assoc [ "encrypted-aes-key", `String wrapped ])
  in
  ignore (S.accept_graph_key_response session graph_response : (unit, string) result);
  T.require
    (S.phase session = Fetching_user_keys)
    "missing private key skipped user-key fetch";
  let package = {|["20251210","~bc2FsdA","~baXY","~bY2lwaGVydGV4dA"]|} in
  let user_response =
    Yojson.Safe.to_string
      (`Assoc
          [ "public-key", `String "bounded-public-key-package"
          ; "encrypted-private-key", `String package
          ])
  in
  ignore (S.accept_user_keys_response session user_response : (unit, string) result);
  T.require
    (S.phase session = Awaiting_password)
    "user keys did not enter password prompt";
  T.require (Result.is_error (S.submit_password session "")) "empty password was accepted";
  (match S.submit_password session "correct horse battery staple" with
   | Ok () -> ()
   | Error message -> T.fail "valid password failed: %s" message);
  T.require
    (!unlocked = Some ("user-2", "correct horse battery staple", package))
    "platform unlock received the wrong bounded operation inputs";
  T.require (S.phase session = Ready) "password unlock did not become ready";
  S.clear session;
  T.require (S.graph_key session = None) "clear retained plaintext graph key"
;;

let test_rejects_malformed_endpoint_contracts () =
  let platform =
    S.
      { has_private_key = (fun ~user_id:_ -> true)
      ; unlock_private_key = (fun ~user_id:_ ~password:_ ~private_key_package:_ -> Ok ())
      ; decrypt_graph_key =
          (fun ~user_id:_ ~encrypted_graph_key:_ -> Ok (String.make 32 'x'))
      }
  in
  List.iter
    (fun response ->
       let session = S.create ~platform ~user_id:"user" ~graph_id ~graph_name:"Graph" in
       T.require
         (Result.is_error (S.accept_graph_key_response session response))
         "malformed E2EE graph-key response was accepted")
    [ "{}"; {|{"encrypted-aes-key":""}|}; {|{"encrypted-aes-key":7}|} ]
;;

let test_rejects_obsolete_or_malformed_user_key_contracts () =
  let platform =
    S.
      { has_private_key = (fun ~user_id:_ -> false)
      ; unlock_private_key = (fun ~user_id:_ ~password:_ ~private_key_package:_ -> Ok ())
      ; decrypt_graph_key =
          (fun ~user_id:_ ~encrypted_graph_key:_ -> Ok (String.make 32 'x'))
      }
  in
  let graph_response = {|{"encrypted-aes-key":"wrapped-graph-key"}|} in
  List.iter
    (fun response ->
       let session = S.create ~platform ~user_id:"user" ~graph_id ~graph_name:"Graph" in
       ignore (S.accept_graph_key_response session graph_response : (unit, string) result);
       T.require
         (Result.is_error (S.accept_user_keys_response session response))
         "obsolete or malformed E2EE user-key response was accepted")
    [ {|{"encrypted-private-key":"private"}|}
    ; {|{"public-key":"public"}|}
    ; {|{"public-key":"","encrypted-private-key":"private"}|}
    ; {|{"public-key":"public","encrypted-private-key":7}|}
    ; {|{"public-key":"public","encrypted-private-key":"private","extra":"field"}|}
    ]
;;

let () =
  test_cached_private_key_unlocks_without_password ();
  test_missing_private_key_prompts_only_after_user_key_response ();
  test_rejects_malformed_endpoint_contracts ();
  test_rejects_obsolete_or_malformed_user_key_contracts ()
;;
