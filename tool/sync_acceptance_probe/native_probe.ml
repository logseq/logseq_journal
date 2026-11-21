let () =
  let directory = Sys.getenv "JOURNAL_SYNC_NETWORK_PROBE_DIRECTORY" in
  let service =
    Logseq_db_worker_lui.Logseq_db_worker_lui_service.For_testing.service_with_network
      (Test_net.wrap ~directory)
  in
  Journal_bridge.register (Application.For_testing.app_with_service service)
;;
