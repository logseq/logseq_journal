let () =
  Alcotest.run "logseq sync protocol" [ "wire codec", Sync_protocol_contract.scenarios ]
;;
