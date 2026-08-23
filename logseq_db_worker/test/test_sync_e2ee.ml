module T = Logseq_db_worker_test_support.Test_support
module Transit = Transit_core.Json
module Codec = Transit_native.Transit.Json
module E2ee = Logseq_db_worker.Sync_e2ee

let expect_ok label = function
  | Ok value -> value
  | Error message -> T.fail "%s: %s" label message
;;

let expect_error label = function
  | Error _ -> ()
  | Ok _ -> T.fail "%s unexpectedly succeeded" label
;;

let fixture () = T.read_json (T.fixture "sync/upstream-fab2774-e2ee.json")

let private_key_package name =
  let open Yojson.Safe.Util in
  let package = fixture () |> member name in
  let values =
    [ Transit.Binary (package |> member "salt" |> to_string)
    ; Transit.Binary (package |> member "iv" |> to_string)
    ; Transit.Binary (package |> member "ciphertext" |> to_string)
    ]
  in
  let values =
    match package |> member "version" with
    | `Null -> values
    | value -> Transit.String (to_string value) :: values
  in
  Codec.to_string (Transit.Array values)
;;

let encrypted_graph_key () =
  let value =
    fixture ()
    |> Yojson.Safe.Util.member "encryptedGraphKey"
    |> Yojson.Safe.Util.to_string
  in
  Codec.to_string (Transit.Binary value)
;;

let crypto calls =
  E2ee.
    { decrypt_private_key =
        (fun ~password ~iterations ~salt ~iv ~ciphertext ->
          calls
          := Printf.sprintf
               "private:%s:%d:%s:%s:%s"
               password
               iterations
               salt
               iv
               ciphertext
             :: !calls;
          Ok "private-key")
    ; decrypt_graph_key =
        (fun ~private_key ~ciphertext ->
          calls := ("graph:" ^ private_key ^ ":" ^ ciphertext) :: !calls;
          Ok "graph-key")
    ; encrypt_aes_gcm =
        (fun ~key ~plaintext ->
          calls := ("seal:" ^ key ^ ":" ^ plaintext) :: !calls;
          Ok ("value-iv", "encrypted-value"))
    ; decrypt_aes_gcm =
        (fun ~key ~iv ~ciphertext ->
          calls := ("open:" ^ key ^ ":" ^ iv ^ ":" ^ ciphertext) :: !calls;
          Ok (Codec.to_string (Transit.String "Decrypted title")))
    }
;;

let unlock_package_case () =
  let current_calls = ref [] in
  let current =
    E2ee.unlock_graph_key
      ~crypto:(crypto current_calls)
      ~password:"e2etest"
      ~private_key_package:(private_key_package "currentPrivateKeyPackage")
      ~encrypted_graph_key:(encrypted_graph_key ())
    |> expect_ok "current key package"
  in
  T.require (String.equal current "graph-key") "current graph key changed";
  T.require
    (List.exists
       (fun call -> String.starts_with ~prefix:"private:e2etest:600000:" call)
       !current_calls)
    "current key package did not use 600000 PBKDF2 iterations";
  expect_error
    "legacy private key package"
    (E2ee.unlock_graph_key
       ~crypto:(crypto (ref []))
       ~password:"e2etest"
       ~private_key_package:(private_key_package "legacyPrivateKeyPackage")
       ~encrypted_graph_key:(encrypted_graph_key ()))
;;

let protected_attribute_case () =
  let expected =
    fixture ()
    |> Yojson.Safe.Util.member "protectedAttributes"
    |> Yojson.Safe.Util.to_list
    |> List.map Yojson.Safe.Util.to_string
  in
  T.require
    (E2ee.protected_attributes = expected)
    "protected attribute set diverged from upstream";
  let transform = function
    | Transit.String value -> Ok (Transit.String ("cipher:" ^ value))
    | _ -> Error "expected string"
  in
  let apply attribute value =
    E2ee.transform_attribute_value ~transform ~attribute value |> expect_ok attribute
  in
  T.require
    (apply "block/title" (Transit.String "Title") = Transit.String "cipher:Title")
    "block/title stayed plaintext";
  T.require
    (apply "block/name" (Transit.String "name") = Transit.String "cipher:name")
    "block/name stayed plaintext";
  T.require
    (apply "logseq.property/status" (Transit.Keyword "logseq.property/status.todo")
     = Transit.Keyword "logseq.property/status.todo")
    "unprotected structural value was transformed";
  expect_error
    "protected non-string"
    (E2ee.transform_attribute_value ~transform ~attribute:"block/title" (Transit.Int 1))
;;

let encrypted_value_case () =
  let calls = ref [] in
  let encrypted =
    E2ee.encrypt_value
      ~crypto:(crypto calls)
      ~graph_key:"graph-key"
      (Transit.String "Plain title")
    |> expect_ok "encrypt protected value"
  in
  (match Codec.of_string encrypted with
   | Transit.Array [ Transit.Binary "value-iv"; Transit.Binary "encrypted-value" ] -> ()
   | _ -> T.fail "encrypted value is not the upstream Transit AES-GCM envelope");
  (match E2ee.decrypt_value ~crypto:(crypto calls) ~graph_key:"graph-key" encrypted with
   | Ok (Transit.String "Decrypted title") -> ()
   | Ok _ -> T.fail "decrypted value lost its Transit type"
   | Error message -> T.fail "decrypt protected value: %s" message);
  let calls_before_plaintext = List.length !calls in
  (match
     E2ee.decrypt_value
       ~crypto:(crypto calls)
       ~graph_key:"graph-key"
       (Codec.to_string (Transit.String "plaintext"))
   with
   | Ok (Transit.String "plaintext") -> ()
   | Ok _ -> T.fail "Transit plaintext changed type"
   | Error message -> T.fail "Transit plaintext was rejected: %s" message);
  (match
     E2ee.decrypt_value ~crypto:(crypto calls) ~graph_key:"graph-key" "raw plaintext"
   with
   | Ok (Transit.String "raw plaintext") -> ()
   | Ok _ -> T.fail "raw plaintext changed type"
   | Error message -> T.fail "raw plaintext was rejected: %s" message);
  T.require
    (List.length !calls = calls_before_plaintext)
    "plaintext protected values invoked AES-GCM"
;;

let cases =
  [ T.case "unlock the current upstream key package" unlock_package_case
  ; T.case "encrypt exactly the upstream protected attributes" protected_attribute_case
  ; T.case "preserve the upstream protected value envelope" encrypted_value_case
  ]
;;

let () = T.run "sync E2EE" cases
