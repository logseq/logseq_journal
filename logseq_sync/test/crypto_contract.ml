module D = Sync_dsl.Core
module C = Logseq_sync_crypto.Core

let get = function
  | Ok value -> value
  | Error error -> Alcotest.fail (D.error_message error)
;;

let identity account =
  get
    (D.identity
       ~origin:"https://example.com"
       ~account
       ~graph:"g"
       ~account_generation:0L
       ~graph_generation:0L)
;;

let limits =
  get
    (D.limits
       ~maximum_items:8
       ~maximum_bytes:1024
       ~maximum_pending:8
       ~maximum_resources:8
       ~steps_per_turn:8
       ~maximum_tasks:8
       ~maximum_messages:8
       ~maximum_message_bytes:1024
       ~maximum_demands:8
       ~maximum_active_assets:2
       ~foreground_reserve:1
       ~foreground_demand_reserve:1
       ~foreground_descriptor_reserve_bytes:128
       ~asset_cache_budget_bytes:4096L
       ~asset_maximum_file_bytes:1024
       ~asset_pending_budget_bytes:4096L
       ~snapshot_maximum_artifact_bytes:4096L
       ~snapshot_staging_budget_bytes:4096L
       ~snapshot_scratch_budget_bytes:4096L)
;;

let create encrypted =
  C.create ~identity:(identity "a") ~limits ~encrypted ~backend:C.apple_backend
;;

let run t operation =
  C.run t ~identity:(identity "a") ~check_current:(fun () -> Ok ()) operation
;;

let check_error expected = function
  | Error error -> Alcotest.(check string) "error" expected (D.error_message error)
  | Ok _ -> Alcotest.fail "Expected rejection"
;;

let unencrypted () =
  let t = create false in
  Alcotest.(check string) "plain string" "hello" (get (run t (D.Decrypt_value "hello")));
  Alcotest.(check string)
    "Transit string"
    "hello"
    (get (run t (D.Decrypt_value "\"hello\"")));
  check_error
    (D.error_message (D.Crypto_failure "Encryption requires a graph key"))
    (run t (D.Encrypt_values (Rrbvec.of_list [ "secret" ])))
;;

let locked () =
  let t = create true in
  check_error (D.error_message D.Locked) (run t (D.Decrypt_value "hello"));
  check_error
    (D.error_message D.Stale_context)
    (C.run
       t
       ~identity:(identity "a")
       ~check_current:(fun () -> Error D.Stale_context)
       (D.Decrypt_value "hello"))
;;

let ownership () =
  let t = create false in
  check_error
    (D.error_message (D.Identity_mismatch "Crypto owner"))
    (C.run
       t
       ~identity:(identity "other")
       ~check_current:(fun () -> Ok ())
       (D.Decrypt_value "hello"));
  C.retire t;
  check_error (D.error_message D.Stale_context) (run t (D.Decrypt_value "hello"))
;;

let bounds () =
  let t = create false in
  check_error
    (D.error_message (D.Capacity_exceeded "Crypto bytes"))
    (run t (D.Decrypt_value (String.make 1025 'a')));
  check_error
    (D.error_message (D.Crypto_failure "Protected value must be a string"))
    (run t (D.Decrypt_value "42"))
;;

let encrypted_roundtrip () =
  let module Aes = Mirage_crypto.AES.GCM in
  let backend : C.backend =
    { unlock = (fun ~identity:_ ~wrapped_graph_key:_ -> Ok (String.make 32 'k'))
    ; crypto =
        { encrypt_aes_gcm =
            (fun ~key ~plaintext ->
              let iv = String.make 12 'i' in
              Ok
                (iv, Aes.authenticate_encrypt ~key:(Aes.of_secret key) ~nonce:iv plaintext))
        ; decrypt_aes_gcm =
            (fun ~key ~iv ~ciphertext ->
              match
                Aes.authenticate_decrypt ~key:(Aes.of_secret key) ~nonce:iv ciphertext
              with
              | Some plaintext -> Ok plaintext
              | None -> Error "Authentication failed")
        }
    }
  in
  let t = C.create ~identity:(identity "a") ~limits ~encrypted:true ~backend in
  let input = get (D.unlock_input ~wrapped_graph_key:"wrapped") in
  ignore (get (run t (D.Unlock input)));
  let encrypted =
    get (run t (D.Encrypt_values (Rrbvec.of_list [ "\"hello\""; "\"world\"" ])))
    |> Rrbvec.to_list
  in
  let wire (iv, ciphertext) =
    Transit_native.Transit.Json.to_string
      (Transit_core.Json.Array [ Binary iv; Binary ciphertext ])
  in
  Alcotest.(check (list string))
    "ordered authenticated plaintexts"
    [ "hello"; "world" ]
    (List.map (fun encrypted -> get (run t (D.Decrypt_value (wire encrypted)))) encrypted);
  let iv, ciphertext = List.hd encrypted in
  let corrupted = Bytes.of_string ciphertext in
  Bytes.set corrupted 0 (Char.chr (Char.code (Bytes.get corrupted 0) lxor 1));
  (match run t (D.Decrypt_value (wire (iv, Bytes.to_string corrupted))) with
   | Error (D.Crypto_failure _) -> ()
   | _ -> Alcotest.fail "Authenticated ciphertext corruption must fail");
  check_error
    (D.error_message (D.Capacity_exceeded "Crypto items"))
    (run t (D.Encrypt_values (Rrbvec.of_list (List.init 9 (fun _ -> "value")))));
  C.retire t;
  check_error
    (D.error_message D.Stale_context)
    (run t (D.Decrypt_value (wire (iv, ciphertext))))
;;

let unlock_revocation () =
  let current = ref true in
  let backend =
    { C.apple_backend with
      unlock =
        (fun ~identity:_ ~wrapped_graph_key:_ ->
          current := false;
          Ok (String.make 32 'k'))
    }
  in
  let owner = C.create ~identity:(identity "a") ~limits ~encrypted:true ~backend in
  let input = get (D.unlock_input ~wrapped_graph_key:"wrapped") in
  check_error
    (D.error_message D.Stale_context)
    (C.run
       owner
       ~identity:(identity "a")
       ~check_current:(fun () -> if !current then Ok () else Error D.Stale_context)
       (D.Unlock input));
  Alcotest.(check bool)
    "revoked unlock never installs key"
    true
    (C.status owner = D.Key_locked)
;;

let () =
  Alcotest.run
    "production crypto"
    [ ( "scope"
      , [ Alcotest.test_case "unencrypted" `Quick unencrypted
        ; Alcotest.test_case "locked and revoked" `Quick locked
        ; Alcotest.test_case "owner and retirement" `Quick ownership
        ; Alcotest.test_case "budgets and shape" `Quick bounds
        ; Alcotest.test_case "authenticated roundtrip" `Quick encrypted_roundtrip
        ; Alcotest.test_case "unlock revocation" `Quick unlock_revocation
        ] )
    ]
;;
