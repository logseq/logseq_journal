# Journal Block Detail Wider Indentation

## Problem

The selected A detail layout uses ten distinct insets, but the user requests slightly stronger indentation at each level.

## Decision

Change only the existing LUI column left margin from 0/12/24/30/36/40/44/48/52/56 to 0/16/32/40/48/53/58/63/68/73 points for depths zero through nine. Keep depth clamping, typography, vertical spacing, semantic color, rich content, and every interaction unchanged. The progressively smaller 16/8/5 point steps preserve usable width at deep levels.

## Alternatives considered

### Uniform sixteen point steps

Rejected because a ninth-level inset of 144 points makes mobile text unnecessarily narrow, especially with larger system fonts.

## Acceptance criteria

- All ten real depths remain distinct; negative and oversized inputs clamp safely.
- Mounted public row behavior verifies the intended insets, unchanged spacing, content, and child actions.
- Existing prepared resources are coordinated before building or using either existing Simulator; no new Simulator or phone operation occurs.
- Representative shallow/deep and large-type screenshots identify their exact source, installed App, device, and graph. The current-main PR acceptance uses only independently generated synthetic graph identity; earlier real-graph evidence remains historical.
- No status implementation, public interface, spec, Dune, lock, or additional Swift responsibility is included. The current-main combined A branch may be pushed as a draft PR under the later explicit user authorization; no merge occurs.

## Risks

- The deepest inset increases by 17 points. Narrow and accessibility-size native layout needs actual visual acceptance in addition to mounted behavior.
- Experimental host restamping does not establish complete iOS ABI validation.

## Questions

- None: the user explicitly requested the adjustment and authorized read-only representative graph screenshots.

## Consequences

The LUI column alone increases each level's horizontal inset. The deepest inset is 73 points, 17 points wider than before; font size, weight, vertical spacing, color, Swift sources, rich content, and interactions are unchanged.

## Implementation evidence

Source commit 9c8c7f7 changes only the existing row formula, its mounted test, and this decision. The updated test failed against the original behavior and all 51 semantics scenarios passed after the minimal change. Negative and oversized depth inputs remain clamped.

The maintained producer run-q0yeo7fe and Simulator importer run-7cfseb0a both bind the exact 9c8c7f7 source. The normal App version 1.5877.3502 passed strict signing and was installed in place on existing A135 Simulator. Its SHA-256 is dfd5bbb4158a641bddbd2c98ee90a25c4d67c7fe3abc2dcb19b0df5253e731a6. Original Lambda RTC identity matched the historical stable identity before and after installation. Read-only DB release checklist and public roadmap screenshots show the adjusted real hierarchy. The main Simulator was left on original Lambda RTC Favorites.

An existing native fixture on existing 1446 Simulator rendered newly generated public OCaml patches using unchanged production Swift. Light shallow/deep and accessibility3 dark/high-contrast screenshots show complete wrapping through depth nine. Native accessibility scrolling reached the complete tenth-level body, and Back returned Synthetic Timeline. This component evidence does not exercise a full synthetic worker or graph.

All raw screenshots, source-bound manifests, graph identity checks without private IDs or body, and test logs are outside the repository under the current task evidence/indent-wider-20261018 directory. The full document check retains three pre-existing invalid historical documents. Host restamping remains experimental: cross_abi_validated=false and runtime_acceptance=false; manual interaction observations do not certify complete cross-target ABI correctness. No phone, new Simulator, shared dependency mutation, graph edit, push, PR, or merge occurred.


## Current-main integration and acceptance

This indentation is included in implementation de16462cad86c468b0db443eefd2790489c9d0f5 on main 851cb85, together with the approved A typography and LUI row ownership.
The exact ten insets remain 0/16/32/40/48/53/58/63/68/73 points, with bounds and row events checked through mounted public composition.
The accompanying A decision records the current clean-source 21-suite/973-case full regression, native provenance, actual synthetic Application screenshots, successful composer readback, source/visual review, and experimental ABI limits.
The 2026-10-19 screenshots use only existing synthetic Simulator 1446 and an independent bundle; A135 and private graphs were not accessed.
Light normal-size and dark maximum-accessibility/high-contrast views reach the complete depth-nine body and native Back returns Timeline.
The new draft PR authorization supersedes the earlier no-push scope solely for this isolated UI branch; the historical evidence above is not substituted for current-source acceptance.
