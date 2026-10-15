# Reusable Apple Build

## Problem

Recent Journal builds repeatedly reconstructed dependency, target, cache and signing checks in external task scripts. The existing Apple entry point defaults to a stub, suppresses signing failures and does not record artifact provenance.

## Decision

Extend `tool/build_journal_apple.sh` through a Python companion using the existing Swift package and icon packager. Build the production macOS native object through Dune in an owned external cache after read-only switch/lock/pin checks. Strict default iOS builds still require explicit mode selection. The user has additionally authorized `--experimental-host-restamp --native-manifest FILE`: import only a hash-verified producer host object matching current native sources, validate its single-unit XMLm force-link proof, compile DNS/crypto C freshly for the selected target, and reuse the common Swift/package/sign pipeline. The input manifest references the existing source, link and XMLm proof JSON files by path/hash; it contains no executable command hooks. Device signing inputs are explicit. Record the host runtime ABI limitation; build never installs or changes pins.

After one successful import, an optional hash-bound `validated_build` receipt proves the original producer records and consumed input hashes for the immutable complete object. Historical archives are no longer live build inputs: their later modification/removal cannot alone invalidate that object. Current object/native source/configuration/pins, runtime C headers, original evidence/receipt, SDK identity, Swift and signing inputs remain strict. The producer commit must be an ancestor of the builder revision; exact native bytes/configuration still match across Build/tool/docs commits, and reports distinguish these revisions. The original producer records are never rewritten. The build importer owns this regression; no application reducer can reproduce a filesystem/provenance contract failure, so tests exercise the importer with a tiny real Mach-O producer and temporary external Git/source files.

## Alternatives considered

### Alternative

Do not copy historical device deployment scripts: their host ARM64 restamp route is not a verified iOS OCaml cross toolchain. Do not add a separate competing build entry point or change protected Dune/spec/lock files.

## Acceptance criteria

- CLI failure checks prevent accidental stub production builds, unsupported targets, unsafe output replacement and concurrent cache use.
- Read-only preflight identifies actual installed dependency mismatches without changing the switch.
- Explicit link-only assembly verifies target, resources, version and signature, with manifest and phase logs outside Git.
- Input changes select a new cache without clearing previous caches; repeated identical builds reuse their namespace.
- Explicit experimental builds validate producer source/configuration/dependency identities, retain runtime/mldoc/XMLm, compile target C, check Swift object platforms, and verify the packaged device signature without claiming full OCaml iOS ABI acceptance.

## Risks

- Current local switch lacks mldoc and XMLm pins; native Dune builds may be blocked rather than repaired implicitly. The explicit imported-native route reuses producer dependency provenance instead of constructing another switch.
- Host runtime restamping remains experimental, not full target-native OCaml compilation or ABI validation. Production iOS C and Swift targets must be independently checked; raw object injection remains blocked. Link-only is not runnable acceptance.

## Consequences

- The existing shell entry point delegates to one standard-library Python implementation. The documented entry point replaces legacy object-injecting aliases for supported builds; protected Dune/spec/lock files are unchanged.
- Nineteen boundary tests pass on Python 3.9 and 3.13, including changed/missing consumed archives, a later builder-only commit and negative object/source/C/header/evidence/receipt/SDK cases. Two actual Simulator link-only assemblies passed target, resource/icon and strict signing checks, and reused one cache namespace. Concurrent entry was rejected as busy. Icon packaging passed for all three targets.
- Independent exact-head review reproduced a cancellation race: a leader could exit on SIGTERM while its descendant ignored it, allowing the cache lock to release early. Cancellation now kills the remaining process group even after the leader exits. A real descendant holding a FIFO write endpoint verifies termination before lock release; it failed before the fix and passes afterward.
- An actual experimental iPhoneOS build produced a signed production App: runtime/mldoc/XMLm retained, 55 Swift objects verified as iOS ARM64, DNS/crypto link-map providers verified as freshly compiled iPhoneOS C, and profile/signature/entitlements read back successfully. Subsequent review tightened source deletion/configuration, compiler and profile guards. A final retry correctly stopped before compilation when another authorized task changed 14 historical producer archive inputs; it did not accept the old provenance or interfere with that cache. The successful App remains preserved. Independent journal-code-review found no remaining substantive issue after fixes.
- The later archive mismatch exposed an overly strict importer lifecycle rule: the fixed complete object remained valid while another owner normally updated its consumed archives. Receipt-bound historical provenance now distinguishes that state from changed current inputs. After the repair, a final production iPhoneOS build passed through this entry point: fixed OCaml complete object reused, target C and all Swift/LUI objects compiled in a new cache namespace, icons/resources packaged, signature/entitlements and input stability verified. No OCaml recompilation or phone operation occurred.
- Full native macOS validation is blocked by the current switch's missing mldoc, nonlocked XMLm and incomplete cached Git source objects. No dependency repair, full OCaml iOS ABI acceptance, phone operation or runtime acceptance is claimed.

## Questions

- The delegated user instruction supplies the target/safety scope and explicitly requests implementation, verification and independent review. No unresolved product choice requires another approval. Protected Dune/spec/lock changes remain outside scope.
