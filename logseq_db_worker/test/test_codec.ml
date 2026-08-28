module T = Logseq_db_worker_test_support.Test_support
module Codec = Logseq_db_storage.Logseq_sqlite_codec

let oracle_root_content () =
  let open Yojson.Safe.Util in
  T.read_json (T.fixture "storage/logseq-65.33-create-page.json")
  |> member "rows"
  |> to_list
  |> List.find (fun row -> row |> member "addr" |> to_int = 0)
  |> member "content"
  |> to_string
;;

let round_trip name value () =
  match Codec.encode_value value with
  | Error _ -> T.fail "%s did not encode" name
  | Ok encoded ->
    (match Codec.decode_value encoded with
     | Error _ -> T.fail "%s did not decode" name
     | Ok decoded ->
       T.require
         (Datascript.Util.value_equal value decoded)
         "%s changed on round trip"
         name)
;;

let round_trip_payload name payload () =
  match Codec.encode_storage_payload payload with
  | Error _ -> T.fail "%s did not encode" name
  | Ok encoded ->
    (match Codec.decode_storage_payload encoded with
     | Error _ -> T.fail "%s did not decode" name
     | Ok _ -> ())
;;

let sample_datom =
  Datascript.
    { e = 42; a = ":block/title"; v = String "sample"; tx = 536870913; added = true }
;;

let sample_schema_attr =
  Datascript.
    { cardinality = Many
    ; unique = Some Identity
    ; indexed = true
    ; is_component = false
    ; no_history = false
    ; doc = Some "sample"
    ; value_type = Some StringType
    ; tuple_attrs = None
    ; tuple_types = None
    }
;;

let cases =
  [ T.case "round trip null" (round_trip "null" Datascript.Nil)
  ; T.case "round trip boolean" (round_trip "boolean" (Bool true))
  ; T.case "round trip integer" (round_trip "integer" (Int 42))
  ; T.case "round trip int64" (round_trip "int64" (Int 4_294_967_296))
  ; T.case "round trip floating point" (round_trip "float" (Float 1.25))
  ; T.case "round trip string" (round_trip "string" (String "你好"))
  ; T.case "round trip keyword" (round_trip "keyword" (Keyword "block/title"))
  ; T.case "round trip symbol" (round_trip "symbol" (Symbol "x"))
  ; T.case
      "round trip UUID"
      (round_trip "UUID" (Uuid "11111111-1111-4111-8111-111111111111"))
  ; T.case "round trip instant" (round_trip "instant" (Instant 1_704_067_200_000))
  ; T.case "round trip regex" (round_trip "regex" (Regex "a.*"))
  ; T.case "round trip list" (round_trip "list" (List [ Int 1; String "x" ]))
  ; T.case "round trip array" (round_trip "array" (Vector [ Bool false; Int 2 ]))
  ; T.case "round trip map" (round_trip "map" (Map [ Keyword "a", Int 1 ]))
  ; T.case "round trip set" (round_trip "set" (Set [ String "a"; String "b" ]))
  ; T.case "round trip tuple" (round_trip "tuple" (Vector [ String "x"; Nil ]))
  ; T.case "round trip reference" (round_trip "reference" (Ref 42))
  ; T.case
      "round trip DataScript datom"
      (round_trip_payload "tail datom" (Storage_tail [ [ sample_datom ] ]))
  ; T.case
      "round trip schema map"
      (round_trip_payload
         "schema"
         (Storage_root
            { storage_schema = [ ":block/title", sample_schema_attr ]
            ; storage_max_eid = 42
            ; storage_max_tx = 536870913
            ; storage_eavt = "10"
            ; storage_aevt = "11"
            ; storage_avet = "12"
            ; storage_duplicate_datoms = []
            ; storage_max_addr = 12
            ; storage_branching_factor = 32
            ; storage_ref_type = Persistent_sorted_set.Strong
            }))
  ; T.case
      "round trip root metadata"
      (round_trip_payload
         "root"
         (Storage_root
            { storage_schema = []
            ; storage_max_eid = 1
            ; storage_max_tx = 2
            ; storage_eavt = "10"
            ; storage_aevt = "11"
            ; storage_avet = "12"
            ; storage_duplicate_datoms = [ sample_datom ]
            ; storage_max_addr = 12
            ; storage_branching_factor = 32
            ; storage_ref_type = Persistent_sorted_set.Weak
            }))
  ; T.case
      "round trip tail groups"
      (round_trip_payload "tail" (Storage_tail [ [ sample_datom ]; [] ]))
  ; T.case
      "round trip persistent sorted-set node"
      (round_trip_payload
         "node"
         (Storage_node (Persistent_sorted_set.Branch ([ sample_datom ], [ "20"; "21" ]))))
  ; T.case "physical node stores child addresses in addresses column" (fun () ->
      let payload =
        Datascript.Storage_node
          (Persistent_sorted_set.Branch ([ sample_datom ], [ "20"; "21" ]))
      in
      match Codec.encode_physical_payload payload with
      | Error _ -> T.fail "physical node did not encode"
      | Ok (content, addresses) ->
        T.require (addresses = [ "20"; "21" ]) "child addresses not split";
        T.require (not (String.equal content "")) "empty node content";
        (match Codec.decode_physical_payload ~content ~addresses with
         | Ok (Datascript.Storage_node (Persistent_sorted_set.Branch (_, restored))) ->
           T.require (restored = addresses) "child addresses not restored"
         | _ -> T.fail "physical branch did not decode"))
  ; T.case "decode official Logseq root index metadata" (fun () ->
      match Codec.decode_root_index_metadata (oracle_root_content ()) with
      | Error (Codec.Unsupported_tag tag) ->
        T.fail "official root metadata has unsupported tag %s" tag
      | Error (Malformed_transit message | Malformed_storage_payload message) ->
        T.fail "official root metadata did not decode: %s" message
      | Error (Out_of_range_number value) ->
        T.fail "official root metadata has out-of-range number %s" value
      | Ok metadata ->
        T.require (metadata.eavt = { count = 2384; shift = 2 }) "wrong EAVT metadata";
        T.require (metadata.aevt = { count = 2384; shift = 2 }) "wrong AEVT metadata";
        T.require (metadata.avet = { count = 2064; shift = 2 }) "wrong AVET metadata")
  ; T.case "decode official Logseq root payload" (fun () ->
      match
        Codec.decode_physical_payload ~content:(oracle_root_content ()) ~addresses:[]
      with
      | Ok (Datascript.Storage_root root) ->
        T.require
          (List.mem_assoc "db/ident" root.storage_schema)
          "official root schema lost db/ident"
      | Error (Codec.Unsupported_tag tag) ->
        T.fail "official root payload has unsupported tag %s" tag
      | Error (Malformed_transit message | Malformed_storage_payload message) ->
        T.fail "official root payload did not decode: %s" message
      | Error (Out_of_range_number value) ->
        T.fail "official root payload has out-of-range number %s" value
      | Ok _ -> T.fail "official root row is not a storage root")
  ; T.case "reject unknown Transit tag" (fun () ->
      match Codec.decode_value "[\"~#unknown\",\"x\"]" with
      | Error (Unsupported_tag "unknown") -> ()
      | _ -> T.fail "unknown tag was not rejected")
  ; T.case "reject out-of-range number" (fun () ->
      match Codec.decode_value "\"~n999999999999999999999999\"" with
      | Error (Out_of_range_number _) -> ()
      | _ -> T.fail "out-of-range integer was not rejected")
  ; T.case "reject malformed address JSON" (fun () ->
      match Codec.decode_storage_payload "{\"~:keys\":[],\"~:children\":[true]}" with
      | Error (Malformed_storage_payload _) -> ()
      | _ -> T.fail "malformed address was not rejected")
  ; T.case "reject malformed root" (fun () ->
      match Codec.decode_storage_payload "{\"~:schema\":{}}" with
      | Error (Malformed_storage_payload _) -> ()
      | _ -> T.fail "malformed root was not rejected")
  ; T.case "reject malformed tail" (fun () ->
      match Codec.decode_storage_payload "[true]" with
      | Error (Malformed_storage_payload _) -> ()
      | _ -> T.fail "malformed tail was not rejected")
  ; T.case "reject lossy value" (fun () ->
      match Codec.decode_value "[\"~#r\",\"https://example.com\"]" with
      | Error (Unsupported_tag "r") -> ()
      | _ -> T.fail "lossy URI coercion was not rejected")
  ]
;;

let () = T.run "codec" cases
