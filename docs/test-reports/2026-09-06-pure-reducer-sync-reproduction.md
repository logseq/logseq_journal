# Pure Reducer Reproduction of the macOS Sync Failure

The M02 submitted-delete recovery defect is now reproduced by public-API-only OCaml tests in `logseq_sync/test/core_contract.ml`, registered under `sync recovery reproductions` in `logseq_sync/test/test_sync.ml`.

## Run

```sh
opam exec -- dune exec logseq_sync/test/test_sync.exe -- test 'sync recovery reproductions'
```

The group contains three cases:

| Index | Event sequence | Current result |
| --- | --- | --- |
| 0 | Submit delete, receive a deferred authoritative pull, receive batch acknowledgement, apply acceptance | PASS: the same deferred authoritative batch is resumed |
| 1 | Submit delete, disconnect, reconnect, receive pull and deferred outcome | FAIL: `authoritative defer owner mismatch` |
| 2 | Submit delete, create a fresh Core, restore the persisted Submitted descriptor, receive pull and deferred outcome | FAIL: `authoritative defer owner mismatch` |

Cases 1 and 2 assert the intended behavior: a durable submitted deletion must remain recoverable after the transport owner ends. They intentionally remain red until the production defect is fixed. The default suite includes these tests; `dune runtest` therefore currently exits nonzero.

## Test boundary

The tests drive `Core.initial`, `Core.step`, public completion events, `Core.state`, and emitted instructions. No implementation record fields, private module aliases, `#mod_use`, database, network, Eio runtime, wall clock, or macOS UI are involved. The targeted group ran in approximately 1 ms.

The fixture first proves that Core actually requests submission and emits the delete batch. It passes a Submitted descriptor back through `Outbox_transition_applied`. The fresh-Core scenario carries only this durable sync view across the simulated process boundary. It does not carry the old Core or its transport owner into restoration.

`Authoritative_batch_deferred` is supplied as the worker completion at the pure policy boundary. This tests Core's response to that valid outcome; it does not test the overlay's decision to defer or SQLite durability. Those behaviors were independently verified in the [earlier root-cause investigation](2026-09-06-sync-root-cause-investigation.md). The live-owner control demonstrates that the same completion is accepted while the owner still exists, and that acceptance resumes the original batch. Replaying the defer event from the same origin also checks reducer immutability and determinism.

## Why M01 is not reproduced by the current pure reducer

M01's retained windows and destructive acknowledgement are owned by `logseq_db_worker/lib/effect_runner/effect_runner.ml`. The pure reducer does not own or modify that list. Supplying an empty pull result to a pure test would reproduce a downstream symptom without executing the faulty cursor-retention algorithm.

M01 therefore still requires worker effect-runner coverage, as supplied by the earlier diagnostic reproduction. Moving that state into a pure reducer could enable a pure unit testcase, but would be an architectural change outside this test-only request. No M01 pure testcase is claimed here.

## Validation

- `dune build @all`: passed.
- Targeted reproduction group: one passing control, two expected defect failures.
- `dune runtest`: the sync executable ran 121 cases; 119 passed and the two new M02 recovery cases failed at the expected assertion. No other failures were reported.
- `ocamlformat --check`: passed for 228 project source/interface files.
- `git diff --check` and agent decision validation: passed.

Only tests and documentation were changed for this request. Production implementations, specs, dune files, live graphs, and existing pending mutations were left untouched.
