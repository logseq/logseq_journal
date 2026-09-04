module Database = Logseq_overlay_db.Database
module T = Test_support

let manifest_path =
  Filename.concat
    T.root
    "logseq_overlay_db/test/fixtures/performance/100000-blocks-v1.manifest.json"
;;

let require_positive_member json name =
  let open Yojson.Safe.Util in
  let value = json |> member name |> to_int in
  T.require (value > 0) "performance manifest field %s is not positive" name;
  value
;;

let manifest_has_every_numeric_gate () =
  let open Yojson.Safe.Util in
  let manifest = Yojson.Safe.from_file manifest_path in
  let fixture = manifest |> member "fixture" in
  T.require
    (fixture |> member "block_count" |> to_int = 100_000)
    "performance fixture does not contain 100,000 blocks";
  let checksum = fixture |> member "checksum" |> to_string in
  T.require
    (String.length checksum = 71 && String.starts_with ~prefix:"sha256:" checksum)
    "performance fixture checksum is missing or malformed";
  let p95 = manifest |> member "p95_milliseconds" in
  List.iter
    (fun name -> ignore (require_positive_member p95 name))
    [ "get_blocks_64"
    ; "get_structure_200"
    ; "get_journals_200"
    ; "single_block_change_classification"
    ; "replan_and_diff_128"
    ; "reopen_1024"
    ; "maximum_get_blocks_64"
    ; "maximum_get_structure_200"
    ; "maximum_get_journals_200"
    ; "maximum_rebase_and_diff_4096"
    ; "maximum_delete_conflict"
    ; "maximum_reopen_4096"
    ];
  let sizes = manifest |> member "active_outbox_records" |> to_list |> List.map to_int in
  T.require
    (sizes = [ 0; 1; 32; 128; 1_024; 4_096 ])
    "performance manifest does not cover every required outbox size"
;;

let point_read_collects_real_samples _database snapshot =
  let behavior = "performance point read collects real samples" in
  let requested = List.init 64 (fun _ -> T.page_uuid) in
  let allocated_before = Gc.allocated_bytes () in
  let started = Unix.gettimeofday () in
  let result = Database.get_pages snapshot requested |> T.require_ok ~behavior in
  let elapsed = Unix.gettimeofday () -. started in
  let allocated = Gc.allocated_bytes () -. allocated_before in
  T.require (List.length result = 64) "64-item point read returned wrong cardinality";
  T.require (elapsed > 0.) "point-read timing sample is a zero-duration placeholder";
  T.require (allocated > 0.) "point-read allocation counter is absent"
;;

let suite =
  [ Alcotest.test_case
      "manifest freezes every numeric gate"
      `Quick
      manifest_has_every_numeric_gate
  ; T.snapshot_case
      "point read records wall time and allocations"
      point_read_collects_real_samples
  ]
;;

let () = Alcotest.run "logseq_overlay_db performance harness" [ "red harness", suite ]
