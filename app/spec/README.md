# App specification container

Each area under this directory is an independent wrapped Dune virtual library.
Do not use recursive `include_subdirs` to merge future specifications into one
library. Add another area only when it has actual contracts and consumers.

- [worker_coordination](worker_coordination/README.md): the target App/Worker
  interaction boundary, exported as `logseq_journal.worker_coordination`.
  It covers typed queries/mutations/assets, real-client bootstrap, exclusive reply
  routing, observation and host lifecycle handoff. It does not specify all App UI
  or business algorithms. The App explicitly links the implementation for the Copy
  read path; the remaining capabilities stay gated until their backend obligations
  and ownership transfers are implemented.
