module T = Logseq_db_worker_test_support.Test_support
module Key = Logseq_db_worker.Sync_graph_key

let crypto =
  { Logseq_db_worker.Sync_e2ee.unavailable_crypto with
    encrypt_aes_gcm =
      (fun ~key ~plaintext ->
        T.require (String.length key = 32) "graph key changed at the crypto boundary";
        Ok ("iv", plaintext))
  ; decrypt_aes_gcm =
      (fun ~key ~iv:_ ~ciphertext ->
        T.require (String.length key = 32) "graph key changed at the crypto boundary";
        Ok ciphertext)
  }
;;

let () =
  T.require (Result.is_error (Key.of_string "short")) "short graph key was accepted";
  let key = Key.of_string (String.make 32 'k') |> Result.get_ok in
  let encrypted =
    Key.encrypt_value ~crypto key (Transit_core.Json.String "secret") |> Result.get_ok
  in
  T.require
    (Key.decrypt_value ~crypto key encrypted = Ok (Transit_core.Json.String "secret"))
    "abstract graph key did not round-trip through crypto";
  Key.clear key;
  T.require
    (Result.is_error (Key.decrypt_value ~crypto key encrypted))
    "cleared graph key remained usable"
;;
