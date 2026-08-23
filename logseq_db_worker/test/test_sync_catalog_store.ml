module T = Logseq_db_worker_test_support.Test_support
module F = Logseq_db_worker_test_support.Adapter_fixture
module Catalog = Logseq_db_worker.Sync_catalog
module Store = Logseq_db_worker.Sync_catalog_store
module Uuid = Logseq_db_worker.Graph_types.Uuid

let graph_id = Uuid.of_string "10000000-0000-4000-8000-000000000001" |> Result.get_ok

let graph =
  Catalog.
    { graph_id
    ; name = "Notes"
    ; schema = { major = 65; minor = 33; exact = true }
    ; encrypted = false
    }
;;

let persists_and_scopes_cache_case () =
  F.with_temp_directory "logseq-sync-catalog-store-" (fun support ->
    let cache =
      Catalog.create_cache
        ~user_id:"user-1"
        ~base_url:"https://sync.example"
        ~graphs:[ graph ]
        ~selected_graph:(Some graph_id)
      |> fun cache -> Catalog.set_mirror_status cache graph_id Ready
    in
    (match Store.save ~application_support_directory:support cache with
     | Ok () -> ()
     | Error message -> T.fail "catalog cache save failed: %s" message);
    let loaded =
      match
        Store.load
          ~application_support_directory:support
          ~user_id:"user-1"
          ~base_url:"https://sync.example"
      with
      | Ok (Some cache) -> cache
      | Ok None -> T.fail "saved catalog cache was absent"
      | Error message -> T.fail "catalog cache load failed: %s" message
    in
    T.require
      (Catalog.selected_graph loaded = Some graph_id)
      "selected graph was not persisted";
    T.require
      (Catalog.mirror_status loaded graph_id = Ready)
      "mirror status was not persisted";
    T.require
      (Store.load
         ~application_support_directory:support
         ~user_id:"other-user"
         ~base_url:"https://sync.example"
       = Ok None)
      "catalog cache crossed account scope";
    T.require
      (Store.load
         ~application_support_directory:support
         ~user_id:"user-1"
         ~base_url:"https://other.example"
       = Ok None)
      "catalog cache crossed origin scope")
;;

let () =
  T.run
    "sync catalog store"
    [ T.case "persist scoped cache" persists_and_scopes_cache_case ]
;;
