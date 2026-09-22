module C = Logseq_sync_effect_runner.Asset_codec
module T = Transit_native.Transit.Json

let get = function
  | Ok x -> x
  | Error e -> failwith e
;;

let bytes = "\000PNG\255\128binary\000"
let iv = String.make 12 '\001'
let ciphertext = String.make 16 '\002' ^ bytes

let crypto : C.crypto =
  { encrypt =
      (fun ~key:_ ~plaintext ->
        if plaintext = bytes then Ok (iv, ciphertext) else Error "not raw bytes")
  ; decrypt =
      (fun ~key ~iv:actual_iv ~ciphertext:actual ->
        if key = "key" && actual_iv = iv && actual = ciphertext
        then Ok bytes
        else Error "authentication failed")
  }
;;

let envelope = T.to_string (Transit_core.Json.Array [ Binary iv; Binary ciphertext ])

let decode ?(key = Some "key") ?(limit = 32) ?(checksum = C.checksum bytes) wire =
  C.decode ~maximum_plaintext_bytes:limit ~crypto ~key ~expected_checksum:checksum wire
;;

let rejects result = Alcotest.(check bool) "rejected" true (Result.is_error result)

let raw_bytes () =
  Alcotest.(check string) "raw bytes after decrypt" bytes (get (decode envelope));
  Alcotest.(check string)
    "upstream envelope"
    envelope
    (get (C.encode ~maximum_plaintext_bytes:32 ~crypto ~key:(Some "key") bytes))
;;

let plaintext () =
  Alcotest.(check string) "unencrypted asset" bytes (get (decode ~key:None bytes))
;;

let validation () =
  rejects (decode ~checksum:(String.make 64 'a') envelope);
  rejects (decode ~key:(Some "wrong") envelope);
  rejects (decode "not transit");
  rejects
    (decode (T.to_string (Transit_core.Json.Array [ Binary "short"; Binary ciphertext ])));
  rejects (decode (T.to_string (Transit_core.Json.Array [ Binary iv; Binary "short" ])));
  rejects (decode ~limit:2 envelope);
  rejects (decode ~key:None ~limit:2 bytes);
  rejects (C.encode ~maximum_plaintext_bytes:2 ~crypto ~key:(Some "key") bytes)
;;

let bounded_envelope_shape () =
  let calls = ref 0 in
  let guarded =
    { crypto with
      decrypt =
        (fun ~key:_ ~iv:_ ~ciphertext:_ ->
          incr calls;
          Error "unexpected decryption")
    }
  in
  let reject wire =
    let before = Gc.allocated_bytes () in
    let result =
      try
        C.decode
          ~maximum_plaintext_bytes:1048576
          ~crypto:guarded
          ~key:(Some "key")
          ~expected_checksum:(C.checksum bytes)
          wire
      with
      | Stack_overflow -> Alcotest.fail "untrusted envelope exhausted the stack"
    in
    let allocated = Gc.allocated_bytes () -. before in
    rejects result;
    Alcotest.(check bool)
      "reject shape without a general Transit tree"
      true
      (allocated < 1048576.)
  in
  reject (String.make 100000 '[' ^ "0" ^ String.make 100000 ']');
  reject ("[" ^ String.concat "," (List.init 100000 (fun _ -> "0")) ^ "]");
  reject ("{\"value\":" ^ envelope ^ "}");
  reject (envelope ^ "null");
  reject "[1,2,3]";
  reject "[\"unterminated";
  Alcotest.(check int) "invalid structure never reaches crypto" 0 !calls;
  Alcotest.(check string)
    "JSON escapes remain accepted"
    bytes
    (get (decode (String.concat "\\u007e" (String.split_on_char '~' envelope))));
  Alcotest.(check string)
    "JSON whitespace remains accepted"
    bytes
    (get (decode (" \n" ^ envelope ^ "\t ")))
;;

let () =
  Alcotest.run
    "asset codec"
    [ ( "binary protocol"
      , [ Alcotest.test_case "raw binary envelope" `Quick raw_bytes
        ; Alcotest.test_case "plaintext" `Quick plaintext
        ; Alcotest.test_case "invalid and oversized" `Quick validation
        ; Alcotest.test_case "bounded envelope shape" `Quick bounded_envelope_shape
        ] )
    ]
;;
