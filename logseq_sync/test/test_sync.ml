let () =
  Alcotest.run
    "logseq sync"
    [ "sync protocol", Sync_protocol_contract.scenarios
    ; "pure core", Core_contract.scenarios
    ; "effect runner", Runner_contract.scenarios
    ]
;;
