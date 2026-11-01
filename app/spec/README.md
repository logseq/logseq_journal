# App specification container

Each specification area lives in its own subdirectory with its own wrapped Dune
virtual library. This directory does not define a combined library or recursively
include future specification modules.

The current area is [Worker coordination](worker_coordination/README.md):

- Source: `app/spec/worker_coordination/`
- Library: `journal_worker_coordination`
- Public name: `logseq_journal.worker_coordination`
- Modules: `Worker_api`, `Worker_coordinator`, `Worker_effect_runner`

Other areas are added only when they have actual contracts. No placeholder UI,
Timeline, Capture, implementation or adapter libraries are created here.
