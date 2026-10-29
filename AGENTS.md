# Working on Qaama

Qaama is a native macOS photo editor with non-destructive editing and library management
(Apple Photos library and folders on disk), inspired by Photomator. These are the rules for
anyone, human or agent, contributing code. The roadmap lives in `docs/PLAN.md`.

## Ground rules

- **Legal: observe, never extract.** Photomator is studied as a black box only: running it,
  reading its plain-text resources, examining files it produces on our own photos, Apple's
  documentation. No decompilation, and never reuse its code, shaders, Core ML models, assets,
  UI strings or file formats. Third-party models or code need a permissive license (Apache 2.0,
  MIT, BSD) recorded next to where they are used.
- **Language.** App UI, code, comments, commit messages, README and this file are in English.
  Conversations with the maintainer and the planning documents (`docs/PLAN.md`,
  `docs/inventaire-photomator.md`) are in French.
- **Platform.** macOS 27 minimum, latest APIs welcome. Packages must stay portable to iPadOS:
  no AppKit in their public API, `#if canImport(AppKit)` where the implementation needs it.
- **Pace.** Plan, proof of concept, MVP, then more. Keep `docs/PLAN.md` checklists current
  (French) when a step is done or a lesson is learned.
- **Commits.** Only when the maintainer asks. English, imperative subject, body with bullet
  points, attribution trailers as configured.

## Architecture

```
Qaama/            SwiftUI app: views, glue between packages, AppKit where unavoidable
Packages/
  EditModel/      EditRecipe: the versioned JSON edit description, pure Swift
  RenderEngine/   Core Image on Metal: decoding (CIRAWFilter for RAW), pipeline, canvas, export
  LibraryKit/     Sources of photos (Photos library, folders), assets, editing storage, caches
Experiments/      Throwaway feasibility prototypes, never linked into the app
```

- Dependency direction: app → everything; RenderEngine → EditModel; LibraryKit depends on
  neither. When LibraryKit needs rendering (preview rebuilds), the app injects a closure
  (`PreviewRenderer`).
- `LibrarySource` is the protocol every photo source implements; views only see
  `any LibrarySource` and `LibraryAsset`. Keep PhotoKit and file-system types inside LibraryKit.
- Edits are recipes, never pixels: sidecar `<file>.qaama` next to folder images,
  `PHAdjustmentData` plus a rendered JPEG for Photos. Reset means removing the recipe.
- Thumbnails of edited folder photos come from `PreviewCache` (2048 px JPEG of the real
  render, keyed by asset id and modification date), never from re-applying the recipe on a
  small image.

## Swift and concurrency

- Swift 6, strict concurrency, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` in the app and
  `.defaultIsolation(MainActor.self)` in packages (except EditModel, which is pure data).
- Value types, protocols and helpers that must be usable off the main actor are marked
  `nonisolated`. Blocking work (file enumeration, ImageIO header reads, full renders) runs in
  `Task.detached` or a `nonisolated` static function, never on the main actor.
- Framework callbacks that run on their own queue (PhotoKit `performChanges`, image request
  handlers, Quick Look, Metal completion handlers) must be `@Sendable` closures. Hop back with
  `Task { @MainActor in … }`.
- `UncheckedSendable` and `nonisolated(unsafe)` are for documented single hand-overs of
  non-Sendable framework objects only; say why in a comment.
- `@Observable` classes for state shown by SwiftUI. Property observers (`didSet`) are fine.
- Prefer SwiftUI; AppKit only in the app target and only when SwiftUI has no equivalent.
  A Metal layer shows nothing inside a SwiftUI `.sheet` on macOS 27: keep canvases in windows
  or columns.

## Code quality

- Small, single-purpose types with a doc comment that says what they are for and any
  non-obvious constraint. Comments explain why, not what.
- No duplication across sources: shared behavior goes into the protocol, a helper enum or an
  extension.
- Errors are typed (`LibrarySourceError`, `LoadError`…) with `LocalizedError` descriptions
  the UI can show as is.
- Logging through OSLog, subsystem `fr.michaelperrin.qaama`, one category per type.
  Use `.notice` for events worth keeping (access, listing times, saves, rebuilds), `.error`
  for failures, `.debug` for per-frame noise. Mark non-sensitive interpolations
  `privacy: .public` or they show as `<private>`.
- Measure before optimizing: log durations with `ContinuousClock` and report them in the plan.

## Tests

- Swift Testing (`@Test`, `#expect`, `#require`) in each package's `Tests/` folder. Add tests
  for any pure logic: models, scanners, caches, pipelines, renderers.
- Tests are hermetic: generate images with CoreGraphics into a temporary folder, remove it in
  `defer`; never read the maintainer's photos or Photos library.
- What can't be unit-tested (PhotoKit, windows, Metal views) gets OSLog instrumentation and is
  verified by running the app. Off-screen rendering into an `MTLTexture` is testable: use it.
- Run `swift test` in every touched package and build the app before reporting a change done.

## Build and tools

```sh
xcodegen generate                      # after editing project.yml; Qaama.xcodeproj is not versioned
xcodebuild -project Qaama.xcodeproj -scheme Qaama -configuration Debug \
  -derivedDataPath build/DerivedData build | xcbeautify --quiet
(cd Packages/LibraryKit && swift test)  # same for EditModel and RenderEngine
swiftformat Packages Qaama              # config in .swiftformat; keeps explicit self for OSLog
open -n build/DerivedData/Build/Products/Debug/Qaama.app
/usr/bin/log show --last 5m --info --predicate 'subsystem == "fr.michaelperrin.qaama"' --style compact
```

- Use `/usr/bin/log`: in zsh, `log` is shadowed by a builtin and prints nothing.
- Ad hoc signing with a free developer account; the app is sandboxed with the Photos and
  user-selected-files entitlements. Folder access persists through security-scoped bookmarks.
- Large downloads (Core ML models) stay out of the repository; document where to get them.
