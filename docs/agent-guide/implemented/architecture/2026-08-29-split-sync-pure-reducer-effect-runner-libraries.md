# Split Sync Pure Reducer Effect Runner Libraries

## Problem

`logseq_sync` currently combines three public virtual modules in one library:
`Core`, `Sync_protocol`, and `Effect_runner`. Their dependency requirements are
not symmetric:

- `Sync_protocol` is a pure application-level message contract and JSON codec;
- `Core` is a pure reducer that consumes and produces those protocol values; and
- `Effect_runner` depends on `Core` and `Sync_protocol` while also requiring Eio,
  TLS, HTTP, WebSocket, filesystem, storage, and platform implementations.

The single virtual-library boundary forces its default implementation to provide
all three modules together. The pure reducer implementation therefore cannot
depend directly on the public `Logseq_sync.Sync_protocol` module without creating
a library cycle: the public virtual library selects an implementation that itself
depends on the reducer helper library.

The current implementation avoids that cycle by defining a second nominal
protocol representation in
`Logseq_sync_pure_core.Sync_protocol_core`. The standalone public
`logseq_sync/spec/sync_protocol.mli` is now self-contained and remains the public
source of truth, but `Pure_core` operates on the lower representation. The
`Core` implementation consequently contains exhaustive conversions such as
`export_client_message`, `import_server_message`, and
`import_rejection_reason` to cross the nominal type boundary.

Those conversions contain no domain policy and exist only because of the library
layout. Every protocol addition must be repeated in the public interface, lower
ADT, codec implementation, and conversion functions. Compiler exhaustiveness
helps detect omissions, but it does not remove the duplicated representation or
the maintenance cost.

The current layout also weakens the compile-time purity boundary. The separate
`logseq_sync_pure_core` helper library is pure, but the installed public
`logseq_sync` contract itself includes the effect-runner interface and therefore
declares dependencies such as Eio and X509 that are irrelevant to protocol and
reducer consumers.

## Proposal

Split the current public spec and implementation into a lower pure-reducer
library and an upper effect-runner library. The dependency direction is:

```text
Sync_protocol -> Core -> Effect_runner
```

The pure-reducer public library owns the canonical `Sync_protocol` and `Core`
virtual modules. Its default implementation provides both modules in the same
pure implementation library. `Core` can therefore use the sibling public
`Sync_protocol` module directly, with one nominal client-message type, one
nominal server-message type, and one codec-error type.

The effect-runner public library owns only the `Effect_runner` virtual module. It
depends on the installed pure-reducer library and uses its public `Core` and
`Sync_protocol` modules. Its default implementation owns all Eio, transport,
storage, TLS, and platform dependencies.

The expected source layout is:

```text
logseq_sync/
├── spec/
│   ├── pure_reducer/
│   │   ├── dune
│   │   ├── core.mli
│   │   └── sync_protocol.mli
│   └── effect_runner/
│       ├── dune
│       └── effect_runner.mli
└── lib/
    ├── pure_reducer/
    │   ├── dune
    │   ├── core.ml
    │   ├── sync_protocol.ml
    │   ├── pure_tx.ml
    │   ├── checksum.ml
    │   └── checksum.mli
    └── effect_runner/
        ├── dune
        ├── effect_runner.ml
        ├── protocol/
        │   ├── catalog.ml
        │   ├── catalog.mli
        │   ├── e2ee.ml
        │   └── e2ee.mli
        ├── storage/
        │   ├── bootstrap.ml
        │   └── bootstrap.mli
        ├── eio/
        │   ├── http.ml
        │   ├── http.mli
        │   ├── http_eio.ml
        │   ├── http_eio.mli
        │   ├── websocket_eio.ml
        │   └── websocket_eio.mli
        └── platform/
            ├── artifact_decoder.ml
            ├── artifact_decoder.mli
            ├── platform_crypto.ml
            ├── platform_crypto.mli
            ├── platform_crypto_stubs.c
            └── gzip_stubs.c
```

Name the lower public library `logseq_sync_pure_reducer`, installed as
`logseq_sync.pure_reducer`. Its public module paths become:

```ocaml
Logseq_sync_pure_reducer.Sync_protocol
Logseq_sync_pure_reducer.Core
```

Its virtual-library shape is approximately:

```lisp
(library
 (name logseq_sync_pure_reducer)
 (public_name logseq_sync.pure_reducer)
 (modules core sync_protocol)
 (virtual_modules core sync_protocol)
 (default_implementation logseq_sync_pure_reducer_impl)
 (libraries
  datascript_ocaml
  logseq_db_types
  uri))
```

The pure implementation library contains the actual `Core` and `Sync_protocol`
implementations:

```lisp
(library
 (name logseq_sync_pure_reducer_impl)
 (public_name logseq_sync.pure_reducer.impl)
 (implements logseq_sync_pure_reducer)
 (modules checksum core pure_tx sync_protocol)
 (private_modules checksum pure_tx)
 (libraries
  datascript_ocaml
  logseq_db_types
  melange-transit-native
  uri
  uutf
  yojson))
```

Move the current reducer implementation from `pure_core.ml` into the virtual
module implementation `core.ml`. It should directly construct and match
`Sync_protocol.Client.message`, `Sync_protocol.Server.message`, and
`Sync_protocol.codec_error`. Remove the `Pure_core.Make` adapter and all
public/internal protocol conversion functions.

Move the codec implementation from `sync_protocol_core.ml` into
`sync_protocol.ml`. That module directly implements the independent public
`sync_protocol.mli`; it must not introduce a second protocol ADT module or an
include-based alias to one. Delete `sync_protocol_core.ml` rather than retaining
it as a compatibility or helper path.

Define the effect-runner spec as a second virtual library that depends on
`logseq_sync.pure_reducer`:

```lisp
(library
 (name logseq_sync_effect_runner)
 (public_name logseq_sync.effect_runner)
 (modules effect_runner)
 (virtual_modules effect_runner)
 (default_implementation logseq_sync_effect_runner_impl)
 (libraries
  eio
  logseq_sync.pure_reducer
  uri
  x509))
```

The effect implementation library contains `effect_runner.ml` and its private
transport, HTTP, storage, catalog, E2EE, and platform modules. It is the only
sync library layer allowed to depend on Eio network implementations, TLS,
filesystem operations, `logseq_db_storage`, or native platform stubs.

Raw WebSocket strings remain confined to this upper layer. Inbound frames are
decoded through
`Logseq_sync_pure_reducer.Sync_protocol.decode_server_message` before being
posted as `Logseq_sync_pure_reducer.Core.event`; outbound typed client messages
are encoded immediately before transport submission.

Update worker and test imports to use the selected effect-runner public module
path directly. Do not add deprecated module aliases or compatibility libraries.

## Decision

Create two installed public virtual libraries. Name the lower library
`logseq_sync_pure_reducer`, installed as `logseq_sync.pure_reducer`, and expose:

```ocaml
Logseq_sync_pure_reducer.Sync_protocol
Logseq_sync_pure_reducer.Core
```

Name the upper library `logseq_sync_effect_runner`, installed as
`logseq_sync.effect_runner`, and expose:

```ocaml
Logseq_sync_effect_runner.Effect_runner
```

Keep `Effect_runner` public. Its dependency-injection interface is a tested
integration boundary and remains useful outside `logseq_db_worker`, while its
implementation and private helper modules stay in the effect-runner
implementation library.

Delete the combined `Logseq_sync.Core`, `Logseq_sync.Sync_protocol`, and
`Logseq_sync.Effect_runner` paths. Update every repository caller atomically to
the two new namespaces. Do not add an umbrella facade, deprecated module alias,
fallback library, or compatibility package.

Make `logseq_sync/spec/pure_reducer/sync_protocol.mli` the source of truth for
the single protocol ADT. Compile `Core` and `Sync_protocol` in the same pure
virtual-library implementation so the reducer uses the canonical public types
directly. Remove the lower duplicate ADT, functor adapter, and all protocol
conversion functions.

## Alternatives considered

### Keep the current typed conversion adapter

The current `Pure_core.Make` adapter preserves a pure helper library and keeps
the public `.mli` independent from its implementation. It is behaviorally safe,
but retains two nominal ADTs and requires exhaustive field-by-field conversions
that carry no synchronization policy. It treats the dependency-cycle symptom
rather than changing the dependency graph.

### Extract a third standalone protocol library

A dependency-neutral protocol library could be shared by the reducer and effect
runner. This removes the cycle, but adds another public namespace and makes it
harder for `logseq_sync/spec/pure_reducer/sync_protocol.mli` to remain the direct
source of `Logseq_sync_pure_reducer.Sync_protocol` without another alias layer.
The proposed two-layer split is sufficient because the protocol is already part
of the pure reducer's public contract.

### Keep one public virtual library and split only private helper libraries

Moving implementation files without splitting the public virtual library leaves
`Core`, `Sync_protocol`, and `Effect_runner` under one implementation selection.
The lower reducer helper still cannot depend on the public protocol module, so
the duplicate ADT or an equivalent functor adapter remains necessary.

### Add an umbrella facade preserving the `Logseq_sync` namespace

A third library could re-export the pure reducer and effect runner through module
aliases. That retains the current combined namespace but adds another dependency
layer and public package surface. It is not part of the two-layer proposal. If
the combined namespace is required, it must use true module aliases so protocol
type identity is preserved; duplicated signatures or compatibility wrappers are
not acceptable.

### Put effect-only helpers in a separate utility library

`Catalog`, `E2ee`, and `Bootstrap` contain some pure functions, but they are used
only by effect execution and platform adapters. Extracting them would create a
third implementation library without helping protocol type identity. Keep them
private to the effect-runner implementation unless another independent consumer
appears.

## Acceptance criteria

- `logseq_sync/spec` contains separate `pure_reducer` and `effect_runner` library
  roots, and the dependency graph is effect runner to pure reducer only.
- The lower installed `logseq_sync.pure_reducer` library exposes
  `Logseq_sync_pure_reducer.Sync_protocol` and
  `Logseq_sync_pure_reducer.Core` without depending on Eio, X509, TLS, HTTP,
  storage, Unix, or platform libraries.
- `sync_protocol.mli` directly declares the complete protocol ADT and contains no
  reference to an implementation module.
- `core.ml` directly uses `Sync_protocol.Client.message`,
  `Sync_protocol.Server.message`, and `Sync_protocol.codec_error`.
- `sync_protocol.ml` directly implements the public interface and owns the codec;
  there is no `Sync_protocol_core` module or second nominal protocol ADT.
- `pure_core.ml`, `sync_protocol_core.ml`, `Core_protocol`, `Protocol_adapter`,
  `export_client_message`, `import_server_message`, and
  `import_rejection_reason` are removed.
- The pure reducer library contains no Eio, Unix, filesystem, mutable transport,
  TLS, HTTP, storage-engine, or platform dependencies.
- The effect-runner spec and implementation depend on
  `logseq_sync.pure_reducer` and use its exact `Core` and `Sync_protocol` types
  without conversion functions.
- Raw WebSocket payload strings exist only at the effect-runner transport codec
  boundary.
- Every worker, test, and package dependency uses the selected new effect-runner
  public path `Logseq_sync_effect_runner.Effect_runner` directly. Pure consumers
  use `Logseq_sync_pure_reducer.Core` and
  `Logseq_sync_pure_reducer.Sync_protocol`; no compatibility alias or retired
  `Logseq_sync.*` path is retained.
- Public protocol contract tests, reducer tests, effect-runner tests, source
  boundary tests, install-manifest checks, `dune build @all`, `dune runtest`,
  `ocamlformat --check`, `git diff --check`, and `spec-dev-tool check --all` pass.

## Implementation evidence

- `logseq_sync/spec/pure_reducer/dune` defines the public virtual library
  `logseq_sync.pure_reducer`, and `logseq_sync/spec/effect_runner/dune` defines
  the independently public virtual library `logseq_sync.effect_runner` with a
  one-way dependency on the pure reducer.
- `logseq_sync/spec/pure_reducer/sync_protocol.mli` directly declares the
  canonical client and server message ADTs, structured codec errors, and all
  four codec operations. It contains no implementation-module reference.
- `logseq_sync/lib/pure_reducer/sync_protocol.ml` directly implements that
  interface, while `logseq_sync/lib/pure_reducer/core.ml` directly consumes and
  produces its types. The old `Sync_protocol_core`, `Pure_core.Make`, adapter
  modules, and field-by-field conversion functions are absent.
- `logseq_sync/lib/effect_runner/effect_runner.ml` uses
  `Logseq_sync_pure_reducer.Core` and
  `Logseq_sync_pure_reducer.Sync_protocol` directly. Its Dune library owns the
  transport, storage, TLS, Eio, and platform dependencies, and its helper CMIs
  remain private.
- Application, worker, and test callers use
  `Logseq_sync_pure_reducer.Core`,
  `Logseq_sync_pure_reducer.Sync_protocol`, and
  `Logseq_sync_effect_runner.Effect_runner`. Source-boundary checks forbid the
  retired combined `Logseq_sync.*` paths and the old flat source layout.
- The generated install manifest contains the public pure-reducer `Core` and
  `Sync_protocol` interfaces and the public effect-runner `Effect_runner`
  interface. It contains no combined `logseq_sync.cmi` or retired
  `Logseq_sync.*` public module interface.
- Protocol, reducer, effect-runner, source-boundary, and install-manifest tests
  pass. The complete `dune build @all` and `dune runtest` gates pass, as do
  `ocamlformat --check` for all changed OCaml sources and `git diff --check`.

## Consequences

The installed sync API now has two explicit dependency levels. Pure consumers
link `logseq_sync.pure_reducer` without acquiring effect-runner dependencies.
Transport owners link the public `logseq_sync.effect_runner` integration
boundary and receive the pure reducer through its declared dependency.

There is one nominal application-level sync protocol representation. The public
`sync_protocol.mli`, codec implementation, reducer, effect runner, tests, and
callers all use the same `Client.message`, `Server.message`, and `codec_error`
types. A protocol constructor change therefore produces direct exhaustiveness
or interface failures instead of requiring a parallel ADT and conversion layer.

The combined `Logseq_sync` namespace is removed immediately. Existing callers
must use the new pure-reducer or effect-runner namespace; there is no facade,
deprecated alias, fallback package, or migration path that can hide an obsolete
dependency.

Raw WebSocket frames and infrastructure dependencies remain in the effect-runner
implementation. The pure reducer receives decoded messages and returns typed
client messages, so the library graph and the runtime protocol boundary now
express the same ownership direction.

## Risks

- Splitting the virtual library changes how Dune resolves default
  implementations. A consumer that links only the effect-runner interface must
  still receive compatible defaults for both virtual libraries.
- Moving `Core` and `Sync_protocol` into the same implementation library removes
  the separately installed `logseq_sync.impl.pure_core` boundary. Source tests
  must enforce purity through the new pure-reducer implementation dependency
  closure.
- The effect-runner module path may change. All worker and test imports must move
  atomically because the repository does not retain compatibility aliases.
- Moving files across Dune directory scopes can change wrapped module names,
  private-module visibility, C-stub ownership, and generated install entries.
- `Catalog` and `E2ee` are computationally pure even though their only consumers
  are effectful. Keeping them in the effect-runner implementation optimizes
  ownership clarity rather than maximizing the amount of code in the lower pure
  library.
- The worktree currently contains overlapping sync and worker changes. A future
  implementation must preserve unrelated edits while moving files and rewriting
  Dune stanzas.

## Questions

- None. The user selected an installed public effect-runner library and the
  immediate removal of all combined `Logseq_sync.*` paths without a facade or
  compatibility aliases.
