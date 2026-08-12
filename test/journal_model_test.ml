let fail format = Printf.ksprintf failwith format

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let require_ok = function
  | Ok value -> value
  | Error error -> fail "unexpected Journal entry rejection: %s" error
;;

let require_error = function
  | Error _ -> ()
  | Ok _ -> fail "invalid Journal entry was accepted"
;;

let id = "10000000-0000-4000-a000-000000000001"
let page_id = "10000000-0000-4000-b000-000000000001"
let parent_id = "10000000-0000-4000-a000-000000000002"
let mutation_id = "10000000-0000-4000-9000-000000000001"

let creation_time =
  Journal_time.create
    ~instant_unix_ms:1_786_204_800_000L
    ~local_day:20260809
    ~local_minute_of_day:0
    ~time_zone_id:"Asia/Shanghai"
    ~utc_offset_seconds:28_800
  |> require_ok
;;

let create
      ?(entry_id = id)
      ?(entry_page_id = page_id)
      ?(journal_day = 20260809)
      ?(entry_parent_id = Some parent_id)
      ?(sibling_order = "000000000001")
      ?(source = "Literal #journal @person 👩🏽‍💻")
      ?(task_state = Journal_model.Todo)
      ?(child_count = 3)
      ?(entry_creation_time = creation_time)
      ?(revision = 7)
      ?(last_mutation_id = mutation_id)
      ()
  =
  Journal_model.create
    ~id:entry_id
    ~page_id:entry_page_id
    ~journal_day
    ~parent_id:entry_parent_id
    ~sibling_order
    ~source
    ~task_state
    ~child_count
    ~creation_time:entry_creation_time
    ~revision
    ~last_mutation_id
;;

let test_entry_preserves_domain_behavior () =
  let entry = create () |> require_ok in
  require (String.equal (Journal_model.id entry) id) "entry ID changed";
  require (String.equal (Journal_model.page_id entry) page_id) "page ID changed";
  require (Journal_model.parent_id entry = Some parent_id) "parent ID changed";
  require
    (String.equal (Journal_model.sibling_order entry) "000000000001")
    "sibling order changed";
  require
    (String.equal (Journal_model.source entry) "Literal #journal @person 👩🏽‍💻")
    "literal source changed";
  require (Journal_model.task_state entry = Journal_model.Todo) "task state changed";
  require (Journal_model.child_count entry = 3) "child count changed";
  require (Journal_model.revision entry = 7) "revision changed";
  require
    (String.equal (Journal_model.last_mutation_id entry) mutation_id)
    "mutation ID changed";
  require (Journal_model.journal_day entry = 20260809) "journal day changed";
  require
    (Journal_time.equal (Journal_model.creation_time entry) creation_time)
    "creation time changed"
;;

let test_literal_unicode_source_round_trips () =
  [ "#tag @mention"
  ; "e\204\129"
  ; "עברית العربية"
  ; "👨‍👩‍👧‍👦"
  ; "日本語 中文 한국어"
  ; String.make 65_536 'x'
  ]
  |> List.iter (fun source ->
    let entry = create ~source () |> require_ok in
    require (String.equal (Journal_model.source entry) source) "source did not round trip")
;;

let test_invalid_identity_source_and_revision_are_rejected () =
  let malformed_utf8 = Bytes.unsafe_to_string (Bytes.of_string "\255") in
  [ create ~entry_id:"not-a-uuid" ()
  ; create ~entry_page_id:"not-a-uuid" ()
  ; create ~entry_parent_id:(Some "not-a-uuid") ()
  ; create ~entry_parent_id:(Some id) ()
  ; create ~sibling_order:"" ()
  ; create ~source:"" ()
  ; create ~source:"   \n\t" ()
  ; create ~source:"contains\000nul" ()
  ; create ~source:malformed_utf8 ()
  ; create ~source:(String.make 65_537 'x') ()
  ; create ~child_count:(-1) ()
  ; create ~revision:0 ()
  ; create ~last_mutation_id:"not-a-uuid" ()
  ]
  |> List.iter require_error
;;

let test_child_count_replacement_preserves_block_and_rejects_negative_counts () =
  let original = create ~child_count:3 () |> require_ok in
  let replaced = Journal_model.with_child_count original ~child_count:2 |> require_ok in
  require
    (Journal_model.child_count replaced = 2)
    "replacement did not update child count";
  require
    (String.equal (Journal_model.id replaced) (Journal_model.id original))
    "replacement changed ID";
  require
    (String.equal (Journal_model.source replaced) (Journal_model.source original))
    "replacement changed source";
  require
    (Journal_model.revision replaced = Journal_model.revision original)
    "replacement changed revision";
  require_error (Journal_model.with_child_count original ~child_count:(-1))
;;

let () =
  test_entry_preserves_domain_behavior ();
  test_literal_unicode_source_round_trips ();
  test_invalid_identity_source_and_revision_are_rejected ();
  test_child_count_replacement_preserves_block_and_rejects_negative_counts ()
;;
