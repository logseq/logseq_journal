---
name: journal-build
description: Build and verify Journal Apple apps for macOS, iOS Simulator and iPhoneOS, or maintain their build scripts, dependency cache identity and native provenance.
---

# Journal Build

Run `bash .agents/skills/journal-build/scripts/build_journal_apple.sh --help` from the repository root. Maintained build, CI provisioning, icon packaging and probe-assembly helpers live in `scripts/`; product acceptance tools remain in `tool/`. The Apple entry point never installs apps, updates dependencies/pins, touches graphs or deletes caches. Coordinate CPU/actool, switch locks and borrowed inputs with active owners.

- Before choosing a target or building, read [targets and prerequisites](references/targets.md). macOS requires an explicit prepared locked switch. Simulator stubs require `--link-only`; runtime imports and device builds require explicit experimental provenance. All current targets are ARM64 with deployment target >=26.0.
- For Simulator producer evidence, use `macos --producer-only --switch ...` with the same prepared inputs. It stops after native production and final input checks, returns a schema-2 envelope and `status: native-produced`, and does not build an App. Then pass that envelope to the normal explicit Simulator importer.
- For `--experimental-host-restamp --native-manifest`, read [native provenance](references/native-provenance.md). Original producer records remain immutable. Host restamping does not prove full iOS cross-compilation or ABI acceptance.
- For incremental reuse, switch/cache mismatch, CI changes or cold/hot measurements, read [cache and CI](references/cache-and-ci.md). Reuse existing input manifests; do not relocate switches, mix target objects, change another owner's pins, or skip locked-dependency and final source/build/test checks to obtain a hit. GitHub cache lifecycle stays in the workflow and CI dependency preparer.

Only `status: built` confirms an App. `preflight-passed` and `link-only` are not runtime acceptance. Preserve `cross_abi_validated=false` for host-restamped objects and hand off the manifest with the app. Installation and phone/graph operations require their own scope.

For build-tool changes run `PYTHONDONTWRITEBYTECODE=1 python3 .agents/skills/journal-build/scripts/test_journal_build.py`. Use `scripts/test_apple_app_icon.py` when packaging changes and the owner/environment permit actool; use `sh test/test_native_static_gmp.sh .agents/skills/journal-build/scripts/native_static_link_flags.sh` for static-link helper changes. A layout-only move needs path/import and Dune resource checks, not a new production build or GUI run.
