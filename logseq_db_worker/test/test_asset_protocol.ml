module P = Logseq_db_worker.Protocol

let id = "78000000-0000-4000-8000-000000000001"

let request command =
  `Assoc
    [ "api_version", `Int P.api_version; "request_id", `String id; "command", command ]
;;

let command name fields = `List [ `String name; `Assoc fields ]

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
        "V2_list_assets"
        [ "recursive", `Bool false
        ; "roots", `List [ `String id ]
        ; "limit", `Int 1
        ; "cursor", `Null
        ]
    ; command "V2_get_asset_descriptors" [ "assets", `List [ `String id ] ]
    ; command
        "V2_list_assets"
        [ "recursive", `Bool true
        ; "roots", `List [ `String id ]
        ; "limit", `Int 5
        ; "cursor", `Null
        ]
    ]
;;

let reference_command previous =
  command
    "V2_set_asset_reference"
    [ "mutation_id", `String id
    ; "block", `String id
    ; "previous", previous
    ; "asset", `String id
    ; ( "preconditions"
      , `Assoc
          [ "blocks", `List [ `List [ `String id; `String "block-revision" ] ]
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
    `List
      [ `String "Managed"
      ; `Assoc [ "checksum", `String (String.make 64 'a'); "file_type", `String "png" ]
      ]
  in
  let item =
    `Assoc
      [ "uuid", `String id
      ; "source", source
      ; "current_checksum", `String (String.make 64 'b')
      ; "size", `Intlit "128"
      ; "dimensions", `List [ `Int 10; `Int 20 ]
      ]
  in
  let json =
    `List
      [ `String "V2_response"
      ; `Assoc
          [ "api_version", `Int P.api_version
          ; "request_id", `String id
          ; ( "outcome"
            , command
                "V2_assets_outcome"
                [ "generation", `String "generation"
                ; "projection_revision", `String "projection"
                ; "items", `List [ item ]
                ; "next_cursor", `Null
                ] )
          ]
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
        "V2_get_asset_descriptors"
        [ "assets", `List (List.init 201 (fun _ -> `String id)) ]
    ; command
        "V2_list_assets"
        [ "recursive", `Bool true
        ; "roots", `List (List.init 65 (fun _ -> `String id))
        ; "limit", `Int 1
        ; "cursor", `Null
        ]
    ; command
        "V2_list_assets"
        [ "recursive", `Bool true; "roots", `List []; "limit", `Int 0; "cursor", `Null ]
    ]
;;

let descriptor_validation () =
  let variant name value = `List [ `String name; value ] in
  let descriptor source checksum size dimensions =
    `Assoc
      [ "uuid", `String id
      ; "source", source
      ; "current_checksum", checksum
      ; "size", size
      ; "dimensions", dimensions
      ]
  in
  let managed =
    variant
      "Managed"
      (`Assoc [ "checksum", `String (String.make 64 'a'); "file_type", `String "png" ])
  in
  let envelope item =
    variant
      "V2_response"
      (`Assoc
          [ "api_version", `Int 2
          ; "request_id", `String id
          ; ( "outcome"
            , command
                "V2_assets_outcome"
                [ "generation", `String "g"
                ; "projection_revision", `String "p"
                ; "items", `List [ item ]
                ; "next_cursor", `Null
                ] )
          ])
  in
  let check_roundtrip item =
    let json = envelope item in
    match P.response_of_yojson json with
    | Error message -> Alcotest.failf "descriptor rejected: %s" message
    | Ok response ->
      Alcotest.(check bool)
        "descriptor variant roundtrip"
        true
        (Yojson.Safe.equal
           (Yojson.Safe.sort (Yojson.Safe.from_string (Yojson.Safe.to_string json)))
           (Yojson.Safe.sort
              (Yojson.Safe.from_string
                 (Yojson.Safe.to_string (P.response_to_yojson response)))))
  in
  List.iter
    check_roundtrip
    [ descriptor
        managed
        (`String (String.make 64 'b'))
        (`Intlit "9223372036854775807")
        (`List [ `Int 10; `Int 20 ])
    ; descriptor (variant "Managed" `Null) `Null `Null `Null
    ; descriptor
        (variant "External" (`String "https://example.org/image.png"))
        `Null
        `Null
        `Null
    ];
  let reject item =
    Alcotest.(check bool)
      "invalid descriptor rejected"
      true
      (Result.is_error (P.response_of_yojson (envelope item)))
  in
  List.iter
    reject
    [ descriptor managed (`String "invalid") `Null `Null
    ; descriptor managed `Null (`Intlit "-1") `Null
    ; descriptor managed `Null (`Intlit "9223372036854775808") `Null
    ; descriptor managed `Null `Null (`List [ `Int 0; `Int 1 ])
    ; descriptor managed `Null `Null (`List [ `Int 1; `Int (-1) ])
    ; descriptor
        (variant
           "Managed"
           (`Assoc [ "checksum", `String "invalid"; "file_type", `String "png" ]))
        `Null
        `Null
        `Null
    ; descriptor
        (variant
           "Managed"
           (`Assoc
               [ "checksum", `String (String.make 64 'a')
               ; "file_type", `String "png/unsafe"
               ]))
        `Null
        `Null
        `Null
    ]
;;

let () =
  Alcotest.run
    "asset protocol"
    [ ( "wire boundary"
      , [ Alcotest.test_case "descriptor validation" `Quick descriptor_validation
        ; Alcotest.test_case "references" `Quick references
        ; Alcotest.test_case "queries" `Quick roundtrip
        ; Alcotest.test_case "descriptors" `Quick response
        ; Alcotest.test_case "bounds" `Quick limits
        ] )
    ]
;;
