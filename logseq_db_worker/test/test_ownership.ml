module T = Logseq_db_worker_test_support.Test_support
module Ownership = Logseq_db_worker__Ownership
module Backup = Logseq_db_worker__Backup
module Snapshot = Logseq_db_worker__Snapshot
module Graph_types = Logseq_db_worker.Graph_types
module Derived_sidecars = Logseq_db_worker__Derived_sidecars

let with_graph f =
  let path = Filename.temp_file "logseq-db-worker-owner-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  f path

let acquire target graph =
  match Ownership.acquire ~target ~graph_dir:graph with
  | Ok owner -> owner
  | Error _ -> T.fail "ownership acquisition failed"

let write_sentinel graph fields =
  Yojson.Safe.to_file (Filename.concat graph "db-worker.lock") (`Assoc fields)

let stale_sentinel graph =
  [ "repo", `String (Filename.basename graph)
  ; "pid", `Int 2_147_483_647
  ; "lock-id", `String "22222222-2222-4222-8222-222222222222"
  ; "owner-source", `String "unknown"
  ; "owner-generation", `String "33333333-3333-4333-8333-333333333333"
  ; "owner-protocol", `Int 1
  ]

let owner_database graph =
  Filename.concat graph ".logseq-db-worker.owner.sqlite"

let create_database graph =
  let db = Sqlite3.db_open (Filename.concat graph "db.sqlite") in
  Sqlite3.Rc.check (Sqlite3.exec db "CREATE TABLE marker(value TEXT NOT NULL)");
  Sqlite3.Rc.check (Sqlite3.exec db "INSERT INTO marker VALUES ('native-backup')");
  T.require (Sqlite3.db_close db) "unable to close native source database"
;;

let create_catalog () =
  let support = Filename.temp_file "logseq-db-worker-native-backup-" "" in
  Sys.remove support;
  Unix.mkdir support 0o700;
  match Snapshot.create_catalog ~application_support_directory:support with
  | Ok catalog -> catalog
  | Error _ -> T.fail "native backup catalog creation failed"
;;

let resolve_snapshot catalog token =
  match Snapshot.resolve catalog token with
  | Ok resolved -> resolved.Snapshot.graph_dir
  | Error _ -> T.fail "native recovery snapshot did not resolve"
;;

let read_marker graph =
  let db = Sqlite3.db_open ~mode:`READONLY (Filename.concat graph "db.sqlite") in
  let marker = ref None in
  Sqlite3.Rc.check
    (Sqlite3.exec db "SELECT value FROM marker" ~cb:(fun row _ -> marker := row.(0)));
  T.require (Sqlite3.db_close db) "unable to close native recovery database";
  !marker
;;

let manifest_owner_generation snapshot_dir =
  match Yojson.Safe.from_file (Filename.concat snapshot_dir "manifest.json") with
  | `Assoc document ->
    (match List.assoc_opt "payload" document with
     | Some (`Assoc payload) -> List.assoc_opt "ownerGeneration" payload
     | _ -> None)
  | _ -> None
;;

let derived_sidecar_marker graph =
  Filename.concat graph ".logseq-db-worker.derived-sidecars.json"
;;

let () =
  T.run
    "ownership"
    [ T.case "snapshot owner acquires lock and sentinel" (fun () ->
        with_graph (fun graph ->
          let owner = acquire Ownership.Snapshot_target graph in
          T.require (Sys.file_exists (Filename.concat graph "db-worker.lock")) "sentinel missing";
          T.require (String.length (Ownership.generation owner) = 36) "generation missing";
          (match Ownership.revalidate owner with
           | Ok () -> ()
           | Error _ -> T.fail "owner did not revalidate");
          match Ownership.release owner with
          | Ok () -> ()
          | Error _ -> T.fail "release failed"))
    ; T.case "native owner acquires coordinated generation lock" (fun () ->
        with_graph (fun graph ->
          let owner = acquire Ownership.Native_target graph in
          let json = Yojson.Safe.from_file (Filename.concat graph "db-worker.lock") in
          (match json with
           | `Assoc fields ->
               T.require (List.assoc_opt "owner-protocol" fields = Some (`Int 1)) "protocol missing";
               T.require
                 (List.assoc_opt "owner-generation" fields
                  = Some (`String (Ownership.generation owner)))
                 "generation mismatch"
           | _ -> T.fail "invalid sentinel");
          ignore (Ownership.release owner)))
    ; T.case "native owner holds the shared SQLite owner transaction" (fun () ->
        with_graph (fun graph ->
          let owner = acquire Ownership.Native_target graph in
          let contender = Sqlite3.db_open (owner_database graph) in
          Sqlite3.Rc.check (Sqlite3.exec contender "PRAGMA busy_timeout = 0");
          let result = Sqlite3.exec contender "BEGIN IMMEDIATE" in
          T.require
            (result = Sqlite3.Rc.BUSY || result = Sqlite3.Rc.LOCKED)
            "native owner did not hold the cross-runtime SQLite transaction";
          T.require (Sqlite3.db_close contender) "unable to close ownership contender";
          ignore (Ownership.release owner)))
    ; T.case "second writer is refused" (fun () ->
        with_graph (fun graph ->
          let owner = acquire Ownership.Native_target graph in
          (match Ownership.acquire ~target:Ownership.Native_target ~graph_dir:graph with
           | Error Ownership.Already_owned -> ()
           | _ -> T.fail "second writer acquired graph");
          ignore (Ownership.release owner)))
    ; T.case "replacement lock survives prior owner release" (fun () ->
        with_graph (fun graph ->
          let owner = acquire Ownership.Native_target graph in
          let path = Filename.concat graph "db-worker.lock" in
          let replacement =
            `Assoc
              [ "repo", `String (Filename.basename graph)
              ; "pid", `Int (Unix.getpid ())
              ; "lock-id", `String "22222222-2222-4222-8222-222222222222"
              ; "owner-source", `String "unknown"
              ; "owner-generation", `String "33333333-3333-4333-8333-333333333333"
              ; "owner-protocol", `Int 1
              ]
          in
          Yojson.Safe.to_file path replacement;
          (match Ownership.release owner with
           | Error Ownership.Identity_changed -> ()
           | _ -> T.fail "prior owner release did not reject replacement");
          T.require (Sys.file_exists path) "replacement sentinel was removed"))
    ; T.case "native owner rejects a non-positive sentinel PID" (fun () ->
        with_graph (fun graph ->
          write_sentinel
            graph
            [ "repo", `String (Filename.basename graph)
            ; "pid", `Int 0
            ; "lock-id", `String "22222222-2222-4222-8222-222222222222"
            ; "owner-source", `String "unknown"
            ; "owner-generation", `String "33333333-3333-4333-8333-333333333333"
            ; "owner-protocol", `Int 1
            ];
          match Ownership.acquire ~target:Ownership.Native_target ~graph_dir:graph with
          | Error Ownership.Invalid_sentinel -> ()
          | _ -> T.fail "a non-positive lock PID was not rejected as malformed"))
    ; T.case "native owner cleans a provably stale coordinated sentinel" (fun () ->
        with_graph (fun graph ->
          write_sentinel
            graph
            [ "repo", `String (Filename.basename graph)
            ; "pid", `Int 2_147_483_647
            ; "lock-id", `String "22222222-2222-4222-8222-222222222222"
            ; "owner-source", `String "unknown"
            ; "owner-generation", `String "33333333-3333-4333-8333-333333333333"
            ; "owner-protocol", `Int 1
            ];
          let owner = acquire Ownership.Native_target graph in
          let persisted = Yojson.Safe.from_file (Filename.concat graph "db-worker.lock") in
          T.require
            (persisted
             <> `Assoc
                  [ "repo", `String (Filename.basename graph)
                  ; "pid", `Int 2_147_483_647
                  ; "lock-id", `String "22222222-2222-4222-8222-222222222222"
                  ; "owner-source", `String "unknown"
                  ; "owner-generation", `String "33333333-3333-4333-8333-333333333333"
                  ; "owner-protocol", `Int 1
                  ])
            "provably stale sentinel was retained";
          ignore (Ownership.release owner)))
    ; T.case "synced owner reclaims a valid dead-PID sentinel" (fun () ->
        with_graph (fun graph ->
          create_database graph;
          write_sentinel graph (stale_sentinel graph);
          let owner = acquire Ownership.Synced_target graph in
          Fun.protect
            ~finally:(fun () -> ignore (Ownership.release owner))
            (fun () ->
               T.require
                 (read_marker graph = Some "native-backup")
                 "stale synced sentinel recovery changed mirror contents";
               T.require
                 (Ownership.revalidate owner = Ok ())
                 "reclaimed synced ownership did not revalidate")))
    ; T.case "synced owner preserves mirror data across repeated crash recovery" (fun () ->
        with_graph (fun graph ->
          create_database graph;
          for _ = 1 to 3 do
            write_sentinel graph (stale_sentinel graph);
            let owner = acquire Ownership.Synced_target graph in
            T.require
              (read_marker graph = Some "native-backup")
              "repeated synced recovery changed mirror contents";
            ignore (Ownership.release owner)
          done))
    ; T.case "snapshot owner keeps a dead-PID sentinel ambiguous" (fun () ->
        with_graph (fun graph ->
          write_sentinel graph (stale_sentinel graph);
          match Ownership.acquire ~target:Ownership.Snapshot_target ~graph_dir:graph with
          | Error Ownership.Ambiguous_stale_lock -> ()
          | _ -> T.fail "snapshot ownership unexpectedly reclaimed a stale sentinel"))
    ; T.case "native backup uses SQLite backup and binds owner generation" (fun () ->
        with_graph (fun graph ->
          create_database graph;
          let catalog = create_catalog () in
          let owner = acquire Ownership.Native_target graph in
          Fun.protect
            ~finally:(fun () -> ignore (Ownership.release owner))
            (fun () ->
               let backup = Backup.create_native ~catalog ~source_graph_dir:graph ~owner in
               let first =
                 match Backup.ensure backup with
                 | Ok token -> token
                 | Error _ -> T.fail "native recovery backup failed"
               in
               let second =
                 match Backup.ensure backup with
                 | Ok token -> token
                 | Error _ -> T.fail "native recovery backup reuse failed"
               in
               T.require
                 (Graph_types.Uuid.equal first second)
                 "native backup created more than one recovery token";
               let recovery_graph = resolve_snapshot catalog first in
               T.require
                 (read_marker recovery_graph = Some "native-backup")
                 "native SQLite backup lost committed data";
               T.require
                 (manifest_owner_generation recovery_graph
                  = Some (`String (Ownership.generation owner)))
                 "native backup manifest is not bound to the owner generation")))
    ; T.case "native backup rejects owner identity replacement before copy" (fun () ->
        with_graph (fun graph ->
          create_database graph;
          let catalog = create_catalog () in
          let owner = acquire Ownership.Native_target graph in
          let backup = Backup.create_native ~catalog ~source_graph_dir:graph ~owner in
          write_sentinel
            graph
            [ "repo", `String (Filename.basename graph)
            ; "pid", `Int (Unix.getpid ())
            ; "lock-id", `String "22222222-2222-4222-8222-222222222222"
            ; "owner-source", `String "unknown"
            ; "owner-generation", `String "33333333-3333-4333-8333-333333333333"
            ; "owner-protocol", `Int 1
            ];
          (match Backup.ensure backup with
           | Error (Backup.Ownership_error Ownership.Identity_changed) -> ()
           | _ -> T.fail "native backup accepted a replacement owner identity");
          T.require
            (Backup.recovery_token backup = None)
            "failed native backup published a usable recovery token";
          ignore (Ownership.release owner)))
    ; T.case "native backup rejects a released owner" (fun () ->
        with_graph (fun graph ->
          create_database graph;
          let catalog = create_catalog () in
          let owner = acquire Ownership.Native_target graph in
          let backup = Backup.create_native ~catalog ~source_graph_dir:graph ~owner in
          ignore (Ownership.release owner);
          match Backup.ensure backup with
          | Error (Backup.Ownership_error Ownership.Not_owner) -> ()
          | _ -> T.fail "native backup accepted a released owner"))
    ; T.case "native backup rejects an owner from another graph" (fun () ->
        with_graph (fun owned_graph ->
          with_graph (fun source_graph ->
            create_database source_graph;
            let catalog = create_catalog () in
            let owner = acquire Ownership.Native_target owned_graph in
            Fun.protect
              ~finally:(fun () -> ignore (Ownership.release owner))
              (fun () ->
                 let backup =
                   Backup.create_native
                     ~catalog
                     ~source_graph_dir:source_graph
                     ~owner
                 in
                 match Backup.ensure backup with
                 | Error (Backup.Ownership_error Ownership.Identity_changed) -> ()
                 | _ -> T.fail "native backup accepted an owner from another graph"))))
    ; T.case "native owner persists independent FTS and vector invalidation marker" (fun () ->
        with_graph (fun graph ->
          let owner = acquire Ownership.Native_target graph in
          Fun.protect
            ~finally:(fun () -> ignore (Ownership.release owner))
            (fun () ->
               let sidecars =
                 match Derived_sidecars.create ~graph_dir:graph ~owner with
                 | Ok sidecars -> sidecars
                 | Error _ -> T.fail "derived sidecar state creation failed"
               in
               let invalidated =
                 match Derived_sidecars.invalidate sidecars with
                 | Ok status -> status
                 | Error _ -> T.fail "derived sidecar invalidation failed"
               in
               let fts =
                 match invalidated.fts_generation with
                 | Some generation -> generation
                 | None -> T.fail "FTS invalidation generation missing"
               in
               let vector =
                 match invalidated.vector_generation with
                 | Some generation -> generation
                 | None -> T.fail "vector invalidation generation missing"
               in
               T.require (not (String.equal fts vector)) "sidecar generations are not independent";
               T.require (String.length fts = 36) "invalid FTS generation";
               T.require (String.length vector = 36) "invalid vector generation";
               T.require
                 (Derived_sidecars.status sidecars = Ok invalidated)
                 "persisted sidecar marker did not round-trip";
               match Yojson.Safe.from_file (derived_sidecar_marker graph) with
               | `Assoc fields ->
                 T.require (List.length fields = 3) "sidecar marker has unexpected fields";
                 T.require
                   (List.assoc_opt "formatVersion" fields = Some (`Int 1))
                   "sidecar marker version mismatch";
                 T.require
                   (List.assoc_opt "ftsRequiredGeneration" fields = Some (`String fts))
                   "sidecar marker FTS generation mismatch";
                 T.require
                   (List.assoc_opt "vectorRequiredGeneration" fields = Some (`String vector))
                   "sidecar marker vector generation mismatch"
               | _ -> T.fail "invalid sidecar marker JSON")))
    ; T.case "native invalidation rejects and preserves a malformed marker" (fun () ->
        with_graph (fun graph ->
          let owner = acquire Ownership.Native_target graph in
          Fun.protect
            ~finally:(fun () -> ignore (Ownership.release owner))
            (fun () ->
               let sidecars =
                 match Derived_sidecars.create ~graph_dir:graph ~owner with
                 | Ok sidecars -> sidecars
                 | Error _ -> T.fail "derived sidecar state creation failed"
               in
               Yojson.Safe.to_file (derived_sidecar_marker graph) (`Assoc []);
               (match Derived_sidecars.invalidate sidecars with
                | Error Derived_sidecars.Invalid_marker -> ()
                | _ -> T.fail "malformed sidecar marker was overwritten");
               T.require
                 (Yojson.Safe.from_file (derived_sidecar_marker graph) = `Assoc [])
                 "malformed sidecar marker was not preserved")))
    ; T.case "native invalidation rejects a released owner" (fun () ->
        with_graph (fun graph ->
          let owner = acquire Ownership.Native_target graph in
          let sidecars =
            match Derived_sidecars.create ~graph_dir:graph ~owner with
            | Ok sidecars -> sidecars
            | Error _ -> T.fail "derived sidecar state creation failed"
          in
          ignore (Ownership.release owner);
          match Derived_sidecars.invalidate sidecars with
          | Error (Derived_sidecars.Ownership_error Ownership.Not_owner) -> ()
          | _ -> T.fail "released owner invalidated derived sidecars"))
    ; T.case "native sidecar state rejects an owner from another graph" (fun () ->
        with_graph (fun owned_graph ->
          with_graph (fun target_graph ->
            let owner = acquire Ownership.Native_target owned_graph in
            Fun.protect
              ~finally:(fun () -> ignore (Ownership.release owner))
              (fun () ->
                 match Derived_sidecars.create ~graph_dir:target_graph ~owner with
                 | Error (Derived_sidecars.Ownership_error Ownership.Identity_changed) -> ()
                 | _ -> T.fail "sidecar state accepted an owner from another graph"))))
    ; T.case "identity tampering is detected" (fun () ->
        with_graph (fun graph ->
          let owner = acquire Ownership.Snapshot_target graph in
          Yojson.Safe.to_file (Filename.concat graph "db-worker.lock") (`Assoc []);
          match Ownership.revalidate owner with
          | Error Ownership.Identity_changed -> ()
          | _ -> T.fail "identity tampering accepted"))
    ; T.case "unexpected malformed sentinel fails closed" (fun () ->
        with_graph (fun graph ->
          Yojson.Safe.to_file (Filename.concat graph "db-worker.lock") (`Assoc []);
          match Ownership.acquire ~target:Ownership.Snapshot_target ~graph_dir:graph with
          | Error Ownership.Invalid_sentinel -> ()
          | _ -> T.fail "malformed sentinel accepted"))
    ]
