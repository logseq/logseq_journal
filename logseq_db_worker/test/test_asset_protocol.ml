module A = Logseq_db_types.Asset_descriptor
module M = Logseq_db_worker_contract.Worker_pure_mutation
module Read = Worker_pure_read
module Sync = Logseq_sync_pure_reducer.Core
module Id = Journal_worker_ids

let id="78000000-0000-4000-8000-000000000001"
let target=Logseq_db_types.Graph_types.Uuid.of_string id |> Result.get_ok
let origin=Uri.of_string "https://example.invalid"
let command name fields=`List[`String name;`Assoc fields]
let stored_bytes command=Yojson.Safe.to_string(Yojson.Safe.sort(`Assoc[
  "version",`Int 1;"owner",`Assoc["origin",`String(Uri.to_string origin);"user",`String "synthetic";"graph",`String id];
  "request",`Assoc["api_version",`Int 2;"request_id",`String id;"command",command]]))

let owner =
  let module F=Read.For_worker in
  let account:Sync.account_scope={managed_sync_origin=origin;user_id="synthetic";
    account_generation=1;presentation_generation=1;lifecycle_generation=1L}in
  let asset_scope:Sync.graph_scope={account;graph_id=target;graph_generation=1}in
  let scope:Sync.timeline_scope={startup={account_generation=1;presentation_generation=1};
    graph_id=target;graph_generation=1}in
  let limits:Worker_pure_data.capability_limits={response_budget_bytes=Worker_pure_data.maximum_response_bytes;
    outbox_max_records=100;outbox_max_bytes=1048576;change_max_items=256;change_max_bytes=1048576;
    dispatcher_capacity=100;wire_batch_max_bytes=1048576}in
  let binding=F.binding ~serial:1L ~incarnation:(Read.worker_incarnation
    ~runtime_epoch:(Id.Runtime.Epoch.of_int64 1L) ~worker_generation:Id.Worker.Generation.one)
    ~origin:(Uri.to_string origin) ~user:"synthetic"in
  F.session ~binding ~graph:target ~account:1 ~lifecycle:1L ~generation:1 ~scope ~asset_scope ~limits
;;

let roundtrip () =
  let check :type a. int -> a Read.query -> unit=fun maximum_items query->
    let budget=Read.read_budget owner ~maximum_items ~maximum_bytes:4096 |> Result.get_ok in
    Alcotest.(check bool) "original typed query admitted"true(Result.is_ok(Read.validate_query owner budget query))in
  check 1(Read.Assets{recursive=false;roots=[target];after=None});
  check 1(Read.Asset_descriptors[target]);
  check 5(Read.Assets{recursive=true;roots=[target];after=None})
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
       let json = stored_bytes (reference_command previous) in
       match M.restore ~origin ~user:"synthetic" ~graph:target json with
       | Error _ -> Alcotest.fail "asset reference command rejected"
       | Ok decoded ->
         Alcotest.(check string) "reference stored bytes roundtrip" json(M.encode decoded))
    [ `Null; `String id ];
  List.iter
    (fun previous ->
       Alcotest.(check bool)
         "malformed previous reference rejected"
         true
         (Result.is_error (M.restore ~origin ~user:"synthetic" ~graph:target (stored_bytes (reference_command previous)))))
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
  let json=item in
  match A.of_yojson json with
  | Error e -> Alcotest.fail e
  | Ok value ->
    Alcotest.(check bool)
      "descriptor roundtrip"
      true
      (Yojson.Safe.equal
         (Yojson.Safe.sort json)
         (Yojson.Safe.sort (A.to_yojson value)))
;;

let limits () =
  let budget=Read.read_budget owner ~maximum_items:1 ~maximum_bytes:4096 |> Result.get_ok in
  let reject :type a. a Read.query->unit=fun query->
    Alcotest.(check bool) "bounded asset query"true(Result.is_error(Read.validate_query owner budget query))in
  reject(Read.Asset_descriptors(List.init 201(fun _->target)));
  reject(Read.Assets{recursive=true;roots=List.init 65(fun _->target);after=None});
  Alcotest.(check bool) "invalid budget cannot be constructed"true
    (Result.is_error(Read.read_budget owner ~maximum_items:0 ~maximum_bytes:4096))
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
  let check_roundtrip item =
    let json = item in
    match A.of_yojson json with
    | Error message -> Alcotest.failf "descriptor rejected: %s" message
    | Ok response ->
      Alcotest.(check bool)
        "descriptor variant roundtrip"
        true
        (Yojson.Safe.equal
           (Yojson.Safe.sort (Yojson.Safe.from_string (Yojson.Safe.to_string json)))
           (Yojson.Safe.sort
              (Yojson.Safe.from_string
                 (Yojson.Safe.to_string (A.to_yojson response)))))
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
      (Result.is_error (A.of_yojson item))
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
