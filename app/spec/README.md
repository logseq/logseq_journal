# App specification container

- [Journal execution flow](journal_execution_flow.mli): documentation-only
  walkthrough of the important App, Worker and Sync paths using existing spec
  types and pseudocode. It exports no interface and adds no virtual library.

Run `dune build @doc` and open `_build/default/_doc/_html/logseq_journal/index.html`.
The package homepage links to the execution guide and the coordination API.
The guide's `.mld` page is generated from its single `.mli` documentation comment;
edit only the `.mli` body.

Each area under this directory is an independent wrapped Dune virtual library.
Do not use recursive `include_subdirs` to merge future specifications into one
library. Add another area only when it has actual contracts and consumers.

- [worker_coordination](worker_coordination/README.md): the target App/Worker
  interaction boundary, exported as `logseq_journal.worker_coordination`.
  It covers typed queries/mutations/assets, real-client bootstrap, exclusive reply
  routing, observation and host lifecycle handoff. It does not specify all App UI
  or business algorithms. The App explicitly links the implementation for Copy
  and the graph runtime's one-shot metadata, admission and UUID reads; the remaining capabilities stay gated until their backend obligations
  and ownership transfers are implemented.
