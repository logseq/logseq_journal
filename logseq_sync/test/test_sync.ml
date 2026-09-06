let () =
  Alcotest.run
    "logseq sync"
    [ "sync protocol", Sync_protocol_contract.scenarios
    ; ( "pure core"
      , Core_contract.scenarios @ [ Local_restore_failure_reconciliation.scenario ] )
    ; "sync recovery reproductions", Core_contract.sync_recovery_reproductions
    ; "effect runner", Runner_contract.scenarios
    ; "transport", Transport_contract.scenarios
    ]
;;
