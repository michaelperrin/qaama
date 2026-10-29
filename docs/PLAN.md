# Qaama — plan de reconstruction d'une appli d'édition photo type Photomator

Statut : plan initial (29 octobre 2026). Projet au long cours, sans contrainte de délai.

## 1. Objectif

Créer une application macOS native en Swift d'édition photo non destructive, avec une
vraie gestion de bibliothèque (dossiers locaux + photothèque Apple), en s'appuyant au
maximum sur les frameworks Apple. Photomator (installé sur le poste) sert de référence
fonctionnelle et d'objet d'étude via le MCP REA.

Démarche : étudier → spécifier → POC → MVP → extensions, par petites étapes validées.

## 2. Ce que la reconnaissance REA a déjà appris (29/10/2026)

Cible étudiée : `/Applications/Photomator.app`, version 3.4.15 (build 20260717.1342),
macOS 13 minimum, 672 Mo, sandboxée, copyright Apple Inc.

### 2.1 Architecture observée

| Couche Photomator | Taille | Rôle (observé / inféré) | Frameworks Apple utilisés |
|---|---|---|---|
| `Photomator` (exécutable) | 220 Ko | coquille, tout est dans les frameworks | AppKit |
| `PXMPro` | 360 Mo | l'appli elle-même + 14 modèles Core ML | SwiftUI, AppKit, PhotosUI, MapKit, PDFKit, ImagePlayground, TipKit, StoreKit, AVKit |
| `PTFoundation` | 43 Mo | moteur image : noyaux Core Image compilés en Metal (`PTCIKernels.ci.metallib`), RAW (`PTCIRAWFilterMaker`) | Core Image, Metal, MPS, Vision, Core ML, Core Data, Photos |
| `PTPhotoKit` | 36 Mo | la bibliothèque : navigateur Photos + navigateur fichiers | Photos, QuickLookThumbnailing, SwiftUI, AVKit |
| `PXMEngine` | 5 Mo | rendu/compositing | Metal, SceneKit, VideoToolbox |
| `PTImageIO` | 3,5 Mo | import/export | ImageIO, PDFKit, UniformTypeIdentifiers |
| `PDFEngine`, `PSDEngine`, `SVGEngine` | ~3 Mo | formats annexes | ImageIO, CoreText |
| `PTPaintTools`, `PTPaintSelection`, `PTObjectRemoval` | < 1 Mo | pinceaux, sélection, suppression d'objets (shaders Metal) | Metal, Core Image |
| `ExtendedRAWSupport.xpc` | 32 Ko | service XPC isolant le décodage RAW | — |
| `Add to Photomator.appex` | 48 Ko | extension de partage | — |

Points notables :

- UI en code (SwiftUI + AppKit), un seul nib : pas de storyboard à imiter.
- Fichiers source visibles dans `PTPhotoKit` : `PTBrowserDataController(+Photos, +Files,
  +Scan, +Caching, +Filter)`, `PTFilesLibrary`, `PTLinkedPhotoFile`,
  `PTPhotosBrowserData(+Fetch, +Sidecar, +URLPairing)`, `PHAsset+LinkedFiles`,
  `PHPhotoLibrary+Albums`. La bibliothèque est donc un contrôleur unique avec deux
  sources (Photos, fichiers), un cache, un filtre, et un appariement fichier ↔ sidecar.
- Édition non destructive dans Photos via `PHAdjustmentData` /
  `PHContentEditingInput` / `PHAssetChangeRequest` (confirmé par les symboles).
  Côté fichiers : sidecar XMP déclaré (`com.seriflabs.xmp`) et format document propre.
- Formats ouverts : JPEG, JPEG 2000, JPEG XL, PNG, TIFF, RAW (`public.camera-raw-image`),
  GoPro GPR, HEIC/HEIF, AVIF, Radiance HDR, OpenEXR, dossiers.
- Modèles Core ML embarqués : SuperResolution, NoiseReduction, NoiseAnalysis,
  SkyDetection, AutoCrop, HorizonDetection, ObjectDetection, MaskRefinement,
  Decontamination, ColorFixing, Deposterize(+Analysis), ImageAnalysis.
- Entitlements : sandbox, photothèque (lecture/écriture), fichiers choisis par
  l'utilisateur, iCloud Documents, App Groups, réseau client, impression.

### 2.2 Ce que REA pourra encore apporter, étape par étape

- Inventaire des ajustements et de leurs paramètres (noms, plages, ordre du pipeline)
  via `analyze_swift_types` / `search_strings` sur `PTFoundation` et `PXMPro`.
- Compréhension du modèle de bibliothèque (scan de dossiers, appariement RAW+JPEG,
  sidecars, cache de vignettes) via décompilation ciblée de `PTPhotoKit`.
- Observation de l'UI réelle (`observe_native_ui`, `capture_native_ui_scenario`) pour
  documenter les flux écran par écran avant de les concevoir.
- Comparaison de versions si Photomator se met à jour en cours de route.
- Hors périmètre (décision du 29/10/2026) : décompilation et analyse de types Swift.

## 3. Limites à connaître dès maintenant

### 3.1 Limites juridiques et éthiques (les plus importantes)

- Photomator appartient désormais à Apple. Le droit français (CPI, art. L122-6-1)
  autorise à **observer, étudier et tester** le fonctionnement d'un logiciel qu'on
  possède, et à le décompiler pour l'**interopérabilité**. Il n'autorise pas à copier.
- Règle du projet (validée le 29 octobre 2026) : **observation et boîte noire
  uniquement, pas de décompilation.** L'exception légale de décompilation ne couvre
  que l'interopérabilité et exclut la création d'un logiciel « fondamentalement
  similaire ». On s'autorise : exécuter et observer l'appli (y compris avec les outils
  d'observation d'UI de REA), lire les ressources livrées en clair, lire les fichiers
  que Photomator produit sur nos propres photos (sidecars), lire la documentation
  Apple. On ne réutilise aucun code, shader `.metallib`, modèle `.mlmodelc`, icône du
  `.car`, chaîne de l'UI ni format propriétaire. La décompilation ne serait envisagée
  que pour un besoin d'interopérabilité documenté (ex. importer des retouches
  Photomator), limitée à ce format et à cet usage.
- Ce qu'on reproduit librement : les idées, l'organisation, les choix de frameworks,
  les comportements observables. L'implémentation est entièrement la nôtre.
- Nom, icône et visuels distincts : pas de confusion possible avec Photomator.

### 3.2 Limites techniques de l'étude

- Sans décompilation, on ne verra ni l'ordre exact du pipeline ni les algorithmes :
  on les redécouvrira par expérimentation (comparaison de rendus) et par la
  documentation Apple. C'est acceptable, et même préférable pour une implémentation
  indépendante.
- Les shaders Metal et les modèles Core ML sont compilés : on sait qu'ils existent
  et à quoi ils servent, pas comment ils marchent.
- Les traitements « ML » maison (super‑résolution, débruitage ML, suppression d'objets,
  remplacement de ciel, décontamination) ne seront **pas reproductibles à l'identique**.
  On les remplacera par les API publiques d'Apple (Vision, Core Image, Image
  Playground) ou par des modèles open source convertis en Core ML, avec une qualité
  différente.

### 3.3 Limites de la plateforme

- Xcode 27.1 est installé. Signature avec un compte Apple
  gratuit suffisante pour tourner en local ; l'iCloud Drive sync et TestFlight
  exigent le programme développeur payant. On démarre sans iCloud.
- Sans sandbox, l'accès à Photos passe par la permission TCC classique
  (`NSPhotoLibraryUsageDescription`). Avec sandbox, il faut les entitlements et des
  security‑scoped bookmarks pour les dossiers : on sandboxe dès le début pour ne pas
  avoir à revenir dessus.
- Les ajustements enregistrés dans Photos via `PHAdjustmentData` ne sont lisibles que
  par notre appli ; Photos n'affiche que le rendu.
- Pas de compatibilité avec les documents `.photomator` : hors périmètre.

## 4. Choix techniques proposés (à valider)

| Sujet | Choix | Raison |
|---|---|---|
| Cible | macOS 27 minimum, Apple Silicon | poste de dev en 27.2 ; PhotoKit 27 (notes, mots‑clés, légendes), dernières API SwiftUI/Vision/Core Image |
| Langage | Swift 6 (concurrence stricte), Observation | moderne, sûr |
| UI | SwiftUI pour l'ensemble, AppKit ponctuel (`MTKView` du canevas via `NSViewRepresentable`, menus, panneaux) | même mélange que Photomator |
| Rendu | Core Image sur contexte Metal, filtres natifs + `CIKernel` Metal maison si besoin | pipeline non destructif naturel, GPU, RAW via `CIRAWFilter` |
| Bibliothèque Photos | PhotoKit : `PHPhotoLibrary`, `PHCachingImageManager`, `PHFetchResultChangeDetails`, `PHAdjustmentData` | identique à l'approche observée |
| Bibliothèque fichiers | `NSOpenPanel` + security‑scoped bookmarks, scan asynchrone, `QuickLookThumbnailing`, `FSEvents`/`DispatchSource` pour la surveillance | sandbox‑compatible |
| Persistance | SwiftData (index de bibliothèque, vignettes en cache disque) ; recette d'édition en JSON `Codable` (sidecar à côté du fichier, et `PHAdjustmentData` pour Photos) | lisible, versionnable, testable |
| Import/export | ImageIO (`CGImageSource`/`CGImageDestination`), métadonnées EXIF/IPTC/XMP conservées | natif, tous formats |
| Analyse d'image | Vision (horizon, sujet/masque de premier plan, saillance, personnes), Core Image (auto‑enhance, histogramme) | remplace les modèles maison |
| Structure | monorepo Xcode + paquets SwiftPM locaux : `EditModel`, `RenderEngine`, `LibraryKit`, `ImageIOKit`, `App` | découpage testable, ouvre la porte à iPad plus tard |
| Projet Xcode | généré par **XcodeGen** (`project.yml`) | éditable en texte, diff lisible |

## 5. Feuille de route

### Phase 0 — Cadrage et étude (en cours)

- [x] Reconnaissance initiale de Photomator avec REA (ce document, §2).
- [x] Inventaire fonctionnel de Photomator (sans décompilation) :
      `docs/inventaire-photomator.md`. Reste : flux UI, plages et valeurs par défaut
      des paramètres, points du §7 de l'inventaire (décompilation nécessaire).
- [x] Liste des ajustements et de leurs paramètres (noms ; plages à compléter).
- [x] Choix du §4 validés, décisions au §7.
- [x] Xcode 27.1 (SDK macOS 27), XcodeGen, xcbeautify, swiftformat, exiftool installés.
- [x] Décision : pas de décompilation (cadre légal, §3.1). Ghidra abandonné.
- [ ] Séance d'observation de l'UI de Photomator en marche (REA `observe_native_ui`),
      écran par écran, pour documenter les flux avant de dessiner ceux de Qaama.
- [ ] Expérimentations en boîte noire sur mes propres photos : contenu d'un sidecar,
      où partent note / drapeau / rejet, appariement RAW+JPEG, réglage « Modify
      originals ». Résultats à consigner dans l'inventaire.

### Phase 1 — POC (valider les briques risquées)

But : prouver que les trois briques critiques tiennent, sans soin de l'UI.

- [x] Squelette Xcode (XcodeGen), app SwiftUI sandboxée, cible macOS 27, signature ad hoc,
      paquet `LibraryKit` (29/10/2026).
- [ ] **Brique rendu** : ouvrir un JPEG/HEIC/RAW, afficher dans un canevas Metal
      (zoom/pan), 3 curseurs (exposition, contraste, saturation) appliqués en
      temps réel via Core Image, export JPEG. Mesurer la latence sur une image 24–48 Mpx
      et un RAW.
- [ ] **Brique Photos** : demander l'accès, afficher une grille des photos récentes
      (`PHCachingImageManager`), ouvrir une photo dans le canevas, réécrire un
      ajustement dans Photos via `PHAdjustmentData` et le relire.
      Fait le 29/10/2026 : accès, grille des 400 photos les plus récentes, vue pleine
      taille. Reste : `PHAdjustmentData`, suivi des changements, mesure des performances.
- [ ] **Brique fichiers** : choisir un dossier, le scanner récursivement, afficher les
      vignettes, conserver l'accès au redémarrage (bookmark).
- [ ] Bilan : ce qui marche, ce qui coince, décisions pour le MVP.

### Phase 2 — MVP (une appli utilisable au quotidien)

Bibliothèque

- [ ] Vue unifiée Photos + dossiers, barre latérale (albums, dossiers, favoris, récents).
- [ ] Grille performante (vignettes en cache, prefetch), tri et filtres (date, type,
      RAW, édité/non édité, favoris), recherche simple.
- [ ] Appariement RAW + JPEG, détection des sidecars, mise à jour en direct des
      changements (Photos et système de fichiers).
- [ ] Inspecteur : métadonnées EXIF, histogramme, localisation (MapKit).

Éditeur

- [ ] Pile d'ajustements non destructive, ordonnée, activable/désactivable, avec
      undo/redo et comparaison avant/après.
- [ ] Ajustements de base : balance des blancs, exposition, contraste, luminosité,
      hautes lumières/ombres, saturation/vibrance, netteté, réduction de bruit simple,
      vignettage, grain, courbes, niveaux, teinte/saturation sélective, noir et blanc.
- [ ] Recadrage, redressement, rotation, perspective simple.
- [ ] Préréglages (sauvegarde/import de recettes), copier/coller les ajustements.
- [ ] Persistance : sidecar JSON pour les fichiers, `PHAdjustmentData` pour Photos.

Export

- [ ] Export unitaire et par lot (format, qualité, taille, métadonnées, profil couleur).
- [ ] Enregistrement dans Photos ou dans un dossier, partage système.

Qualité

- [ ] Tests unitaires `EditModel`/`RenderEngine` (rendu de référence par image
      golden), tests de la couche bibliothèque sur un dossier de fixtures.
- [ ] Journalisation `OSLog`, mesures de performance (Instruments).

### Phase 3 — Au-delà du MVP (selon l'envie)

- [ ] Fonctions « intelligentes » via Vision/Core Image : auto‑amélioration, redressement
      automatique de l'horizon, masque de sujet / arrière‑plan, ajustements par zone
      (pinceau, dégradé, masque ML).
- [ ] Super‑résolution et débruitage via modèles open source convertis en Core ML.
- [ ] Outil de retouche/suppression d'objets (approche simple d'abord : clonage,
      inpainting basique).
- [ ] Extension d'édition pour Photos (`PHEditingExtension`) et extension de partage.
- [ ] HDR (gain map, EDR sur écran compatible), vidéo courte peut‑être.
- [ ] iCloud (si compte développeur), puis déclinaison iPad si le cœur reste portable.

## 6. Outils à installer côté poste

- **Xcode** (en cours) : indispensable. Vérifier ensuite
  `sudo xcode-select -s /Applications/Xcode.app` et accepter la licence.
- **XcodeGen** (`brew install xcodegen`) : génération du projet depuis `project.yml`.
- **xcbeautify** (`brew install xcbeautify`) : sortie de build lisible dans le terminal.
- **swiftformat** ou **swift-format** (`brew install swiftformat`) : formatage.
- **exiftool** (`brew install exiftool`) : vérifier les métadonnées exportées.
- Un petit jeu d'images de test : quelques RAW (idéalement de ton propre appareil),
  des HEIC iPhone avec gain map HDR, des JPEG lourds, un PNG avec transparence.

## 7. Décisions prises (29 octobre 2026)

1. **Nom** : Qaama (« lumière » en kalaallisut, écho à « camera »). Vérifier la
   disponibilité App Store / domaine avant toute publication.
2. **Cible** : **macOS 27 minimum** (décision du 29/10/2026, poste mis à jour en 27.2),
   on suit les dernières avancées d'Apple. Le SDK 27 (livré avec Xcode 27.1) ajoute à PhotoKit la note
   par étoiles (`PHAsset.rating`, `PHAssetChangeRequest.rating`), les mots‑clés
   (`addKeyword`/`removeKeyword`), la légende, et le choix RAW/JPEG de l'original
   (`revertAssetContentToOriginalResourceChoice`), ce qui évite de stocker nous-mêmes
   le tri (notes, mots‑clés) hors de Photos. Core Image 27 ajoute la liste des
   appareils RAW pris en charge et le téléchargement à la demande des décodeurs RAW ;
   Vision 27 une segmentation itérative. Cibles de déploiement passées à 27.0.
3. **Plateforme** : macOS uniquement pour l'instant. Règle de portabilité : les paquets
   cœur (`EditModel`, `RenderEngine`, `LibraryKit`, `ImageIOKit`) n'importent jamais
   AppKit, pour garder un portage iPad possible (seule la couche UI serait à refaire).
4. **Compte développeur** : gratuit, tout en local. Passage au programme payant
   seulement si une fonctionnalité l'exige (iCloud, TestFlight).
5. **RAW** : moteur Apple (`CIRAWFilter`) exclusivement. Appareil de référence :
   Fujifilm X-T30 (fichiers RAF, capteur X-Trans).
6. **Priorité MVP** : la bibliothèque d'abord, avec très vite quelques ajustements
   basiques dans l'éditeur.
