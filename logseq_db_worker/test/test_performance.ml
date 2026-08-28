module T = Logseq_db_worker_test_support.Test_support
module Json = Yojson.Safe.Util

let expected_fixture_sha256 =
  "534a3e9f71595299c74956b4acfd8c3afd903a6222315ea834b45ece580075eb"
;;

let manifest_path = T.fixture "performance/100000-blocks-v1.manifest.json"

let result_path () =
  match Sys.getenv_opt "LOGSEQ_DB_WORKER_PERFORMANCE_RESULT" with
  | Some path -> path
  | None -> T.fixture "performance/reference-apple-silicon-v1.json"
;;

let read_required_json ~kind path =
  T.require (Sys.file_exists path) "%s is missing: %s" kind path;
  T.read_json path
;;

let manifest () = read_required_json ~kind:"performance fixture manifest" manifest_path
let result () = read_required_json ~kind:"performance benchmark result" (result_path ())
let field name json = Json.member name json
let string name json = field name json |> Json.to_string
let int name json = field name json |> Json.to_int
let float name json = field name json |> Json.to_float
let bool name json = field name json |> Json.to_bool

let require_sha256 name value =
  T.require (String.length value = 64) "%s is not a SHA-256 digest" name;
  String.iter
    (fun character ->
       T.require
         ((character >= '0' && character <= '9') || (character >= 'a' && character <= 'f'))
         "%s is not a lowercase SHA-256 digest"
         name)
    value
;;

let require_fixture_identity () =
  let manifest = manifest () in
  let result = result () in
  let manifest_hash = string "fixtureContentSha256" manifest in
  let result_hash = string "fixtureContentSha256" result in
  require_sha256 "fixtureContentSha256" manifest_hash;
  T.require
    (String.equal manifest_hash expected_fixture_sha256)
    "performance fixture content changed: expected %s, got %s"
    expected_fixture_sha256
    manifest_hash;
  T.require
    (String.equal result_hash manifest_hash)
    "benchmark result used a different fixture"
;;

let samples metric = int "samples" (result () |> field "latency" |> field metric)
let p95_ms metric = float "p95Milliseconds" (result () |> field "latency" |> field metric)

let cases =
  [ T.case "fixture hash and benchmark environment are recorded" (fun () ->
      require_fixture_identity ();
      let manifest = manifest () in
      let result = result () in
      T.require (int "blockCount" manifest = 100_000) "fixture block count changed";
      T.require
        (String.equal (string "architecture" (field "environment" result)) "arm64")
        "reference benchmark is not arm64";
      T.require
        (int "memoryBytes" (field "environment" result) >= 16 * 1024 * 1024 * 1024)
        "reference machine has less than 16 GiB";
      T.require
        (String.equal (string "buildProfile" (field "environment" result)) "release")
        "benchmark was not a release build";
      List.iter
        (fun name ->
           T.require
             (String.length (string name (field "environment" result)) > 0)
             "environment field %s is empty"
             name)
        [ "cpu"; "os"; "sqliteVersion"; "cacheCondition"; "rssSampler" ])
  ; T.case "100000-block cold open is within 15 seconds" (fun () ->
      require_fixture_identity ();
      T.require
        (float "coldOpenMilliseconds" (field "measurements" (result ())) < 15_000.)
        "cold open exceeded 15 seconds")
  ; T.case "peak RSS is below 1.5 GiB" (fun () ->
      require_fixture_identity ();
      T.require
        (int "peakRssBytes" (field "measurements" (result ())) < 1_610_612_736)
        "peak RSS reached or exceeded 1.5 GiB")
  ; T.case "warm Get_block p95 is below 20 ms" (fun () ->
      require_fixture_identity ();
      T.require (p95_ms "getBlock" < 20.) "Get_block p95 reached or exceeded 20 ms")
  ; T.case "warm 100-item Get_children p95 is below 100 ms" (fun () ->
      require_fixture_identity ();
      T.require
        (p95_ms "getChildren100" < 100.)
        "Get_children(100) p95 reached or exceeded 100 ms")
  ; T.case "post-backup structural mutation p95 is below 750 ms" (fun () ->
      require_fixture_identity ();
      T.require
        (p95_ms "postBackupSaveBlock" < 750.)
        "post-backup Save_block p95 reached or exceeded 750 ms")
  ; T.case "at least 100 latency samples use frozen estimator" (fun () ->
      require_fixture_identity ();
      let policy = manifest () |> field "benchmarkPolicy" in
      T.require (int "warmupSamples" policy = 20) "warm-up count is not frozen at 20";
      T.require (int "measuredSamples" policy = 100) "sample count is not frozen at 100";
      T.require
        (String.equal (string "percentileEstimator" policy) "nearest-rank")
        "percentile estimator is not nearest-rank";
      List.iter
        (fun metric ->
           T.require (samples metric >= 100) "%s has fewer than 100 samples" metric)
        [ "getBlock"; "getChildren100"; "postBackupSaveBlock" ])
  ; T.case "deep tree at depth 64 remains bounded" (fun () ->
      require_fixture_identity ();
      let boundedness = result () |> field "boundedness" in
      T.require (bool "depth64Accepted" boundedness) "depth-64 query was rejected";
      T.require
        (bool "depth65Rejected" boundedness)
        "depth greater than 64 was not rejected")
  ; T.case "large sibling set paginates deterministically" (fun () ->
      require_fixture_identity ();
      T.require
        (bool "largeSiblingPaginationDeterministic" (field "boundedness" (result ())))
        "large sibling pagination was not deterministic")
  ; T.case "high reference cardinality respects byte budget" (fun () ->
      require_fixture_identity ();
      let boundedness = result () |> field "boundedness" in
      T.require
        (bool "highReferencesWithinResponseBudget" boundedness)
        "high-reference response exceeded its byte budget";
      T.require
        (int "highReferencesResponseBytes" boundedness
         <= Logseq_db_worker.Protocol.maximum_response_bytes)
        "high-reference response exceeded the protocol ceiling")
  ; T.case "snapshot and first backup throughput are reported" (fun () ->
      require_fixture_identity ();
      let throughput = result () |> field "throughput" in
      List.iter
        (fun name -> T.require (float name throughput > 0.) "%s was not reported" name)
        [ "snapshotBytesPerSecond"; "firstBackupBytesPerSecond" ])
  ]
;;

let () = T.run "performance" cases
