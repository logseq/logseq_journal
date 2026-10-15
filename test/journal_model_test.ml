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
      ?(revision = "block-7")
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
  require (String.equal (Journal_model.revision entry) "block-7") "revision changed";
  require
    (String.equal (Journal_model.last_mutation_id entry) mutation_id)
    "mutation ID changed";
  require (Journal_model.journal_day entry = 20260809) "journal day changed";
  require
    (Journal_time.equal (Journal_model.creation_time entry) creation_time)
    "creation time changed"
;;

let test_literal_unicode_source_round_trips () =
  [ ""
  ; "   \n\t"
  ; "#tag @mention"
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
  ; create ~source:"contains\000nul" ()
  ; create ~source:malformed_utf8 ()
  ; create ~source:(String.make 65_537 'x') ()
  ; create ~child_count:(-1) ()
  ; create ~revision:"" ()
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

module Squuid = Logseq_db_types.Squuid
module Uuid = Logseq_db_types.Graph_types.Uuid

let random_bytes uuid =
  let hex = String.split_on_char '-' uuid |> String.concat "" in
  Bytes.init 16 (fun i -> Char.chr (int_of_string ("0x" ^ String.sub hex (i * 2) 2)))
;;

let next_squuid state timestamp random =
  match Squuid.next state ~timestamp_ms:timestamp ~random_bytes:random with
  | Ok result -> result
  | Error _ -> fail "SQUUID allocation unexpectedly failed"
;;

let expect_squuid expected actual =
  require
    (Uuid.to_string actual = expected)
    "expected %s, got %s"
    expected
    (Uuid.to_string actual);
  require
    (Uuid.equal actual (Uuid.of_string expected |> require_ok))
    "UUID round-trip failed"
;;

let test_squuid_layout () =
  let _, uuid =
    next_squuid
      Squuid.empty
      1_640_183_584_769L
      (random_bytes "85335e1f-9c1f-4c62-9ce9-cef70883794a")
  in
  expect_squuid "017de28f-5801-8c62-9ce9-cef70883794a" uuid;
  List.iter
    (fun (byte, variant) ->
       let random = Bytes.make 16 '\255' in
       Bytes.set random 8 (Char.chr byte);
       let _, uuid = next_squuid Squuid.empty 0L random in
       expect_squuid ("00000000-0000-8fff-" ^ variant ^ "fff-ffffffffffff") uuid)
    [ 0x0f, "8"; 0x5f, "9"; 0xaf, "a"; 0xff, "b" ];
  let _, uuid = next_squuid Squuid.empty 0xffffffffffffL (Bytes.make 16 '\000') in
  expect_squuid "ffffffff-ffff-8000-8000-000000000000" uuid
;;

let test_squuid_monotonic_transitions () =
  let random = Bytes.make 16 '\000' in
  let state, epoch = next_squuid Squuid.empty 0L random in
  expect_squuid "00000000-0000-8000-8000-000000000000" epoch;
  let state, repeated = next_squuid state 0L (Bytes.make 16 '\255') in
  expect_squuid "00000000-0000-8000-8000-000000000001" repeated;
  let state, later = next_squuid state 256L random in
  expect_squuid "00000000-0100-8000-8000-000000000000" later;
  let state, rollback = next_squuid state 1L (Bytes.make 16 '\255') in
  expect_squuid "00000000-0100-8000-8000-000000000001" rollback;
  let _, retained = next_squuid state 256L random in
  expect_squuid "00000000-0100-8000-8000-000000000002" retained;
  List.iter
    (fun (a, b) -> require (Uuid.compare a b < 0) "UUID order did not increase")
    [ epoch, repeated; repeated, later; later, rollback; rollback, retained ];
  let state, _ = next_squuid Squuid.empty 257L (Bytes.make 16 '\255') in
  let _, later = next_squuid state 258L random in
  expect_squuid "00000000-0102-8000-8000-000000000000" later
;;

let test_squuid_payload_carries () =
  List.iter
    (fun (base, expected) ->
       let state, before = next_squuid Squuid.empty 1L (random_bytes base) in
       let _, after = next_squuid state 1L (Bytes.make 16 '\000') in
       expect_squuid expected after;
       require (Uuid.compare before after < 0) "carry reversed UUID order")
    [ "00000000-0000-8000-8000-0000000000ff", "00000000-0001-8000-8000-000000000100"
    ; "00000000-0000-8000-8000-ffffffffffff", "00000000-0001-8000-8001-000000000000"
    ; "00000000-0000-8000-8fff-ffffffffffff", "00000000-0001-8000-9000-000000000000"
    ; "00000000-0000-8000-9fff-ffffffffffff", "00000000-0001-8000-a000-000000000000"
    ; "00000000-0000-8000-afff-ffffffffffff", "00000000-0001-8000-b000-000000000000"
    ; "00000000-0000-8000-bfff-ffffffffffff", "00000000-0001-8001-8000-000000000000"
    ; "00000000-0000-80ff-bfff-ffffffffffff", "00000000-0001-8100-8000-000000000000"
    ; "00000000-0000-8ffe-bfff-ffffffffffff", "00000000-0001-8fff-8000-000000000000"
    ]
;;

let test_squuid_errors_and_state_retention () =
  let random = Bytes.make 16 '\000' in
  let state, _ = next_squuid Squuid.empty 100L random in
  List.iter
    (fun state ->
       List.iter
         (fun timestamp ->
            require
              (Squuid.next state ~timestamp_ms:timestamp ~random_bytes:random
               = Error Squuid.Timestamp_out_of_range)
              "invalid timestamp accepted")
         [ -1L; Int64.min_int; 0x1000000000000L; Int64.max_int ];
       List.iter
         (fun length ->
            require
              (Squuid.next
                 state
                 ~timestamp_ms:100L
                 ~random_bytes:(Bytes.make length '\000')
               = Error (Squuid.Invalid_random_length length))
              "invalid entropy length accepted")
         [ 0; 15; 17; 32 ])
    [ Squuid.empty; state ];
  let _, uuid = next_squuid state 100L random in
  expect_squuid "00000000-0064-8000-8000-000000000001" uuid;
  let mutable_random = Bytes.make 16 '\255' in
  let exhausted, _ = next_squuid Squuid.empty 100L mutable_random in
  Bytes.fill mutable_random 0 16 '\000';
  List.iter
    (fun timestamp ->
       require
         (Squuid.next exhausted ~timestamp_ms:timestamp ~random_bytes:random
          = Error Squuid.Payload_exhausted)
         "payload exhausted without failure")
    [ 0L; 100L ];
  let _, recovered = next_squuid exhausted 101L random in
  expect_squuid "00000000-0065-8000-8000-000000000000" recovered;
  let exhausted, _ = next_squuid Squuid.empty 0xffffffffffffL (Bytes.make 16 '\255') in
  require
    (Squuid.next exhausted ~timestamp_ms:0xffffffffffffL ~random_bytes:random
     = Error Squuid.Payload_exhausted)
    "maximum timestamp wrapped"
;;

let test_reference_text () =
  let a = id
  and b = parent_id in
  let link id = "[[" ^ id ^ "]]" in
  let sources = [ a, "Target 中文\nsecond line"; b, "nested " ^ link a ] in
  let render =
    Journal_model.render_references ~lookup:(fun id -> List.assoc_opt id sources)
  in
  require
    (render ("before " ^ link b ^ " after") = "before nested Target 中文\nsecond line after")
    "nested UUID reference was not rendered";
  require
    (render (link (String.uppercase_ascii a)) = "Target 中文\nsecond line")
    "uppercase UUID reference was not normalized";
  let literal = "[[page]] [[not-a-uuid]] [[" ^ a ^ "x]] [[" ^ a ^ "]]" in
  require
    (render literal = "[[page]] [[not-a-uuid]] [[" ^ a ^ "x]] Target 中文\nsecond line")
    "page or malformed reference changed";
  require (render ("\\" ^ link a) = "\\" ^ link a) "escaped reference changed";
  require (render (link mutation_id) = link mutation_id) "missing target disappeared";
  let cycles = [ a, link b; b, link a ] in
  require
    (Journal_model.render_references ~lookup:(fun id -> List.assoc_opt id cycles) (link a)
     = link a)
    "cyclic reference did not terminate at the original token";
  require
    (Journal_model.render_references ~lookup:(fun _ -> Some "") (link a) = "")
    "empty block content did not render";
  let chain id = Some ("x" ^ link id) in
  require
    (String.length (Journal_model.render_references ~lookup:chain (link a)) < 100)
    "self reference expanded without a bound";
  let doubling = String.concat "" (List.init 400 (fun _ -> link a)) in
  require
    (String.length (render doubling) <= 65536)
    "reference output exceeded text budget";
  require
    (Journal_model.reference_ids (link a ^ link a ^ "[[page]]" ^ "\\" ^ link b) = [ a ])
    "reference discovery did not deduplicate UUIDs or preserve escapes"
;;

let test_rich_title_boundaries () =
  let link id = "[[" ^ id ^ "]]" in
  let render = Journal_model.Title.render ~lookup:(fun target ->
    List.assoc_opt target [id, "**Target 中文**"; parent_id, link id; mutation_id, "**" ^ link mutation_id ^ "**"]) in
  let plain source = render source |> Journal_model.Title.plain in
  List.iter (fun (source, expected) -> require (plain source = expected) "rich title: %s" source)
    [ "prefix " ^ link parent_id ^ " suffix", "prefix Target 中文 suffix"
    ; link mutation_id, link mutation_id
    ; link "00000000-0000-4000-a000-000000000099", link "00000000-0000-4000-a000-000000000099"
    ; "`" ^ link id ^ "`", link id
    ; "\\" ^ link id, link id
    ; "((" ^ id ^ "))", "((" ^ id ^ "))"
    ; "# First\n# Second", "First\nSecond"
    ; "[](https://example.org/path)", "https://example.org/path"
    ; "<admin@example.org>", "admin@example.org"
    ; "before [1/3] after", "before [1/3] after"
    ; "before {{renderer :hello}} after", "before {{renderer :hello}} after"
    ; "{{renderer :hello}} " ^ link id, "{{renderer :hello}} Target 中文"
    ; "before [[outer [[inner]]]] after", "before [[outer [[inner]]]] after"
    ; "SCHEDULED: <2026-10-14 Wed> " ^ link id, "SCHEDULED: <2026-10-14 Wed> Target 中文" ];
  require
    (List.for_all (fun (run : Journal_model.Title.run) -> run.reference = Some parent_id) (render (link parent_id)))
    "nested expansion changed the outer reference click target";
  let runs = render ("**" ^ link id ^ "**") in
  require (List.exists (fun (run : Journal_model.Title.run) -> run.text = "Target 中文" && run.reference = Some id && List.mem "bold" run.styles) runs) "reference lost styles/target";
  let runs = render "[**标签**](HTTP://example.org/path)" in
  require (List.exists (fun (run : Journal_model.Title.run) -> run.url = Some "http://example.org/path" && run.text = "标签" && List.mem "bold" run.styles) runs) "URL lost nested style or authority";
  let repeated = String.concat " " (List.init 600 (fun _ -> link id)) in
  require (String.length (plain repeated) <= 65536) "title work/output budget exceeded";
  let long = String.concat "" (List.init 2000 (fun _ -> "中文 English ")) in
  require (plain long = long) "long bilingual title truncated in OCaml";
  require (Journal_model.Title.plain (Journal_model.Title.render ~lookup:(fun _ -> Some "") (link id)) = "") "empty target changed";
  let pathological = String.make 4000 '[' ^ "x" ^ String.make 4000 ']' in
  let before = Unix.gettimeofday () in
  require (plain pathological = pathological) "complex title lost literal fallback";
  require (Unix.gettimeofday () -. before < 0.1) "mldoc complexity admission did not bound parse time";
  let first = Journal_model.Title.render ~lookup:(fun _ -> Some "first") (link id)
  and next = Journal_model.Title.render ~lookup:(fun _ -> Some "next") (link id) in
  require (Journal_model.Title.plain first = "first" && Journal_model.Title.plain next = "next") "parse cache retained stale reference output"
;;

let test_ast_reference_discovery () =
  let a = id and b = parent_id in
  let page id = "[[" ^ id ^ "]]" and ref id = "((" ^ id ^ "))" in
  let cases =
    [ "deprecated syntax is literal", ref a ^ " " ^ ref a, []
    ; "nested formatting", "**" ^ page a ^ "** and _" ^ page b ^ "_", [a;b]
    ; "code", "`" ^ page a ^ "` ``" ^ ref b ^ "``", []
    ; "fenced code", "```\n" ^ ref a ^ "\n```", []
    ; "escaped", "\\" ^ page a ^ " \\" ^ ref b, []
    ; "labeled reference", "[label](" ^ page a ^ ")", [a]
    ; "URLs", "https://example.com [label](https://example.com)", []
    ; "missing valid UUID", page mutation_id, [mutation_id]
    ; "plain CJK", "普通文本 English 中英文长文", [] ]
  in
  List.iter (fun (name, source, expected) ->
    require (Journal_model.reference_ids source = expected)
      "AST reference discovery: %s" name) cases
;;

let () =
  test_rich_title_boundaries ();
  test_ast_reference_discovery ();
  test_reference_text ();
  test_squuid_layout ();
  test_squuid_monotonic_transitions ();
  test_squuid_payload_carries ();
  test_squuid_errors_and_state_retention ();
  test_entry_preserves_domain_behavior ();
  test_literal_unicode_source_round_trips ();
  test_invalid_identity_source_and_revision_are_rejected ();
  test_child_count_replacement_preserves_block_and_rejects_negative_counts ()
;;
