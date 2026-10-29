# Qaama

Application macOS native (Swift 6, SwiftUI) d'édition photo non destructive avec gestion de
bibliothèque (photothèque Apple + dossiers locaux). « Qaama » signifie « lumière » en
kalaallisut.

- Plan et décisions : [docs/PLAN.md](docs/PLAN.md)
- Cahier des charges de référence : [docs/inventaire-photomator.md](docs/inventaire-photomator.md)

## Prérequis

macOS 27, Xcode 27.1, [XcodeGen](https://github.com/yonaskolb/XcodeGen), xcbeautify (optionnel).

## Construire

```sh
xcodegen generate            # régénère Qaama.xcodeproj depuis project.yml (non versionné)
xcodebuild -scheme Qaama -configuration Debug build | xcbeautify
open build/DerivedData/Build/Products/Debug/Qaama.app   # si -derivedDataPath build/DerivedData
```

Tests des paquets : `swift test` dans `Packages/<Paquet>`.

## Organisation

- `Qaama/` : cible application (SwiftUI, AppKit ponctuel).
- `Packages/LibraryKit` : bibliothèque de photos (PhotoKit, fichiers). Sans AppKit dans
  son API publique, pour rester portable.
- Autres paquets à venir selon le plan : `RenderEngine`, `EditModel`, `ImageIOKit`.
