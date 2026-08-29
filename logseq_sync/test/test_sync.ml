let () =
  Alcotest.run
    "logseq sync"
    [ "pure core", Core_contract.scenarios; "effect runner", Runner_contract.scenarios ]
;;
