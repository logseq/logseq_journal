module P = Logseq_db_worker.Protocol

let id = "78000000-0000-4000-8000-000000000001"

let request command =
  `Assoc [ "apiVersion", `Int P.api_version; "requestId", `String id; "command", command ]
;;

let command name fields = `Assoc (("type", `String name) :: fields)

let roundtrip () =
  List.iter
    (fun cmd ->
       let json = request cmd in
       match P.request_of_yojson json with
       | Error _ -> Alcotest.fail "asset query command rejected"
       | Ok value ->
         Alcotest.(check bool)
           "query roundtrip"
           true
           (Yojson.Safe.equal
              (Yojson.Safe.sort json)
              (Yojson.Safe.sort (P.request_to_yojson value))))
    [ command
        "listAssets"
        [ "recursive", `Bool false
        ; "roots", `List [ `String id ]
        ; "limit", `Int 1
        ; "cursor", `Null
        ]
    ; command "getAssetDescriptors" [ "assets", `List [ `String id ] ]
    ; command
        "listAssets"
        [ "recursive", `Bool true
        ; "roots", `List [ `String id ]
        ; "limit", `Int 5
        ; "cursor", `Null
        ]
    ]
;;

let reference_command previous =
  command
    "setAssetReference"
    [ "mutationId", `String id
    ; "block", `String id
    ; "previous", previous
    ; "asset", `String id
    ; ( "preconditions"
      , `Assoc
          [ ( "blocks"
            , `List
                [ `Assoc [ "uuid", `String id; "revision", `String "block-revision" ] ] )
          ; "pages", `List []
          ; "scopes", `List []
          ] )
    ]
;;

let references () =
  List.iter
    (fun previous ->
       let json = request (reference_command previous) in
       match P.request_of_yojson json with
       | Error _ -> Alcotest.fail "asset reference command rejected"
       | Ok decoded ->
         Alcotest.(check bool)
           "reference command roundtrip"
           true
           (Yojson.Safe.equal
              (Yojson.Safe.sort json)
              (Yojson.Safe.sort (P.request_to_yojson decoded))))
    [ `Null; `String id ];
  List.iter
    (fun previous ->
       Alcotest.(check bool)
         "malformed previous reference rejected"
         true
         (Result.is_error (P.request_of_yojson (request (reference_command previous)))))
    [ `String "not-a-uuid"; `Int 1; `Bool false ]
;;

let response () =
  let source =
    `Assoc
      [ "kind", `String "managed"
      ; ( "remote"
        , `Assoc [ "checksum", `String (String.make 64 'a'); "type", `String "png" ] )
      ]
  in
  let item =
    `Assoc
      [ "uuid", `String id
      ; "source", source
      ; "currentChecksum", `String (String.make 64 'b')
      ; "size", `String "128"
      ; "dimensions", `Assoc [ "width", `Int 10; "height", `Int 20 ]
      ]
  in
  let json =
    `Assoc
      [ "apiVersion", `Int P.api_version
      ; "requestId", `String id
      ; ( "outcome"
        , command
            "assets"
            [ "generation", `String "generation"
            ; "projectionRevision", `String "projection"
            ; "items", `List [ item ]
            ; "nextCursor", `Null
            ] )
      ]
  in
  match P.response_of_yojson json with
  | Error e -> Alcotest.fail e
  | Ok value ->
    Alcotest.(check bool)
      "descriptor roundtrip"
      true
      (Yojson.Safe.equal
         (Yojson.Safe.sort json)
         (Yojson.Safe.sort (P.response_to_yojson value)))
;;

let limits () =
  List.iter
    (fun cmd ->
       Alcotest.(check bool)
         "bounded asset command"
         true
         (Result.is_error (P.request_of_yojson (request cmd))))
    [ command
        "getAssetDescriptors"
        [ "assets", `List (List.init 201 (fun _ -> `String id)) ]
    ; command
        "listAssets"
        [ "recursive", `Bool true
        ; "roots", `List (List.init 65 (fun _ -> `String id))
        ; "limit", `Int 1
        ; "cursor", `Null
        ]
    ; command
        "listAssets"
        [ "recursive", `Bool true; "roots", `List []; "limit", `Int 0; "cursor", `Null ]
    ]
;;

let () =
  Alcotest.run
    "asset protocol"
    [ ( "wire boundary"
      , [ Alcotest.test_case "references" `Quick references
        ; Alcotest.test_case "queries" `Quick roundtrip
        ; Alcotest.test_case "descriptors" `Quick response
        ; Alcotest.test_case "bounds" `Quick limits
        ] )
    ]
;;
