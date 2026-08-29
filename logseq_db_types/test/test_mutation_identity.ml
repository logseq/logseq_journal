open Logseq_db_types
open Mutation

let fail format = Printf.ksprintf failwith format

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let uuid value =
  match Graph_types.Uuid.of_string value with
  | Ok value -> value
  | Error message -> fail "%s" message
;;

let check_identity name mutation expected_payload expected_fingerprint =
  let identity = identify mutation in
  let payload = identity_payload identity in
  let fingerprint = identity_fingerprint identity in
  require (String.equal payload expected_payload) "%s payload changed" name;
  require
    (String.equal fingerprint expected_fingerprint)
    "%s fingerprint changed: %s"
    name
    fingerprint;
  require (String.length fingerprint = 64) "%s fingerprint is not 64 bytes" name;
  require
    (String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       fingerprint)
    "%s fingerprint is not lowercase hexadecimal"
    name
;;

let capture_insert () =
  let mutation =
    Structural
      (Insert_blocks
         { roots =
             [ { uuid = uuid "10000000-0000-4000-8000-000000000001"
               ; title = "Captured source"
               ; children = []
               }
             ]
         ; position = Relative (Last_child (uuid "10000000-0000-4000-8000-000000000002"))
         ; context =
             { mutation_id = uuid "10000000-0000-4000-8000-000000000003"
             ; expected_basis = 42L
             }
         })
  in
  check_identity
    "Capture Insert_blocks"
    mutation
    {|{"type":"insertBlocks","roots":[{"uuid":"10000000-0000-4000-8000-000000000001","title":"Captured source","children":[]}],"position":{"type":"lastChild","block":"10000000-0000-4000-8000-000000000002"},"context":{"mutationId":"10000000-0000-4000-8000-000000000003","expectedBasis":"42"}}|}
    "74c6d7a5c571eaf060a44197fddeec5b4ad55dd25325461c079861a53186edc6"
;;

let page_creation () =
  let mutation =
    Page
      (Create_page
         { title = "Daily Notes"
         ; kind =
             Create_journal_page
               { journal_day = 20260829
               ; supplied_uuid = Some (uuid "20000000-0000-4000-8000-000000000001")
               }
         ; context =
             { mutation_id = uuid "20000000-0000-4000-8000-000000000002"
             ; expected_basis = 7L
             }
         })
  in
  check_identity
    "page creation"
    mutation
    {|{"type":"createPage","title":"Daily Notes","kind":{"type":"journal","journalDay":20260829,"suppliedUuid":"20000000-0000-4000-8000-000000000001"},"context":{"mutationId":"20000000-0000-4000-8000-000000000002","expectedBasis":"7"}}|}
    "3af4769d68a8d9068b8f38f83bb29e6fc484cee75fdc399d3aaf1a2960e1e32b"
;;

let property_mutation () =
  let mutation =
    Property
      (Set_property
         { block = uuid "30000000-0000-4000-8000-000000000001"
         ; property = Graph_types.Property_by_ident "logseq.property/status"
         ; value = Graph_types.Default_value "logseq.property/status.todo"
         ; context =
             { mutation_id = uuid "30000000-0000-4000-8000-000000000002"
             ; expected_basis = 9L
             }
         })
  in
  check_identity
    "property mutation"
    mutation
    {|{"type":"setProperty","block":"30000000-0000-4000-8000-000000000001","property":{"type":"ident","ident":"logseq.property/status"},"value":{"type":"default","value":"logseq.property/status.todo"},"context":{"mutationId":"30000000-0000-4000-8000-000000000002","expectedBasis":"9"}}|}
    "2b9248fe9919e77dd9c493760b7cc7da79d7563ca37f9adad3ad5dd50359bec5"
;;

let reused_mutation_id_content_change () =
  let make title =
    Structural
      (Save_block
         { block = uuid "40000000-0000-4000-8000-000000000001"
         ; title
         ; context =
             { mutation_id = uuid "40000000-0000-4000-8000-000000000002"
             ; expected_basis = 11L
             }
         })
  in
  let original = identify (make "Original content") in
  let changed = identify (make "Changed content") in
  require
    (String.equal
       (identity_fingerprint original)
       "b63f6c308496ecde6728b3e2855d52e950696c447c41d7493b6cac7fed815834")
    "original content fingerprint changed";
  require
    (String.equal
       (identity_fingerprint changed)
       "5736a05ea9c8c23b7c9936ff45a2f5c0e6e1c1c88aed056002978eaa372249b4")
    "changed content fingerprint changed";
  require
    (not (String.equal (identity_fingerprint original) (identity_fingerprint changed)))
    "content change under a reused mutation ID kept the same fingerprint"
;;

let large_payload_has_bounded_fingerprint () =
  let mutation =
    Structural
      (Save_block
         { block = uuid "50000000-0000-4000-8000-000000000001"
         ; title = String.make Limits.maximum_request_bytes 'x'
         ; context =
             { mutation_id = uuid "50000000-0000-4000-8000-000000000002"
             ; expected_basis = 13L
             }
         })
  in
  let identity = identify mutation in
  require
    (String.length (identity_payload identity) > Limits.maximum_request_bytes)
    "large test mutation did not exercise payload-size independence";
  require
    (String.length (identity_fingerprint identity) = 64)
    "large mutation fingerprint grew with its payload"
;;

let () =
  capture_insert ();
  page_creation ();
  property_mutation ();
  reused_mutation_id_content_change ();
  large_payload_has_bounded_fingerprint ()
;;
