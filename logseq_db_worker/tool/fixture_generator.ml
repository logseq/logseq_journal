type mode =
  | Runtime_flow
  | Runtime_flow_with_persistence_failure

type generated =
  { support_root : string
  ; snapshot_token : Logseq_db_worker.Graph_types.Uuid.t
  ; graph_dir : string
  }

module Snapshot = Logseq_db_worker__Snapshot
module Adapter_fixture = Logseq_db_worker_test_support.Adapter_fixture

let create ~support_root ~mode =
  try
    if Filename.is_relative support_root
    then Error "support root must be absolute"
    else if not (Sys.file_exists support_root && Sys.is_directory support_root)
    then Error "support root must be an existing directory"
    else
      let support_root = Unix.realpath support_root in
      let sources = Filename.concat support_root "sources" in
      let source_graph_dir = Filename.concat sources "runtime-flow-source" in
      if Sys.file_exists source_graph_dir
      then Error "runtime flow source already exists"
      else (
        if Sys.file_exists sources
        then (
          if not (Sys.is_directory sources)
          then failwith "fixture sources path is not a directory")
        else Unix.mkdir sources 0o700;
        let source_graph_dir =
          Adapter_fixture.create_oracle_graph sources "runtime-flow-source"
        in
        (match mode with
         | Runtime_flow -> ()
         | Runtime_flow_with_persistence_failure ->
           Adapter_fixture.install_mutation_write_failure source_graph_dir);
        let catalog =
          match Snapshot.create_catalog ~application_support_directory:support_root with
          | Ok catalog -> catalog
          | Error _ -> failwith "unable to create snapshot catalog"
        in
        let snapshot_token =
          match Snapshot.create catalog ~source_graph_dir with
          | Ok token -> token
          | Error _ -> failwith "unable to publish runtime fixture snapshot"
        in
        let graph_dir =
          match Snapshot.resolve catalog snapshot_token with
          | Ok resolved -> resolved.graph_dir
          | Error _ -> failwith "unable to resolve published runtime fixture"
        in
        Ok { support_root; snapshot_token; graph_dir })
  with
  | Unix.Unix_error (error, operation, path) ->
    Error
      (Printf.sprintf
         "fixture filesystem operation failed: %s(%s): %s"
         operation
         path
         (Unix.error_message error))
  | Failure message -> Error message
;;

let to_yojson generated =
  `Assoc
    [ "formatVersion", `Int 1
    ; "supportRoot", `String generated.support_root
    ; ( "snapshotToken"
      , `String (Logseq_db_worker.Graph_types.Uuid.to_string generated.snapshot_token) )
    ; "graphDir", `String generated.graph_dir
    ]
;;
