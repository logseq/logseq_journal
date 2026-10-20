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

(* HTTP bytes are opaque to the pure reducer. The public codec is the narrowest
   owner that can reproduce content classification and validation. *)
let capture_stderr f =
  let saved = Unix.dup Unix.stderr in
  let input, output = Unix.pipe () in
  Unix.dup2 output Unix.stderr;
  Unix.close output;
  let outcome =
    try
      Ok
        (Fun.protect
           ~finally:(fun () ->
             flush stderr;
             Unix.dup2 saved Unix.stderr;
             Unix.close saved)
           f)
    with
    | exn -> Error exn
  in
  let channel = Unix.in_channel_of_descr input in
  let log =
    Fun.protect
      ~finally:(fun () -> close_in channel)
      (fun () -> In_channel.input_all channel)
  in
  match outcome with
  | Ok result -> result, log
  | Error exn -> raise exn
;;

let non_transit_raw_assets () =
  let calls = ref 0 in
  let guarded =
    { crypto with
      decrypt =
        (fun ~key:_ ~iv:_ ~ciphertext:_ ->
          incr calls;
          Error "PRIVATE_UNEXPECTED_DECRYPT")
    }
  in
  List.iter
    (fun wire ->
       let result, log =
         capture_stderr (fun () ->
           C.decode
             ~maximum_plaintext_bytes:256
             ~crypto:guarded
             ~key:(Some "PRIVATE_KEY")
             ~expected_checksum:(C.checksum wire)
             wire)
       in
       Alcotest.(check string) "raw bytes preserved" wire (get result);
       Alcotest.(check string)
         "fixed path evidence contains no content/key/hash"
         "journal asset decode path=raw-fallback\n"
         log)
    [ bytes
    ; "\137PNG\r\n\026\nPRIVATE_IMAGE"
    ; "\255\000PRIVATE_BINARY"
    ; "not transit PRIVATE_TEXT"
    ; "hello PRIVATE_TEXT"
    ; "- PRIVATE_MARKDOWN"
    ; "\239\187\191PRIVATE_TEXT"
    ; " \nPRIVATE_TEXT"
    ; ""
    ; " \n\t"
    ];
  Alcotest.(check int) "raw never decrypts" 0 !calls;
  Alcotest.(check string) "existing plain graph path" bytes (get (decode ~key:None bytes))
;;

let raw_assets_keep_validation () =
  let check ~maximum ~expected wire error =
    let result, _ =
      capture_stderr (fun () ->
        C.decode
          ~maximum_plaintext_bytes:maximum
          ~crypto
          ~key:(Some "key")
          ~expected_checksum:expected
          wire)
    in
    Alcotest.(check (result string string))
      "common validation is retained"
      (Error error)
      result
  in
  check ~maximum:32 ~expected:(String.make 64 'a') bytes "Asset checksum mismatch";
  check ~maximum:2 ~expected:(C.checksum bytes) bytes "Asset exceeds plaintext size limit";
  check ~maximum:0 ~expected:(C.checksum "x") "x" "Asset exceeds plaintext size limit";
  check ~maximum:(-1) ~expected:(C.checksum bytes) bytes "Invalid plaintext size limit";
  let oversized = String.make 1000 'X' in
  check
    ~maximum:0
    ~expected:(C.checksum oversized)
    oversized
    "Asset exceeds wire size limit";
  let result, _ =
    capture_stderr (fun () ->
      decode ~limit:(String.length bytes) ~checksum:(C.checksum bytes) bytes)
  in
  Alcotest.(check string) "raw size boundary succeeds" bytes (get result)
;;

let transit_failures_never_become_raw () =
  let calls = ref 0 in
  let guarded =
    { crypto with
      decrypt =
        (fun ~key:_ ~iv:_ ~ciphertext:_ ->
          incr calls;
          Error "authentication failed")
    }
  in
  let reject ?(decrypts = false) ?(crypt = guarded) wire =
    let before = !calls in
    let result, log =
      capture_stderr (fun () ->
        C.decode
          ~maximum_plaintext_bytes:1048576
          ~crypto:crypt
          ~key:(Some "wrong")
          ~expected_checksum:(C.checksum wire)
          wire)
    in
    rejects result;
    Alcotest.(check string) "no raw fallback even when raw checksum matches" "" log;
    if not decrypts
    then Alcotest.(check int) "malformed candidates never decrypt" before !calls
  in
  List.iter
    reject
    [ "["
    ; "[\"~b"
    ; "[\"~bAA==\","
    ; "[\"~bAA==\",\"~bAA==\"]"
    ; "[\"~b!\",\"~b!\"]"
    ; "[\"a\",\"b\"]"
    ; "[]"
    ; "[1,2,3]"
    ; "{\"PRIVATE\":1}"
    ; "\"PRIVATE\""
    ; "null"
    ; "true"
    ; "123"
    ; "tru"
    ; "nul"
    ; "-"
    ; "1e"
    ; "[\"\\q\",0]"
    ; envelope ^ "null"
    ; "\239\187\191" ^ envelope
    ; " \n\239\187\191" ^ envelope
    ; "\239\187\191\239\187\191" ^ envelope
    ; String.sub envelope 0 (String.length envelope - 1)
    ; T.to_string (Transit_core.Json.Array [ Binary "short"; Binary ciphertext ])
    ; T.to_string (Transit_core.Json.Array [ Binary iv; Binary "short" ])
    ; String.make 100000 '[' ^ "0" ^ String.make 100000 ']'
    ];
  reject ~decrypts:true envelope;
  Alcotest.(check int) "valid envelope reaches auth exactly once" 1 !calls;
  reject
    ~crypt:{ crypto with decrypt = (fun ~key:_ ~iv:_ ~ciphertext:_ -> Ok "wrong") }
    envelope;
  let raised =
    try
      reject
        ~crypt:
          { crypto with
            decrypt =
              (fun ~key:_ ~iv:_ ~ciphertext:_ -> failwith "PRIVATE_AUTH_EXCEPTION")
          }
        envelope;
      false
    with
    | Failure message -> message = "PRIVATE_AUTH_EXCEPTION"
  in
  Alcotest.(check bool) "crypto exception is not a plaintext signal" true raised;
  Alcotest.(check string)
    "valid encrypted success remains unchanged"
    bytes
    (get (decode envelope))
;;

let () =
  Alcotest.run
    "asset codec"
    [ ( "binary protocol"
      , [ Alcotest.test_case
            "non-Transit assets in encrypted graphs"
            `Quick
            non_transit_raw_assets
        ; Alcotest.test_case
            "raw assets preserve validation"
            `Quick
            raw_assets_keep_validation
        ; Alcotest.test_case
            "Transit and crypto failures never fall back"
            `Quick
            transit_failures_never_become_raw
        ; Alcotest.test_case "raw binary envelope" `Quick raw_bytes
        ; Alcotest.test_case "plaintext" `Quick plaintext
        ; Alcotest.test_case "invalid and oversized" `Quick validation
        ; Alcotest.test_case "bounded envelope shape" `Quick bounded_envelope_shape
        ] )
    ]
;;
