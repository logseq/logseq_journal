module S = Logseq_sync_effect_runner.Asset_cache
module Codec = Logseq_sync_effect_runner.Asset_codec
module A = Logseq_db_types.Asset_descriptor
module C = Logseq_sync_pure_reducer.Core
module U = Logseq_db_types.Graph_types.Uuid

let get = function
  | Ok x -> x
  | Error _ -> failwith "unexpected error"
;;

let uuid = get (U.of_string "00000000-0000-4000-8000-000000000001")

let scope : C.graph_scope =
  { account =
      { managed_sync_origin = Uri.of_string "https://sync.example"
      ; user_id = "user"
      ; account_generation = 1
      ; presentation_generation = 1
      ; lifecycle_generation = 1L
      }
  ; graph_id = uuid
  ; graph_generation = 1
  }
;;

let version bytes = get (A.version ~checksum:(Codec.checksum bytes) ~file_type:"png")

let rec remove path =
  if Sys.is_directory path
  then (
    Array.iter (fun n -> remove (Filename.concat path n)) (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path
;;

let fixture test =
  let root = Filename.temp_file "asset-cache" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () -> test root)
;;

let create ?(budget = 8L) ?(scope = scope) root =
  get (S.create ~root ~scope ~budget_bytes:budget ~maximum_file_bytes:8)
;;

let put cache bytes =
  S.publish
    cache
    ~asset:uuid
    ~version:(version bytes)
    ~current:(fun () -> true)
    ~plaintext:bytes
;;

let lookup cache bytes = get (S.lookup cache ~asset:uuid ~version:(version bytes))
let exists cache bytes = Option.is_some (lookup cache bytes)
let bool = Alcotest.check Alcotest.bool

let roundtrip () =
  fixture (fun root ->
    let cache = create root in
    let handle = get (put cache "file") in
    let path = Option.get (S.path cache handle) in
    let channel = open_in_bin path in
    let bytes = really_input_string channel 4 in
    close_in channel;
    Alcotest.(check string) "published bytes" "file" bytes;
    S.close cache;
    let cache = create root in
    bool "restart restores verified file" true (exists cache "file");
    S.close cache)
;;

let corrupt () =
  fixture (fun root ->
    let cache = create root in
    let h = get (put cache "file") in
    let path = Option.get (S.path cache h) in
    S.close cache;
    let out = open_out_bin path in
    output_string out "bad!";
    close_out out;
    let cache = create root in
    bool "corrupt file not ready" false (exists cache "file");
    S.close cache)
;;

let stale () =
  fixture (fun root ->
    let cache = create root in
    bool
      "stale publish rejected"
      true
      (S.publish
         cache
         ~asset:uuid
         ~version:(version "file")
         ~current:(fun () -> false)
         ~plaintext:"file"
       = Error S.Stale);
    bool "no stale record" false (exists cache "file");
    bool
      "checksum verified"
      true
      (S.publish
         cache
         ~asset:uuid
         ~version:(version "file")
         ~current:(fun () -> true)
         ~plaintext:"bad!"
       = Error S.Checksum_mismatch);
    bool "no corrupt record" false (exists cache "file");
    S.close cache)
;;

let leases () =
  fixture (fun root ->
    let cache = create ~budget:4L root in
    let h = get (put cache "file") in
    let renderer = Option.get (S.retain cache h) in
    S.release cache h;
    bool "live renderer pins file" true (put cache "next" = Error S.Full);
    bool "renderer path remains" true (Option.is_some (S.path cache renderer));
    S.release cache renderer;
    let _ = get (put cache "next") in
    bool "unpinned LRU evicted" false (exists cache "file");
    S.close cache)
;;

let filename_extension () =
  fixture (fun root ->
    let cache = create root in
    let handle = get (put cache "file") in
    let path = Option.get (S.path cache handle) in
    bool "downloaded file carries its type" true (Filename.check_suffix path ".png");
    S.release cache handle;
    S.close cache;
    let cache = create root in
    let handle = Option.get (lookup cache "file") in
    let path = Option.get (S.path cache handle) in
    bool "restart preserves typed filename" true (Filename.check_suffix path ".png");
    S.release cache handle;
    S.close cache)
;;

let legacy_bin_cleanup () =
  fixture (fun root ->
    let cache = create root in
    let handle = get (put cache "file") in
    let path = Option.get (S.path cache handle) in
    let legacy = Filename.chop_extension path ^ ".bin" in
    Sys.rename path legacy;
    S.release cache handle;
    S.close cache;
    let cache = create root in
    bool "untyped data file evicted" false (Sys.file_exists legacy);
    bool "manifest without typed data removed" false (exists cache "file");
    S.close cache)
;;

let isolation () =
  fixture (fun root ->
    let first = create root in
    let _ = get (put first "file") in
    let scope = { scope with account = { scope.account with user_id = "another" } } in
    let second = create ~scope root in
    bool "accounts isolated" false (exists second "file");
    let _ = get (put second "next") in
    let _ = get (S.delete first) in
    bool "deletion leaves other account" true (exists second "next");
    S.close second)
;;

let account_cleanup () =
  fixture (fun root ->
    let another_graph =
      { scope with graph_id = get (U.of_string "00000000-0000-4000-8000-000000000002") }
    in
    let other_user = { scope with account = { scope.account with user_id = "other" } } in
    let other_origin =
      { scope with
        account =
          { scope.account with
            managed_sync_origin = Uri.of_string "https://other.example"
          }
      }
    in
    List.iter
      (fun scope ->
         let cache = create ~scope root in
         ignore (get (put cache "file"));
         S.close cache)
      [ scope; another_graph; other_user; other_origin ];
    get (S.delete_account ~root ~account:scope.account);
    get (S.delete_account ~root ~account:scope.account);
    List.iter
      (fun scope ->
         let cache = create ~scope root in
         bool "all account graphs removed" false (exists cache "file");
         S.close cache)
      [ scope; another_graph ];
    List.iter
      (fun scope ->
         let cache = create ~scope root in
         bool "other namespace preserved" true (exists cache "file");
         S.close cache)
      [ other_user; other_origin ])
;;

let graph_cleanup () =
  fixture (fun root ->
    let another_graph =
      { scope with graph_id = get (U.of_string "00000000-0000-4000-8000-000000000002") }
    in
    List.iter
      (fun scope ->
         let cache = create ~scope root in
         ignore (get (put cache "file"));
         S.close cache)
      [ scope; another_graph ];
    get (S.delete_graph ~root ~account:scope.account ~graph_id:scope.graph_id);
    get (S.delete_graph ~root ~account:scope.account ~graph_id:scope.graph_id);
    let removed = create root in
    bool "selected graph removed" false (exists removed "file");
    S.close removed;
    let kept = create ~scope:another_graph root in
    bool "other graph retained" true (exists kept "file");
    S.close kept)
;;

let staging () =
  fixture (fun root ->
    let source_file = Filename.concat root "picker.bin" in
    let out = open_out_bin source_file in
    output_string out "source";
    close_out out;
    let cache = create ~budget:4L root in
    let staged =
      get
        (S.stage
           cache
           ~file_type:"bin"
           ~operation:uuid
           ~source_file
           ~pending_budget_bytes:8L)
    in
    bool
      "staging checksum"
      true
      (staged.checksum = Codec.checksum "source" && staged.size = 6L);
    Sys.remove source_file;
    let path = Option.get (S.staged_path cache ~file:staged.file) in
    let input = open_in_bin path in
    let bytes = really_input_string input 6 in
    close_in input;
    Alcotest.(check string) "picker is no longer needed" "source" bytes;
    S.release cache (get (put cache "file"));
    ignore (get (put cache "next"));
    bool "LRU does not evict pending import" true (Sys.file_exists path);
    let interrupted = path ^ ".part" in
    let out = open_out_bin interrupted in
    output_string out "partial";
    close_out out;
    S.close cache;
    let cache = create root in
    bool "interrupted staging discarded" false (Sys.file_exists interrupted);
    bool
      "pending source survives restart"
      true
      (Option.is_some (S.staged_path cache ~file:staged.file));
    bool "path traversal rejected" true (S.staged_path cache ~file:"../picker.bin" = None);
    get (S.release_staged cache ~file:staged.file);
    get (S.release_staged cache ~file:staged.file);
    bool
      "completion releases pending source"
      true
      (S.staged_path cache ~file:staged.file = None);
    S.close cache)
;;

let staging_bounds () =
  fixture (fun root ->
    let source_file = Filename.concat root "picker.bin" in
    let write bytes =
      let out = open_out_bin source_file in
      output_string out bytes;
      close_out out
    in
    write "large-file";
    let cache = create root in
    bool
      "oversize staging rejected"
      true
      (Result.is_error
         (S.stage
            cache
            ~file_type:"bin"
            ~operation:uuid
            ~source_file
            ~pending_budget_bytes:32L));
    write "file";
    let staged =
      get
        (S.stage
           cache
           ~file_type:"bin"
           ~operation:uuid
           ~source_file
           ~pending_budget_bytes:4L)
    in
    bool
      "duplicate cannot overwrite immutable staging"
      true
      (Result.is_error
         (S.stage
            cache
            ~file_type:"bin"
            ~operation:uuid
            ~source_file
            ~pending_budget_bytes:32L));
    let other = get (U.of_string "00000000-0000-4000-8000-000000000003") in
    bool
      "pending namespace has a separate budget"
      true
      (S.stage
         cache
         ~file_type:"bin"
         ~operation:other
         ~source_file
         ~pending_budget_bytes:4L
       = Error S.Full);
    bool
      "failed staging leaves original intact"
      true
      (Option.is_some (S.staged_path cache ~file:staged.file));
    let staged_path = Option.get (S.staged_path cache ~file:staged.file) in
    get (S.delete cache);
    bool "graph deletion removes staging" false (Sys.file_exists staged_path))
;;

let prune_orphans () =
  fixture (fun root ->
    let source_file = Filename.concat root "picker.bin" in
    Out_channel.with_open_bin source_file (fun output -> output_string output "file");
    let other = get (U.of_string "00000000-0000-4000-8000-000000000002") in
    let cache = create root in
    let staged operation =
      get
        (S.stage cache ~file_type:"bin" ~operation ~source_file ~pending_budget_bytes:16L)
    in
    let retained = staged uuid in
    let orphan = staged other in
    let retained_path = Option.get (S.staged_path cache ~file:retained.file) in
    let orphan_path = Option.get (S.staged_path cache ~file:orphan.file) in
    let stranger = Filename.concat (Filename.dirname orphan_path) "unrecognized.txt" in
    Out_channel.with_open_bin stranger (fun output -> output_string output "preserve");
    let link =
      Filename.concat
        (Filename.dirname orphan_path)
        "00000000-0000-4000-8000-000000000003.bin"
    in
    Unix.symlink source_file link;
    bool
      "failed ownership check fails closed"
      true
      (Result.is_error
         (S.prune_staged cache ~keep:(fun operation ->
            if U.equal operation uuid then Error "database unavailable" else Ok false)));
    bool
      "no partial cleanup on owner failure"
      true
      (Sys.file_exists retained_path && Sys.file_exists orphan_path);
    Alcotest.(check int)
      "only orphan removed"
      1
      (get (S.prune_staged cache ~keep:(fun operation -> Ok (U.equal operation uuid))));
    bool "durable staging retained" true (Sys.file_exists retained_path);
    bool "orphan gone" false (Sys.file_exists orphan_path);
    bool "unknown file retained" true (Sys.file_exists stranger);
    bool
      "symlink not followed or removed"
      true
      ((Unix.lstat link).st_kind = Unix.S_LNK && Sys.file_exists source_file);
    Alcotest.(check int)
      "repeat cleanup"
      0
      (get (S.prune_staged cache ~keep:(fun _ -> Ok true)));
    for index = 1 to 4096 do
      let path =
        Filename.concat (Filename.dirname orphan_path) ("unknown-" ^ string_of_int index)
      in
      Out_channel.with_open_bin path (fun _ -> ())
    done;
    bool
      "oversized directory fails closed"
      true
      (S.prune_staged cache ~keep:(fun _ -> Ok false) = Error S.Full);
    bool "capacity failure preserves staged data" true (Sys.file_exists retained_path);
    S.close cache;
    bool
      "closed scope refuses cleanup"
      true
      (Result.is_error (S.prune_staged cache ~keep:(fun _ -> Ok false))))
;;

let staged_preview () =
  fixture (fun root ->
    let source_file = Filename.concat root "picker.bin" in
    Out_channel.with_open_bin source_file (fun out -> output_string out "file");
    let cache = create root in
    let staged =
      get
        (S.stage
           cache
           ~file_type:"pdf"
           ~operation:uuid
           ~source_file
           ~pending_budget_bytes:8L)
    in
    let lease =
      match S.retain_staged cache ~file:staged.file with
      | Some lease -> lease
      | None -> Alcotest.fail "staged preview unavailable"
    in
    let preview = Option.get (S.path cache lease) in
    bool
      "native preview retains document extension"
      true
      (Filename.check_suffix preview ".pdf");
    List.iter
      (fun file_type ->
         bool
           "unsafe file types are rejected"
           true
           (Result.is_error
              (S.stage
                 cache
                 ~file_type
                 ~operation:uuid
                 ~source_file
                 ~pending_budget_bytes:8L)))
      [ ""; "../pdf"; "x.pdf"; String.make 33 'a' ];
    let second = Option.get (S.retain cache lease) in
    Alcotest.(check int)
      "orphan cleanup preserves active previews"
      0
      (get (S.prune_staged cache ~keep:(fun _ -> Ok false)));
    get (S.release_staged cache ~file:staged.file);
    bool "completion keeps preview bytes" true (Sys.file_exists preview);
    bool
      "completed staging refuses new preview"
      true
      (S.retain_staged cache ~file:staged.file = None);
    S.release cache lease;
    bool "one remaining lease keeps file" true (Sys.file_exists preview);
    S.release cache second;
    bool "last lease finishes cleanup" false (Sys.file_exists preview);
    S.release cache second;
    get (S.release_staged cache ~file:staged.file);
    let staged =
      get
        (S.stage
           cache
           ~file_type:"pdf"
           ~operation:uuid
           ~source_file
           ~pending_budget_bytes:8L)
    in
    let lease = Option.get (S.retain_staged cache ~file:staged.file) in
    get (S.release_staged cache ~file:staged.file);
    S.close cache;
    bool "close invalidates preview lease" true (S.path cache lease = None);
    bool "close finishes deferred cleanup" false (Sys.file_exists preview);
    let reopened = create root in
    let staged =
      get
        (S.stage
           reopened
           ~file_type:"pdf"
           ~operation:uuid
           ~source_file
           ~pending_budget_bytes:8L)
    in
    ignore (Option.get (S.retain_staged reopened ~file:staged.file));
    S.close reopened;
    bool "close preserves nonterminal staging" true (Sys.file_exists preview))
;;

let () =
  Alcotest.run
    "asset cache"
    [ ( "filesystem"
      , List.map
          (fun (n, f) -> Alcotest.test_case n `Quick f)
          [ "staged preview lifetime", staged_preview
          ; "orphan staging", prune_orphans
          ; "durable staging", staging
          ; "staging limits", staging_bounds
          ; "graph cleanup", graph_cleanup
          ; "account cleanup", account_cleanup
          ; "downloaded filename", filename_extension
          ; "legacy bin cleanup", legacy_bin_cleanup
          ; "restart", roundtrip
          ; "corruption", corrupt
          ; "atomic eligibility", stale
          ; "leases and budget", leases
          ; "account isolation", isolation
          ] )
    ]
;;
