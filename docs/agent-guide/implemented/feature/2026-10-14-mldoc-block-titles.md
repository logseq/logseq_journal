# Parse block titles with mldoc

## Problem

Timeline and Detail expose markup and raw URLs; string reference expansion misreads code and escapes and loses nested styling.

## Decision

Use official native mldoc AST in Journal_model.Title to emit styled runs with explicit URL/block targets. Timeline root/child and Detail share this adapter and graph-session reference cache. Swift maps runs to AttributedString and native Text for wrapping, truncation and clicks; it does not parse Markdown. Only UUID Page_ref nodes written as [[uuid]] are business references. Code, escapes and ordinary page names remain literal; missing/cyclic targets fall back to their tokens. Expanded nested labels retain their outer reference click target, while explicit URL fragments keep their URL.

Admit at most 64 KiB source, 32 delimiter depth and 4096 open delimiters before parsing, then cap semantic conversion at 512 nodes. Keep a FIFO 512-entry/2 MiB source-byte syntax cache. Expansion is limited to 16 reference levels, 256 targets, 512 work nodes and 64 KiB output. Timeline keeps four parent lines and at most three smaller/fainter children of two lines; Detail retains status, properties, ten-level pagination, 100 ms loading and asset ownership.

Pin the merged core package to b3e06c030b7396f7992ebe1c3a4f35f5e6983200 and XMLm fork to eb469d536e98c98f2754c0ff8813c92b3a17fe9f. The user approved the app/dune library entry and the exact dune-project/opam/locked dependency range. Only mldoc.dev and xmlm.dev are new locked packages; CLI, JS and benchmark packages are separate upstream packages.

## Alternatives considered

### Swift Markdown parser

A Swift Markdown parser would duplicate Logseq syntax and diverge between views. The shared OCaml adapter preserves mldoc semantics and leaves native layout to SwiftUI.

## Consequences

The graph-session target/missing cache, pending deduplication and invalidation retain bounded hydration. Cold targets use the existing indexed single-UUID worker API; no render-driven DB read, all-graph query or new batch protocol is added. Complex source outside the parser/conversion/expansion budgets remains literal. The conservative parser admission also avoids mldoc nested-link backtracking on adversarial delimiter input.

The Simulator continues to use the existing ARM64 complete-object restamp route with simulator crypto. Physical-device/full cross-runtime ABI acceptance remains outside this task.

## Validation

The merged core was fetched at its public immutable SHA, built as package mldoc and installed to a private prefix with the fixed XMLm fork. Native link manifests record source and archive hashes. The complete forced Dune @runtest plus native_embed.exe.o build returned exit 0: 21 Alcotest suites, 784 cases, plus standalone package checks. The existing sealed-interface test now locates its own build's three public CMI paths from the test executable; its full positive/negative compilation assertions are unchanged. Actual external-cwd RED then GREEN proves the path fix without a repository _build symlink.

Three actual native XCTest cases pass on the isolated iPhone 13/iOS 26.1 synthetic fixture with the merged core. Screenshots verify parent four-line and child two-line truncation, three Timeline children, Detail full text, nested style, long bilingual/CJK text, missing/cyclic fallback and target Detail. Both URL forms open Safari. AX extension frames include host reservation; CJK acceptance compares Detail expansion and uses pixel inspection for four visible lines. Safari webpage content/loading is not asserted. No real graph changes, physical-device installation, push or PR occurred. All temporary evidence stays outside Git.

## Test ownership

The nested-reference click defect belongs to pure Title.render, which has no reducer-event boundary. Its public output regression failed before the minimal fix and passed afterward, without injected DB/effect results. The external-build path defect belongs to the existing public compiler test harness; its direct execution and unchanged compiler assertions exercise the narrowest boundary. Native XCTest is the separately requested feature acceptance.
