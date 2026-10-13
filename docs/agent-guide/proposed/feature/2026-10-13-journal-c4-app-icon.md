# Journal C4 App Icon

## Problem

The Journal Apple build assembles its app without an icon catalog. Installing the app therefore does not show the C4 logo chosen by the user.

## Proposal

Keep the approved original PNG and standard opaque icon sizes in assets/apple. Compile one AppIcon catalog with Apple's actool during the existing Apple app assembly, merge its generated icon declarations into the actual bundle Info.plist, and sign after adding resources. Use the same artwork for basic macOS support. Keep features, Dune, spec interfaces, dependency pins, and device installations outside this change.

## Decision

Implemented the approved C4 artwork without design changes. The 1254px RGB original is retained beside opaque standard-size copies. Both Apple bundle layouts compile AppIcon through one shared actool packaging step before signing; generated icon declarations are merged into the installed Info.plist.

Real iOS and macOS packaging tests pass. A production-source Simulator binary was compiled with verified unchanged LUI dependencies and the main-baseline OCaml object, restamped using the existing ios-app convention. The installed bundle's binary, icon resources, and Info.plist match the built product. Its Home Screen displays C4 with the system corner mask. Validation evidence is kept outside Git; the app was not launched and no graph was accessed.

## Alternatives considered

### Copy only a PNG

A loose image has no compiled AppIcon or generated bundle declaration; it does not complete iOS app icon packaging.

## Acceptance criteria

- The 1024px iOS input is opaque and full bleed, with rounding left to the system.
- Real actool compilation yields icon resources and declarations in iOS and macOS bundles.
- The production Apple assembly invokes icon packaging before signing.
- An installed production Simulator bundle shows C4 on the Home Screen, with evidence outside Git.

## Risks

- Simulator's Home Screen can cache icon artwork; verification must inspect the installed bundle and actual Home Screen.
- Existing OCaml and Swift outputs are reused only with matching source and target identity.

## Questions

None. The user selected C4, explicitly requested adding the app logo and separate PRs, and supplied the approved standalone opaque PNG.
