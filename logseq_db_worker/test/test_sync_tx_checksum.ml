module T = Logseq_db_worker_test_support.Test_support
module F = Logseq_db_worker_test_support.Structural_fixture
module Tx = Logseq_db_worker.Sync_tx
module Encoder = Logseq_db_worker.Sync_tx_encoder
module Checksum = Logseq_db_worker.Sync_checksum
module Transit = Transit_core.Json
module Codec = Transit_native.Transit.Json

let page_uuid = "11111111-1111-4111-8111-111111111111"
let block_uuid = "22222222-2222-4222-8222-222222222222"
let fixture () = T.read_json (T.fixture "sync/upstream-fab2774-replay.json")

let fixture_string name =
  fixture () |> Yojson.Safe.Util.member name |> Yojson.Safe.Util.to_string
;;

let expect_ok label = function
  | Ok value -> value
  | Error message -> T.fail "%s: %s" label message
;;

let expect_error label = function
  | Error _ -> ()
  | Ok _ -> T.fail "%s unexpectedly succeeded" label
;;

let contains_substring text pattern =
  let rec loop index =
    index + String.length pattern <= String.length text
    && (String.equal (String.sub text index (String.length pattern)) pattern
        || loop (index + 1))
  in
  String.length pattern = 0 || loop 0
;;

let baseline_db () =
  let page = Datascript.Temp_id "page" in
  let block = Datascript.Temp_id "block" in
  Datascript.empty_db ~schema:F.schema ()
  |> Datascript.db_with
       [ Datascript.Add (page, "block/uuid", Uuid page_uuid)
       ; Add (page, "block/name", String "inbox")
       ; Add (page, "block/title", String "Inbox")
       ; Add (block, "block/uuid", Uuid block_uuid)
       ; Add (block, "block/parent", Ref_to page)
       ; Add (block, "block/page", Ref_to page)
       ; Add (block, "block/order", String "a0")
       ; Add (block, "block/title", String "First")
       ]
;;

let entity_by_uuid db uuid =
  match
    Datascript.datoms db Datascript.Avet ~a:"block/uuid" ~v:(Datascript.Uuid uuid) ()
    |> List.of_seq
  with
  | [ datom ] -> datom.Datascript.e
  | _ -> T.fail "unable to resolve fixture entity %s" uuid
;;

let value db entity attr =
  match Datascript.datoms db Datascript.Eavt ~e:entity ~a:attr () |> List.of_seq with
  | [ datom ] -> datom.Datascript.v
  | _ -> T.fail "fixture attribute %s is missing or ambiguous" attr
;;

let strict_transit_decode_case () =
  let db = baseline_db () in
  let title_ops = expect_ok "title tx" (Tx.decode ~db (fixture_string "titleTx")) in
  let after_title = Datascript.db_with title_ops db in
  let block = entity_by_uuid after_title block_uuid in
  T.require
    (value after_title block "block/title" = Datascript.String "First updated")
    "normalized title transaction did not apply";
  let reference_ops =
    expect_ok "reference tx" (Tx.decode ~db:after_title (fixture_string "referenceTx"))
  in
  let after_reference = Datascript.db_with reference_ops after_title in
  let page = entity_by_uuid after_reference page_uuid in
  T.require
    (value after_reference block "block/page" = Datascript.Ref page)
    "lookup-ref value did not decode as a reference";
  let retraction =
    expect_ok "retraction" (Tx.decode ~db:after_title (fixture_string "retractTx"))
  in
  let after_retraction = Datascript.db_with retraction after_title in
  T.require
    (Datascript.datoms after_retraction Datascript.Eavt ~e:block ~a:"block/title" ()
     |> Seq.is_empty)
    "normalized retraction did not apply";
  ignore
    (expect_ok
       "retract entity"
       (Tx.decode ~db:after_title (fixture_string "retractEntityTx")));
  expect_error "unknown operation" (Tx.decode ~db {|[["~:db/future",1]]|});
  expect_error "entity map" (Tx.decode ~db {|[{"~:db/id":"temp"}]|});
  expect_error "trailing field" (Tx.decode ~db {|[["~:db/retractEntity",1,2]]|});
  expect_error "invalid Transit" (Tx.decode ~db "not transit")
;;

let cached_lookup_reference_decode_case () =
  let source =
    {|[["~:db/add","new","~:block/uuid","~u33333333-3333-4333-8333-333333333333"],["^0",["^1","~u33333333-3333-4333-8333-333333333333"],"~:block/title","Cached lookup"]]|}
  in
  match Tx.decode ~db:(baseline_db ()) source with
  | Ok [ Datascript.Add _; Add _ ] -> ()
  | Ok _ -> T.fail "cached lookup transaction decoded to unexpected operations"
  | Error message -> T.fail "cached lookup transaction did not decode: %s" message
;;

let checksum_fixture_case () =
  let db = baseline_db () in
  T.require
    (String.equal (Checksum.recompute ~e2ee:false db) (fixture_string "baselineChecksum"))
    "pinned plaintext checksum fixture changed";
  T.require
    (String.equal
       (Checksum.recompute ~e2ee:true db)
       (fixture_string "e2eeBaselineChecksum"))
    "pinned E2EE checksum fixture changed";
  let after_title =
    Tx.decode ~db (fixture_string "titleTx")
    |> expect_ok "title tx"
    |> fun operations -> Datascript.db_with operations db
  in
  T.require
    (String.equal
       (Checksum.recompute ~e2ee:false after_title)
       (fixture_string "afterTitleChecksum"))
    "title update checksum changed";
  let after_order =
    Tx.decode ~db:after_title (fixture_string "orderTx")
    |> expect_ok "order tx"
    |> fun operations -> Datascript.db_with operations after_title
  in
  T.require
    (String.equal
       (Checksum.recompute ~e2ee:false after_order)
       (fixture_string "afterTitleAndOrderChecksum"))
    "ordered batch checksum changed";
  let unrelated =
    Datascript.db_with
      [ Datascript.Add
          ( Datascript.Lookup_ref ("block/uuid", Uuid block_uuid)
          , "block/updated-at"
          , Int 42 )
      ]
      db
  in
  T.require
    (Checksum.recompute ~e2ee:false unrelated = Checksum.recompute ~e2ee:false db)
    "unrelated attribute changed the entity checksum"
;;

let checksum_excludes_built_in_case () =
  let db = baseline_db () in
  let built_in = Datascript.Temp_id "built-in" in
  let with_built_in =
    Datascript.db_with
      [ Datascript.Add
          (built_in, "block/uuid", Uuid "33333333-3333-4333-8333-333333333333")
      ; Add (built_in, "block/name", String "built-in")
      ; Add (built_in, "block/title", String "Built in")
      ; Add (built_in, "logseq.property/built-in?", Bool true)
      ]
      db
  in
  T.require
    (Checksum.recompute ~e2ee:false with_built_in = Checksum.recompute ~e2ee:false db)
    "built-in entity changed the checksum"
;;

let encrypted_protected_value_case () =
  let db = baseline_db () in
  let encrypted =
    Codec.to_string
      ~mode:Codec.Verbose
      (Transit.Array [ Binary "iv"; Binary "ciphertext" ])
  in
  let source =
    Codec.to_string
      ~mode:Codec.Verbose
      (Transit.Array
         [ Transit.Array
             [ Keyword "db/add"
             ; Array [ Keyword "block/uuid"; Uuid block_uuid ]
             ; Keyword "block/title"
             ; String encrypted
             ]
         ; Transit.Array
             [ Keyword "db/add"
             ; Array [ Keyword "block/uuid"; Uuid block_uuid ]
             ; Keyword "block/order"
             ; String "a1"
             ]
         ])
  in
  let decrypted = ref [] in
  let operations =
    Tx.decode
      ~decrypt_protected:(fun ~attribute ciphertext ->
        decrypted := (attribute, ciphertext) :: !decrypted;
        Ok (Transit.String "Decrypted title"))
      ~db
      source
    |> expect_ok "encrypted protected transaction"
  in
  let after = Datascript.db_with operations db in
  let block = entity_by_uuid after block_uuid in
  T.require
    (value after block "block/title" = Datascript.String "Decrypted title")
    "protected transaction value stayed encrypted";
  T.require
    (value after block "block/order" = Datascript.String "a1")
    "unprotected transaction value changed";
  T.require
    (!decrypted = [ "block/title", encrypted ])
    "decrypt callback did not receive exactly the protected value"
;;

let outgoing_encoder_round_trip_case () =
  let db = baseline_db () in
  let operations =
    [ Datascript.Add
        ( Datascript.Lookup_ref ("block/uuid", Uuid block_uuid)
        , "block/title"
        , String "Outgoing title" )
    ; Datascript.Add
        (Datascript.Lookup_ref ("block/uuid", Uuid block_uuid), "block/order", String "a2")
    ]
  in
  let wire =
    Encoder.encode
      ~encrypt_protected:(fun plaintext ->
        T.require (String.equal plaintext "Outgoing title") "encoder saw wrong plaintext";
        Ok "opaque-ciphertext")
      db
      operations
    |> expect_ok "encode outgoing transaction"
  in
  T.require
    (not (contains_substring wire "Outgoing title"))
    "protected plaintext appeared at the outgoing wire boundary";
  let decoded =
    Tx.decode
      ~decrypt_protected:(fun ~attribute:_ ciphertext ->
        if String.equal ciphertext "opaque-ciphertext"
        then Ok (Transit.String "Outgoing title")
        else Error "unexpected ciphertext")
      ~db
      wire
    |> expect_ok "decode outgoing transaction"
  in
  let expected = Datascript.db_with operations db in
  let actual = Datascript.db_with decoded db in
  T.require
    (Datascript.datoms expected Datascript.Eavt ()
     |> List.of_seq
     = (Datascript.datoms actual Datascript.Eavt () |> List.of_seq))
    "encoded transaction did not round trip"
;;

let cases =
  [ T.case "decode pinned normalized Transit transactions" strict_transit_decode_case
  ; T.case
      "decode cache references in two-element lookup arrays"
      cached_lookup_reference_decode_case
  ; T.case "match pinned plaintext and E2EE checksums" checksum_fixture_case
  ; T.case "exclude built-in entities from checksum" checksum_excludes_built_in_case
  ; T.case
      "decrypt protected normalized transaction values"
      encrypted_protected_value_case
  ; T.case "round trip encrypted outgoing transactions" outgoing_encoder_round_trip_case
  ]
;;

let () = T.run "sync transaction and checksum" cases
