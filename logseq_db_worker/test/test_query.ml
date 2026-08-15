module T = Logseq_db_worker_test_support.Test_support
module Query = Logseq_db_worker__Query

let key = Bytes.of_string "0123456789abcdef0123456789abcdef"

let payload =
  Query.
    { api_version = Logseq_db_worker.Protocol.api_version
    ; fingerprint = "query-fingerprint"
    ; basis = 42L
    ; last_sort_key = "a0"
    ; expires_at_ms = 2_000L
    }
;;

let encoded () =
  match Query.encode_cursor ~key payload with
  | Ok cursor -> cursor
  | Error _ -> T.fail "cursor encoding failed"
;;

let () =
  T.run
    "query"
    [ T.case "positive limit is required" (fun () ->
        match Query.validate_limit 0 with
        | Error Query.Invalid_limit -> ()
        | _ -> T.fail "zero limit accepted")
    ; T.case "maximum page size is enforced" (fun () ->
        (match Query.validate_limit Logseq_db_worker.Protocol.maximum_page_size with
         | Ok () -> ()
         | _ -> T.fail "maximum limit rejected");
        match Query.validate_limit (Logseq_db_worker.Protocol.maximum_page_size + 1) with
        | Error Query.Invalid_limit -> ()
        | _ -> T.fail "oversized limit accepted")
    ; T.case "query fingerprint is canonical" (fun () ->
        let left = Query.fingerprint (`Assoc [ "b", `Int 2; "a", `Int 1 ]) in
        let right = Query.fingerprint (`Assoc [ "a", `Int 1; "b", `Int 2 ]) in
        T.require (String.equal left right) "object order changed fingerprint")
    ; T.case "cursor encoding is canonical and authenticated" (fun () ->
        let first = encoded () in
        let second = encoded () in
        T.require
          (String.equal
             (Logseq_db_worker.Graph_types.Cursor.to_string first)
             (Logseq_db_worker.Graph_types.Cursor.to_string second))
          "cursor encoding is unstable";
        T.require
          (String.equal
             (Logseq_db_worker.Graph_types.Cursor.to_string first)
             "eyJhcGlWZXJzaW9uIjoxLCJiYXNpcyI6NDIsImV4cGlyZXNBdE1zIjoyMDAwLCJmaW5nZXJwcmludCI6InF1ZXJ5LWZpbmdlcnByaW50IiwibGFzdFNvcnRLZXkiOiJhMCJ9_HZUhML3CD8Oh5NOs8w8kmDFZKE2xr3BsricGGcNUls")
          "cursor does not match the frozen base64url envelope";
        match Query.decode_cursor ~key ~now_ms:1_000L first with
        | Ok decoded -> T.require (decoded = payload) "cursor payload changed"
        | Error _ -> T.fail "cursor decode failed")
    ; T.case "cursor expiry is enforced" (fun () ->
        match Query.decode_cursor ~key ~now_ms:2_001L (encoded ()) with
        | Error Query.Cursor_expired -> ()
        | _ -> T.fail "expired cursor accepted")
    ; T.case "cursor tampering is rejected" (fun () ->
        let value = Logseq_db_worker.Graph_types.Cursor.to_string (encoded ()) in
        let replacement = if Char.equal value.[0] '0' then '1' else '0' in
        let tampered =
          String.init (String.length value) (fun index ->
            if index = 0 then replacement else value.[index])
        in
        let cursor =
          match Logseq_db_worker.Graph_types.Cursor.of_string tampered with
          | Ok cursor -> cursor
          | Error message -> T.fail "%s" message
        in
        match Query.decode_cursor ~key ~now_ms:1_000L cursor with
        | Error Query.Cursor_tampered -> ()
        | _ -> T.fail "tampered cursor accepted")
    ; T.case "cursor key rotation is versioned" (fun () ->
        let other_key = Bytes.of_string "abcdef0123456789abcdef0123456789" in
        match Query.decode_cursor ~key:other_key ~now_ms:1_000L (encoded ()) with
        | Error Query.Cursor_tampered -> ()
        | _ -> T.fail "cursor decoded under another key")
    ]
;;
