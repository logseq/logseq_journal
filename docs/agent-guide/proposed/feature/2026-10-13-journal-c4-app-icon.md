# Journal C4 App Icon

## Problem

The Journal Apple build assembles its app without an icon catalog. Installing the app therefore does not show the C4 logo chosen by the user.

## Proposal

Keep the approved original PNG and standard opaque icon sizes in assets/apple. Compile one AppIcon catalog with Apple's actool during the existing Apple app assembly, merge its generated icon declarations into the actual bundle Info.plist, and sign after adding resources. Use the same artwork for basic macOS support. Keep features, Dune, spec interfaces, dependency pins, and device installations outside this change.

## Alternatives considered

### Copy only a PNG

A loose image has no compiled AppIcon or generated bundle declaration; it does not complete iOS app icon packaging.

## Acceptance criteria

- The 1024px iOS input is opaque and full bleed, with rounding left to the system.
- Real actool compilation yields icon resources and declarations in iOS and macOS bundles.
- The production Apple assembly invokes icon packaging before signing.
- An installed production Simulator bundle shows C4 on the Home Screen, with evidence outside Git.
- A separate non-draft PR is opened and its exact head CI reaches a terminal result.

## Risks

- Simulator's Home Screen can cache icon artwork; verification must inspect the installed bundle and actual Home Screen.
- Existing OCaml and Swift outputs are reused only with matching source and target identity.

## Questions

None. The user selected C4, explicitly requested adding the app logo and separate PRs, and supplied the approved standalone opaque PNG.
