# Qaama

Native macOS app (Swift 6, SwiftUI) for non-destructive photo editing with library
management (Apple Photos library and local folders). "Qaama" means "light" in Kalaallisut.

- Plan and decisions (French): [docs/PLAN.md](docs/PLAN.md)
- Reference feature inventory (French): [docs/inventaire-photomator.md](docs/inventaire-photomator.md)

## Requirements

macOS 27, Xcode 27.1, [XcodeGen](https://github.com/yonaskolb/XcodeGen), xcbeautify (optional).

## Build

```sh
xcodegen generate            # regenerates Qaama.xcodeproj from project.yml (not versioned)
xcodebuild -scheme Qaama -configuration Debug -derivedDataPath build/DerivedData build | xcbeautify
open build/DerivedData/Build/Products/Debug/Qaama.app
```

Package tests: `swift test` inside `Packages/<Package>`.

## Layout

- `Qaama/`: application target (SwiftUI, with AppKit where needed).
- `Packages/LibraryKit`: photo library (PhotoKit, files). Its public API never exposes
  AppKit, to keep it portable.
- Further packages planned: `RenderEngine`, `EditModel`, `ImageIOKit`.

## Language

The app and its code are in English. Project planning documents in `docs/` are in French.
