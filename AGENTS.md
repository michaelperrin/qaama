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
- **Feature list.** Every user-visible feature goes into `docs/FEATURES.md` (English, by area and
  sub-area, dated) in the same change that ships it. It is the source for a future website.
- **Commits.** Only when the maintainer asks. English, imperative subject, body with bullet
  points, attribution trailers as configured.

## Architecture

```
Qaama/            SwiftUI app: views, glue between packages, AppKit where unavoidable
Packages/
  EditModel/      EditRecipe: the versioned JSON edit description, pure Swift
  EditorKit/      EditorModel: editing workflow (open, preview, undo, save, export), testable without views
  ImageIOKit/     ImageIO and Quick Look: headers (EXIF), thumbnails, full-size decoding
  RenderEngine/   Core Image on Metal: decoding (CIRAWFilter for RAW), pipeline, canvas, export,
                  the retouch fill and the reading of LUT files (targets HealingFill and CubeLUT,
                  always optimized), and the LUT library
  LibraryKit/     Sources of photos (Photos library, folders), SQLite catalog (GRDB), sidecars, caches
Experiments/      Throwaway feasibility prototypes, never linked into the app
```

- Dependency direction: app → everything; EditorKit → LibraryKit + RenderEngine + EditModel;
  RenderEngine → EditModel and ImageIOKit; LibraryKit → ImageIOKit and GRDB. LibraryKit never depends on RenderEngine: when it needs rendering (preview
  rebuilds), the app injects a closure (`PreviewRenderer`).
- The catalog (`docs/catalogue.md`) is an index of the folders and sidecars, rebuildable at any
  time; the sidecar next to the image is the portable truth and wins on conflict. Scans run in
  two phases: `FolderLister` + `FolderIndexer` (fast, system attributes, identity), then
  `MetadataIndexer` (headers in batches, in the background).
- `LibrarySource` is the protocol every photo source implements; views only see
  `any LibrarySource` and `LibraryAsset`. Keep PhotoKit and file-system types inside LibraryKit.
- The map of every library (`CombinedLibrarySource`, "Map" in the sidebar) holds no photo and
  lists none until a group is opened from the map: it then weaves by date the members' listings
  of that group, and sends everything asked about a photo to the member holding it. Its members
  are its own instances of the sources (it sets their query, so it can't share the ones the
  sidebar shows); identifiers are the members' own. Anything a source must tell for that goes
  into `LibrarySource` (`listingDates()`), never into a cast to a concrete source. One grid of
  every photo of every library was tried and dropped: see `docs/PLAN.md` before bringing it back.
- A card or a camera plugged in (`CameraLibrarySource`, "Devices" in the sidebar) is a
  `LibrarySource` without any capability, so the grid browses it as it does a library; nothing is
  stored about its photos. What talks to the device is behind `CameraConnection` and
  `CameraBrowser` (ImageCaptureCore is one implementation, `ImageCaptureBrowser`), so everything
  above is tested with a fake one. A device answers one request at a time and reads the whole file
  for a thumbnail: every request goes through `CameraRequestQueue`, and the grid shows
  `quickThumbnail` (the one embedded in the file's header) first.
- Filters: `LibraryQuery.filters` (`LibraryFilters`) says what applies and is all a source reads;
  what the Filter panel shows (checkboxes, values kept while unchecked, its switch) is
  `LibraryFilterSettings`, kept per library by `LibraryFilterPanels`, which writes the query (and
  writes it again when the day changes, for dates like "the last 30 days": `LibraryFilters` only
  holds absolute dates). A new
  filter goes into both, with its `QueryCapability`, the catalog's SQL and the PhotoKit predicate
  (or the Photos index when PhotoKit can't query it, as for places and edits).
- A filter preset (`FilterPreset`, kept by `FilterPresetStore` in a JSON file of Application
  Support: user data, unlike the catalog) is panel settings plus the library they were saved in.
  It shows through a source of its own (`LibraryCatalog.library(for:)`), as the map does, so its
  filters never touch the source the library's own sidebar entry shows.
- Edits are recipes, never pixels: sidecar `<file>.qaama` next to folder images,
  `PHAdjustmentData` plus a rendered JPEG for Photos. Reset means removing the recipe.
- A LUT is named in the recipe, never copied into it: the `.cube` files live in the app's
  library (`LUTLibrary`, Application Support), which every render reads by name. A recipe whose
  table is gone renders without it.
- Deleting and duplicating belong to the source (`LibrarySource.delete`, `duplicate`): a folder
  moves the image and its sidecar to the Trash (through `FileTrash`, a folder in tests) and
  copies them under the Finder's name for a copy, the sidecar under a new identifier; Photos
  deletes after the system's own question and copies the original's resources into a new photo.
  A RAW + JPEG pair shown as one photo is deleted or copied as one.
- Retouches are strokes in the recipe, in the original's coordinates. What fills them is computed
  by `RetouchRenderer` once per stroke, off the main actor, and only composited by the pipeline;
  each fill depends on the retouches before it.
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
  Views stay thin: behavior goes into an observable model in a package (see `EditorModel`).
- The app's accent is a neutral gray (`AccentColor` in `Qaama/Resources/Assets.xcassets`): next to
  photos the interface stays quiet. Color what must stand out with `Color.accentColor` or `.tint`,
  never with a fixed blue, and keep color for what informs (a gradient on a slider's track). A
  selected photo is marked with `SelectionRing`, not with the accent, which a photo swallows.
- Prefer SwiftUI; AppKit only in the app target and only when SwiftUI has no equivalent.
  A Metal layer shows nothing inside a SwiftUI `.sheet` on macOS 27: keep canvases in windows
  or columns.
- In the editor inspector (a `Form`), never place a control whose natural width exceeds the
  column (segmented pickers with long labels, wide buttons): the List renegotiates its insets on
  every frame while a slider is dragged and the whole column wobbles. Keep segmented labels
  short and `.controlSize(.small)`; prefer menus for long choices.
- SwiftUI skips a view's `body` by itself when its inputs are plain values; it can't when they
  include closures or existentials (`any LibrarySource`). A view that is repeated (grid cells,
  list rows) or that holds a context menu with a submenu (SwiftUI replaces an open menu's items
  on every update of the view holding it, which closes the submenu) gets `Equatable` with
  `.equatable()`, its closures moved to one stable object (see `AssetGridCell` and
  `AssetGridActions`). Everything the view shows must then be one of its inputs or an observed
  value, or the display goes stale. Elsewhere, measure before adding it.
- While a key is held, SwiftUI calls the `onKeyPress` handler of the first press again for every
  repeat, and a `@Binding` it reads keeps the value of that first press (`@State` reads are
  current). Have the handler call through an object the view repoints at each update, as the
  grid does with `AssetGridActions.move`.
- Inside the grid's `ForEach`, read nothing observed from the source but `assets[index]`: a cell
  that depends on other state of the source (its items, a per-photo lookup) is refreshed alone
  when it changes, with a row that may no longer exist, and crashes when the listing shrinks.
  Ask the source once per grid update instead (as `hasFileURLs` does). And check the row still
  exists before reading it: even a cell that only reads `assets` can be asked again before the
  months above it are, when a listing spread over several months shrinks.
- A cell of the grid is identified by its row and its section (`GridRowID`), never by its row
  alone: when a section is inserted above (a newer month), its rows are rows another section held,
  and the lazy grid then keeps the old cells on screen without ever installing the new ones (seen
  with a probe: the rows are built, neither `==` nor `body` of their cells is called). Scroll to a
  row through `DateTimeline.rowID(_:)`.
- Every row of a `ForEach` in a lazy container is exactly one view. A row made of an `if` without
  `else` is zero or one view: the container can't tell where a row is without building every row
  above it, and does so at each update (measured with 74,000 photos: 3.6 s to toggle the sidebar,
  against 0.2 s). Put the condition inside a container (`ZStack`), as the grid does.
- Between the window and a scroll view that runs under the toolbar, only frames (`frame(width:)`,
  `frame(maxWidth:)`): inside a `Layout` of our own, a `GeometryReader`, an `overlay`, or a frame
  with both a minimum and a maximum, the scroll view loses the toolbar's soft edge and photos show
  sharp under the window's title (seen with a probe; see `SettledWidth`).

## Code quality

- **Everything is undoable.** Any operation that changes a photo or its metadata (adjustments,
  pasted adjustments from the grid, rating, flag, keywords, crop, batch actions) registers with
  the window's `UndoManager` under an action name, so the Edit menu can undo and redo it. For
  asynchronous work, capture the previous state before writing, register on a target that lives
  as long as the window (the library source), and have the undo register its own inverse. Changes
  whose inverse is only known once made (a new album's identifier, where the Trash put a file) go
  through `UndoableSteps`. Two exceptions: a photo deleted from the Photos library can't be taken
  back out of Recently Deleted (PhotoKit), and a photo deleted from a card or a camera is gone
  (no Trash there); neither registers an undo, and the second always asks first.
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
- Anything that runs per slider move must stay well under a frame (16 ms): no per-pixel or
  per-entry allocations, dictionaries or generic helpers in hot loops (precompute into arrays,
  as `HSL.Evaluator` does), cache derived data keyed by the setting that produced it (as
  `ColorCube.data(for:)` does), and remember the app is tested in Debug builds, which are
  several times slower than Release. Measure with a temporary test before and after.
- Pure Swift loops over pixels are hundreds of times slower without optimization (measured:
  38 s against 59 ms for one retouch fill). Code of that kind goes into a small target of its
  own compiled with `-O` in Debug too, as `HealingFill` and `CubeLUT` are in the RenderEngine
  package.

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
