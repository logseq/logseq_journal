module Cache = Logseq_sync_assets.Cache
module Namespace = Logseq_sync_assets.Namespace
module Codec = Logseq_sync_native_crypto.Asset_codec
module Uuid = Logseq_db_types.Graph_types.Uuid

let ok = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "unexpected error"
;;

let some = function
  | Some value -> value
  | None -> Alcotest.fail "expected resource"
;;

let bool = Alcotest.check Alcotest.bool
let exists label expected path = bool label expected (Sys.file_exists path)
let read path = In_channel.with_open_bin path In_channel.input_all
let write path bytes = Out_channel.with_open_bin path (fun out -> output_string out bytes)

let uuid index =
  Uuid.of_string (Printf.sprintf "96000000-0000-4000-8000-%012d" index) |> ok
;;

let operation = uuid 1
let asset = uuid 2

let scope ?(origin = "https://sync.example.test") ?(user = "alice") ?(graph = 3) ()
  : Namespace.graph_scope
  =
  { account = { managed_sync_origin = Uri.of_string origin; user_id = user }
  ; graph_id = uuid graph
  }
;;

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_fixture test =
  let root = Filename.temp_file ~temp_dir:(Sys.getcwd ()) "asset-cache-fixture-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let caches = ref [] in
  let create ?(scope = scope ()) ?(budget = 8L) ?(maximum = 8) () =
    let cache =
      Cache.create ~root ~scope ~budget_bytes:budget ~maximum_file_bytes:maximum |> ok
    in
    caches := cache :: !caches;
    cache
  in
  let source = Filename.concat root "source.bin" in
  write source "file";
  Fun.protect
    ~finally:(fun () ->
      List.iter Cache.close !caches;
      remove_tree root)
    (fun () -> test root source create)
;;

let stage ?(budget = 64L) ?(file_type = "bin") cache source =
  Cache.stage cache ~operation ~file_type ~source_file:source ~pending_budget_bytes:budget
;;

let staged_path cache (staged : Cache.staged) =
  Cache.staged_path cache ~file:staged.file |> some
;;

let release cache handle = Cache.release_checked cache handle |> ok
let close cache = Cache.close_checked cache |> ok

let invalid = function
  | Error (Cache.Invalid _) -> ()
  | _ -> Alcotest.fail "expected Invalid"
;;

let full result = bool "storage full" true (result = Error Cache.Full)

let durable_staging () =
  with_fixture (fun _ source create ->
    let cache = create ~budget:0L () in
    let staged = stage cache source |> ok in
    Alcotest.(check string) "checksum" (Codec.checksum "file") staged.checksum;
    Alcotest.(check int64) "size" 4L staged.size;
    let path = staged_path cache staged in
    Sys.remove source;
    Alcotest.(check string) "independent copy" "file" (read path);
    write (path ^ ".part") "interrupted";
    close cache;
    let reopened = create ~budget:0L () in
    Alcotest.(check string) "same durable path" path (staged_path reopened staged);
    exists "partial removed" false (path ^ ".part");
    ignore (Cache.prune reopened |> ok);
    exists "pending not evicted" true path;
    Cache.release_staged reopened ~file:staged.file |> ok;
    Cache.release_staged reopened ~file:staged.file |> ok;
    exists "completion removes copy" false path)
;;

let staging_limits () =
  with_fixture (fun _ source create ->
    let cache = create ~maximum:4 () in
    write source "large";
    invalid (stage cache source);
    write source "file";
    let staged = stage ~budget:4L cache source |> ok in
    full (stage ~budget:4L cache source);
    exists "budget rejection preserves source" true (staged_path cache staged);
    Cache.release_staged cache ~file:staged.file |> ok;
    ignore (stage ~budget:4L cache source |> ok))
;;

let empty_staging_budget () =
  with_fixture (fun _ source create ->
    let cache = create () in
    write source "";
    full (stage ~budget:0L cache source);
    let staged = stage ~budget:1L cache source |> ok in
    full (stage ~budget:1L cache source);
    Alcotest.(check int64) "empty size" 0L staged.size)
;;

let invalid_inputs () =
  with_fixture (fun root source create ->
    let cache = create () in
    invalid (stage ~file_type:"../bin" cache source);
    invalid (stage ~budget:(-1L) cache source);
    invalid (stage cache root);
    bool
      "traversal not readable"
      true
      (Cache.staged_path cache ~file:"../source.bin" = None);
    bool
      "traversal not retainable"
      true
      (Cache.retain_staged cache ~file:"../source.bin" = None);
    invalid (Cache.release_staged cache ~file:"../source.bin");
    invalid
      (Cache.create ~root ~scope:(scope ()) ~budget_bytes:(-1L) ~maximum_file_bytes:8);
    invalid
      (Cache.create
         ~root
         ~scope:(scope ())
         ~budget_bytes:8L
         ~maximum_file_bytes:((100 * 1024 * 1024) + 1)))
;;

let preview_leases () =
  with_fixture (fun _ source create ->
    let cache = create () in
    let staged = stage cache source |> ok in
    let first = Cache.retain_staged cache ~file:staged.file |> some in
    let second = Cache.retain cache first |> some in
    bool "distinct leases" true (first <> second);
    let path = Cache.path cache first |> some in
    full (Cache.release_staged_if_unused cache ~file:staged.file);
    Cache.release_staged cache ~file:staged.file |> ok;
    bool
      "retired refuses new preview"
      true
      (Cache.retain_staged cache ~file:staged.file = None);
    let report = Cache.report cache |> ok in
    Alcotest.(check int64) "retained bytes counted once" 4L report.retained_bytes;
    Alcotest.(check int) "deferred cleanup" 1 report.cleanup_pending;
    invalid (Cache.close_checked cache);
    release cache first;
    exists "second lease preserves bytes" true path;
    release cache second;
    release cache second;
    exists "last release cleans" false path;
    bool "released lease invalid" true (Cache.path cache second = None);
    close cache)
;;

let nonterminal_preview () =
  with_fixture (fun _ source create ->
    let cache = create () in
    let staged = stage cache source |> ok in
    let lease = Cache.retain_staged cache ~file:staged.file |> some in
    let path = Cache.path cache lease |> some in
    release cache lease;
    close cache;
    exists "close preserves pending ownership" true path;
    bool
      "closed scope rejects retain"
      true
      (Cache.retain_staged cache ~file:staged.file = None);
    bool "closed stage stale" true (stage cache source = Error Cache.Stale))
;;

let checked_release_retry () =
  with_fixture (fun _ source create ->
    let cache = create () in
    let staged = stage cache source |> ok in
    let lease = Cache.retain_staged cache ~file:staged.file |> some in
    let path = Cache.path cache lease |> some in
    Cache.release_staged cache ~file:staged.file |> ok;
    let saved = path ^ ".saved" in
    Unix.rename path saved;
    Unix.mkdir path 0o700;
    (match Cache.release_checked cache lease with
     | Error (Cache.Io _) -> ()
     | _ -> Alcotest.fail "cleanup failure must be typed");
    bool "failed release retains exact handle" true (Cache.path cache lease = Some path);
    invalid (Cache.close_checked cache);
    Unix.rmdir path;
    Unix.rename saved path;
    release cache lease;
    exists "retry completes cleanup" false path;
    close cache)
;;

let exact_instances () =
  with_fixture (fun _ source create ->
    let cache = create () in
    let older = stage cache source |> ok in
    let newer = stage cache source |> ok in
    bool "same operation fresh physical identity" true (older.file <> newer.file);
    let old_path = staged_path cache older in
    let new_path = staged_path cache newer in
    let seen = ref [] in
    let removed =
      Cache.prune_staged cache ~keep:(fun file ->
        seen := file :: !seen;
        Ok (file = newer.file))
      |> ok
    in
    Alcotest.(check int) "one orphan" 1 removed;
    Alcotest.(check (list string))
      "exact names checked"
      (List.sort String.compare [ older.file; newer.file ])
      (List.sort String.compare !seen);
    exists "old removed" false old_path;
    Cache.release_staged cache ~file:older.file |> ok;
    exists "late old completion preserves replacement" true new_path;
    Alcotest.(check int)
      "idempotent prune"
      0
      (Cache.prune_staged cache ~keep:(fun _ -> Ok true) |> ok))
;;

let prune_legacy_and_strangers () =
  with_fixture (fun _ source create ->
    let cache = create () in
    let staged = stage cache source |> ok in
    let directory = Filename.dirname (staged_path cache staged) in
    let legacy = Uuid.to_string (uuid 4) ^ ".bin" in
    let legacy_path = Filename.concat directory legacy in
    write legacy_path "legacy";
    let lease = Cache.retain_staged cache ~file:legacy |> some in
    Alcotest.(check string)
      "legacy preview"
      "legacy"
      (read (Cache.path cache lease |> some));
    release cache lease;
    let stranger = Filename.concat directory "unknown.txt" in
    write stranger "keep";
    let link = Filename.concat directory (Uuid.to_string (uuid 5) ^ ".bin") in
    Unix.symlink source link;
    let seen = ref [] in
    Alcotest.(check int)
      "legacy pruned"
      1
      (Cache.prune_staged cache ~keep:(fun file ->
         seen := file :: !seen;
         Ok (file = staged.file))
       |> ok);
    bool "legacy exact identity checked" true (List.mem legacy !seen);
    exists "legacy removed" false legacy_path;
    exists "stranger preserved" true stranger;
    bool "symlink preserved" true ((Unix.lstat link).st_kind = Unix.S_LNK);
    exists "symlink target preserved" true source)
;;

let prune_failure_atomic () =
  with_fixture (fun _ source create ->
    let cache = create () in
    let first = stage cache source |> ok in
    let second = stage cache source |> ok in
    let calls = ref 0 in
    (match
       Cache.prune_staged cache ~keep:(fun _ ->
         incr calls;
         if !calls = 2 then Error "ownership unavailable" else Ok false)
     with
     | Error (Cache.Io _) -> ()
     | _ -> Alcotest.fail "ownership failure must abort prune");
    exists "first survives aborted prune" true (staged_path cache first);
    exists "second survives aborted prune" true (staged_path cache second))
;;

let prune_pinned () =
  with_fixture (fun _ source create ->
    let cache = create () in
    let staged = stage cache source |> ok in
    let lease = Cache.retain_staged cache ~file:staged.file |> some in
    Alcotest.(check int)
      "pinned skipped"
      0
      (Cache.prune_staged cache ~keep:(fun _ ->
         Alcotest.fail "pinned ownership must not be queried")
       |> ok);
    release cache lease;
    Alcotest.(check int)
      "released orphan removed"
      1
      (Cache.prune_staged cache ~keep:(fun _ -> Ok false) |> ok))
;;

let directory_limit () =
  with_fixture (fun _ source create ->
    let cache = create () in
    let staged = stage cache source |> ok in
    let path = staged_path cache staged in
    let directory = Filename.dirname path in
    for index = 1 to 4096 do
      write (Filename.concat directory ("unknown-" ^ string_of_int index)) ""
    done;
    full (stage cache source);
    full (Cache.prune_staged cache ~keep:(fun _ -> Ok false));
    exists "scan overflow removes nothing" true path)
;;

let crypto : Codec.crypto =
  { encrypt = (fun ~key:_ ~plaintext:_ -> Error "unused")
  ; decrypt = (fun ~key:_ ~iv:_ ~ciphertext:_ -> Error "unused")
  }
;;

let version bytes =
  Logseq_db_types.Asset_descriptor.version
    ~checksum:(Codec.checksum bytes)
    ~file_type:"bin"
  |> ok
;;

let verified bytes =
  Codec.decode
    ~maximum_plaintext_bytes:64
    ~crypto
    ~key:None
    ~expected:(version bytes)
    bytes
  |> ok
;;

let publish cache bytes =
  Cache.publish cache ~asset ~current:(fun () -> true) ~verified:(verified bytes)
;;

let published_durable () =
  with_fixture (fun _ _ create ->
    let cache = create () in
    let lease = publish cache "file" |> ok in
    let path = Cache.path cache lease |> some in
    let duplicate = Cache.retain cache lease |> some in
    invalid (Cache.close_checked cache);
    release cache lease;
    exists "retained published bytes" true path;
    release cache duplicate;
    close cache;
    let reopened = create () in
    let restored = Cache.lookup reopened ~asset ~version:(version "file") |> ok |> some in
    Alcotest.(check string)
      "manifest-backed recovery"
      "file"
      (read (Cache.path reopened restored |> some));
    release reopened restored)
;;

let published_limits () =
  with_fixture (fun _ _ create ->
    let cache = create ~budget:4L () in
    let lease = publish cache "file" |> ok in
    full (publish cache "next");
    release cache lease;
    let next = publish cache "next" |> ok in
    bool
      "unpinned entry evicted"
      true
      (Cache.lookup cache ~asset ~version:(version "file") |> ok = None);
    release cache next;
    invalid (publish cache "123456789");
    bool
      "stale publication refused"
      true
      (Cache.publish cache ~asset ~current:(fun () -> false) ~verified:(verified "next")
       = Error Cache.Stale))
;;

let corrupt_publication () =
  with_fixture (fun _ _ create ->
    let cache = create () in
    let lease = publish cache "file" |> ok in
    let path = Cache.path cache lease |> some in
    write path "evil";
    bool
      "corrupt bytes not served"
      true
      (Cache.lookup cache ~asset ~version:(version "file") |> ok = None);
    full (publish cache "file");
    release cache lease;
    bool
      "corrupt unpinned entry removed"
      true
      (Cache.lookup cache ~asset ~version:(version "file") |> ok = None);
    exists "corrupt file removed" false path;
    let replacement = publish cache "file" |> ok in
    release cache replacement)
;;

let scope_isolation () =
  with_fixture (fun _ source create ->
    let original = create () in
    let staged = stage original source |> ok in
    let published = publish original "file" |> ok in
    List.iter
      (fun scoped ->
         let other = create ~scope:scoped () in
         bool "staging isolated" true (Cache.staged_path other ~file:staged.file = None);
         bool
           "published isolated"
           true
           (Cache.lookup other ~asset ~version:(version "file") |> ok = None);
         bool "lease isolated" true (Cache.path other published = None);
         release other published;
         bool "foreign release harmless" true (Cache.path original published <> None))
      [ scope ~origin:"https://other.example.test" ()
      ; scope ~user:"bob" ()
      ; scope ~graph:4 ()
      ];
    release original published)
;;

let retirement index =
  Namespace.retirement_id_of_string (Uuid.to_string (uuid index)) |> ok
;;

let deletion scope retirement = Namespace.asset_deletion_reference ~scope ~retirement

let graph_abort () =
  with_fixture (fun root source create ->
    let scoped = scope () in
    let cache = create () in
    let staged = stage cache source |> ok in
    let path = staged_path cache staged in
    close cache;
    let retirement = retirement 10 in
    let deletion = deletion scoped retirement in
    Cache.prepare_graph_deletion ~root ~scope:scoped ~retirement |> ok;
    Cache.prepare_graph_deletion ~root ~scope:scoped ~retirement |> ok;
    exists "prepared namespace moved" false path;
    bool
      "not terminal while prepared"
      true
      (Cache.graph_deletion_terminal ~root ~scope:scoped ~retirement |> ok = None);
    Cache.finish_graph_deletion ~root ~deletion ~commit:false |> ok;
    exists "abort restores bytes" true path;
    Cache.finish_graph_deletion ~root ~deletion ~commit:true |> ok;
    exists "late commit cannot reverse abort" true path;
    bool
      "abort terminal"
      true
      (Cache.graph_deletion_terminal ~root ~scope:scoped ~retirement |> ok = Some `Aborted))
;;

let graph_commit_replacement () =
  with_fixture (fun root source create ->
    let scoped = scope () in
    let cache = create () in
    let staged = stage cache source |> ok in
    let path = staged_path cache staged in
    close cache;
    let retirement = retirement 11 in
    let deletion = deletion scoped retirement in
    Cache.prepare_graph_deletion ~root ~scope:scoped ~retirement |> ok;
    let replacement = create () in
    let fresh = stage replacement source |> ok in
    let fresh_path = staged_path replacement fresh in
    close replacement;
    Cache.finish_graph_deletion ~root ~deletion ~commit:true |> ok;
    Cache.finish_graph_deletion ~root ~deletion ~commit:false |> ok;
    Cache.finish_graph_deletion ~root ~deletion ~commit:true |> ok;
    exists "old source removed" false path;
    exists "replacement survives terminal replay" true fresh_path;
    bool
      "commit terminal"
      true
      (Cache.graph_deletion_terminal ~root ~scope:scoped ~retirement
       |> ok
       = Some `Committed))
;;

let graph_restore_conflict () =
  with_fixture (fun root source create ->
    let scoped = scope () in
    let cache = create () in
    let staged = stage cache source |> ok in
    let path = staged_path cache staged in
    close cache;
    let retirement = retirement 12 in
    let deletion = deletion scoped retirement in
    Cache.prepare_graph_deletion ~root ~scope:scoped ~retirement |> ok;
    let replacement = create () in
    let fresh = stage replacement source |> ok in
    let fresh_path = staged_path replacement fresh in
    close replacement;
    bool
      "restore conflict reported"
      true
      (Result.is_error (Cache.finish_graph_deletion ~root ~deletion ~commit:false));
    exists "replacement not overwritten" true fresh_path;
    remove_tree (Filename.dirname (Filename.dirname fresh_path));
    Cache.finish_graph_deletion ~root ~deletion ~commit:false |> ok;
    exists "retry restores original" true path)
;;

let account_deletion () =
  with_fixture (fun root source create ->
    let scopes =
      [ scope ()
      ; scope ~graph:4 ()
      ; scope ~user:"bob" ()
      ; scope ~origin:"https://other.example.test" ()
      ]
    in
    let paths =
      List.map
        (fun scoped ->
           let cache = create ~scope:scoped () in
           let staged = stage cache source |> ok in
           let path = staged_path cache staged in
           close cache;
           path)
        scopes
    in
    Cache.delete_account ~root ~account:(scope ()).account |> ok;
    List.iter2
      (fun expected path -> exists "account/origin deletion boundary" expected path)
      [ false; false; true; true ]
      paths;
    Cache.delete_account ~root ~account:(scope ()).account |> ok)
;;

let () =
  Alcotest.run
    "native asset cache"
    [ ( "Cache"
      , List.map
          (fun (name, test) -> Alcotest.test_case name `Quick test)
          [ "durable staging and recovery", durable_staging
          ; "staging file and pending limits", staging_limits
          ; "empty staging consumes capacity", empty_staging_budget
          ; "invalid inputs and traversal", invalid_inputs
          ; "preview leases and deferred cleanup", preview_leases
          ; "nonterminal preview survives close", nonterminal_preview
          ; "checked release retries exact handle", checked_release_retry
          ; "prune exact physical identities", exact_instances
          ; "legacy staging and strangers", prune_legacy_and_strangers
          ; "ownership failure makes prune atomic", prune_failure_atomic
          ; "prune protects preview leases", prune_pinned
          ; "bounded staging directory scan", directory_limit
          ; "published bytes survive reopen", published_durable
          ; "published limits and eviction", published_limits
          ; "corrupt pinned publication", corrupt_publication
          ; "origin account graph isolation", scope_isolation
          ; "graph retirement abort", graph_abort
          ; "graph retirement commit and replacement", graph_commit_replacement
          ; "graph restore conflict and retry", graph_restore_conflict
          ; "account deletion isolation", account_deletion
          ] )
    ]
;;
