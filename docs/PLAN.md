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
| Persistance | SQLite via GRDB derrière `CatalogStore` (index de bibliothèque, décidé le 29/10/2026), aperçus en cache disque ; recette d'édition en JSON `Codable` (sidecar à côté du fichier, et `PHAdjustmentData` pour Photos) | lisible, versionnable, testable |
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
- [x] **Brique rendu** : ouvrir un JPEG/HEIC/RAW, afficher dans un canevas Metal
      (zoom/pan), 3 curseurs (exposition, contraste, saturation) appliqués en
      temps réel via Core Image, export JPEG. Mesurer la latence sur une image 24–48 Mpx
      et un RAW.
      Fait le 29/10/2026 : paquets `EditModel` (recette JSON versionnée) et `RenderEngine`
      (CIRAWFilter pour les RAW, pipeline Core Image, `MTKView` piloté par `setNeedsDisplay`,
      export JPEG sRGB). Éditeur dans la colonne principale avec pincement, glisser,
      double-clic. Sauvegarde non destructive : sidecar `<fichier>.qaama` pour les dossiers,
      `PHAdjustmentData` + JPEG rendu pour Photos (à vérifier à l'usage).
      Leçon : une `CAMetalLayer` n'affiche rien dans une feuille `.sheet` SwiftUI sur
      macOS 27 (contenu composé hors écran) ; l'éditeur vit donc dans la fenêtre.
      Sortie 8 bits sRGB pour l'instant ; l'EDR (rgba16Float + P3 linéaire) viendra plus tard.
- [ ] **Brique Photos** : demander l'accès, afficher une grille des photos récentes
      (`PHCachingImageManager`), ouvrir une photo dans le canevas, réécrire un
      ajustement dans Photos via `PHAdjustmentData` et le relire.
      Fait le 29/10/2026 : accès, grille de toute la photothèque, vue pleine taille,
      note par étoiles native (PhotoKit 27, touches 0–5), suivi des changements de la
      photothèque, mesure du temps de listage (journal `OSLog`, sous-titre de fenêtre).
      Mesuré : 74 000 photos listées en 2,8 s ; la notation rafraîchit la liste de façon
      incrémentale (avant : reconstruction complète, ~1,5 s de latence perçue).
      `PHAdjustmentData` écrit et relu avec la brique rendu (29/10/2026).
      Vignettes des photos modifiées (29/10/2026) : aperçu 2048 px du vrai rendu mis en cache
      (`PreviewCache`, dossier Caches, clé = identifiant + date du sidecar), vignettes découpées
      dedans, reconstruction en arrière-plan si l'aperçu manque. Remise à zéro = suppression du
      sidecar et de l'aperçu ; côté Photos, retour à l'original.
- [ ] **Brique fichiers** : choisir un dossier, le scanner récursivement, afficher les
      vignettes, conserver l'accès au redémarrage (bookmark).
      Fait le 29/10/2026 : barre latérale Photos + dossiers, ajout via `fileImporter`,
      scan récursif (`FileManager` + en-têtes ImageIO : dimensions, orientation, date
      EXIF), vignettes Quick Look, pleine taille via ImageIO (moteur RAW d'Apple),
      signets sécurisés dans `UserDefaults`, protocole `LibrarySource` commun aux deux
      sources. Reste : notes pour les fichiers (sidecar), vérifier le temps de scan et la
      qualité RAW sur les RAF du X-T30.
- [x] Bilan : ce qui marche, ce qui coince, décisions pour le MVP (29/10/2026, ci-dessous).

### Bilan du POC (29/10/2026)

Principe retenu avec Michaël : le POC et le MVP ne sont pas du code jetable. Le projet peut
devenir un vrai logiciel, donc l'architecture, les tests et la réutilisabilité comptent dès
maintenant (règles dans `AGENTS.md`).

**Ce qui marche**

- Photothèque Apple : accès, grille de 74 000 photos, notation native, suivi des changements,
  ouverture de l'original (RAW compris) et sauvegarde non destructive via `PHAdjustmentData`.
- Dossiers : ajout, signets persistants, scan récursif, vignettes Quick Look, sidecar `.qaama`,
  cache d'aperçus du vrai rendu.
- Rendu : Core Image sur Metal, RAW par CIRAWFilter, trois curseurs fluides, export JPEG.
- Masque ciel : faisable avec DETR (Apache 2.0) + segmentation par clic de Vision 27.
- 16 tests unitaires hermétiques sur les modèles, le scanner, le cache, le pipeline et le
  rendu hors écran.

**Ce qui coince (mesuré)**

- Listage complet de la photothèque : 1,6 à 2,8 s, en mémoire, refait à chaque lancement.
- Scan de dossier : 15 à 20 ms par fichier (en-têtes ImageIO), inacceptable au-delà de
  quelques centaines de RAW.
- Sortie 8 bits sRGB seulement (pas d'EDR), pas de notes ni de drapeaux pour les fichiers.
- Une `CAMetalLayer` ne s'affiche pas dans une feuille `.sheet` SwiftUI sur macOS 27.

**Dette d'architecture à rembourser avant d'empiler des fonctions**

1. **Identifiants stables.** `LibraryAsset.id` est le chemin du fichier : un renommage ou un
   déplacement casse le sidecar, le cache d'aperçus et les futures notes. Introduire un
   catalogue persistant (SQLite via GRDB, voir `docs/catalogue.md`) avec un identifiant propre à Qaama, le chemin et une
   empreinte (taille + date + hachage partiel) pour retrouver les fichiers déplacés.
2. **Listage en deux temps.** Lister d'abord (nom, type, dates système), lire les en-têtes
   (dimensions, EXIF) en arrière-plan par lots et les conserver dans le catalogue. Même
   logique côté Photos : index persistant et chargement paresseux de `PHFetchResult`.
3. **Modèle de l'éditeur.** `EditorView` porte encore le chargement, le rendu, la
   sauvegarde et l'export. Extraire un `EditorModel` observable testable, la vue ne gardant
   que l'affichage.
4. **Recette extensible.** `EditRecipe` est un struct à trois champs. Passer à une liste
   ordonnée d'ajustements typés (avec activation, et plus tard masque) avant d'ajouter le
   moindre réglage, pour ne pas migrer le format vingt fois ; le champ `version` existe déjà.
5. **Sidecar = métadonnées, pas seulement recette.** Le fichier `.qaama` doit porter notes,
   drapeaux, mots-clés et recette, versionné, pour les photos hors Photos.
6. **Paquet `ImageIOKit`.** `FileImageLoader` et la lecture d'en-têtes de `FolderScanner`
   vivent dans LibraryKit ; les regrouper dans le paquet prévu, réutilisable par l'éditeur.
7. **Vues.** Découper `AssetGridView` et `EditorView` en composants, ajouter des aperçus
   SwiftUI avec des sources factices (`LibrarySource` est un protocole, c'est facile).

Conception détaillée des fondations de données : `docs/catalogue.md`. Réalisée le 29/10/2026 :
catalogue SQLite (GRDB) derrière `CatalogStore`, sidecar v2 (identifiant, note, drapeau,
mots-clés, recette), listage en deux phases avec identité stable au renommage et au
déplacement (le sidecar suit l'image), notes, drapeaux et mots-clés dans l'interface pour les
dossiers (mots-clés aussi pour Photos, en natif), listage paresseux de Photos (74 000 photos
en 0,7 s, lignes construites à l'affichage). Le 30/10/2026 : recette v2 en calques
d'ajustements typés (point 3), `EditorModel` dans le paquet `EditorKit` avec undo/redo relié
au menu Édition (point 5), vues découpées avec aperçus SwiftUI sur `SampleLibrarySource`
(point 7). Dette d'architecture du bilan POC entièrement remboursée.

**Décisions proposées pour le MVP**

- Ordre : (a) dette 1, 2, 4 et 5 (fondations de données), (b) bibliothèque riche (albums,
  tri, filtres, notes et drapeaux partout), (c) éditeur : pile d'ajustements, balance des
  blancs, hautes lumières/ombres, recadrage, avant/après, undo/redo, (d) masques.
- EDR et couleur P3 : à la reprise du canevas, pas avant.
- Photos reste la référence pour ses propres vignettes et métadonnées ; Qaama n'indexe que
  ce qu'il faut pour trier et filtrer.

### Étude de faisabilité : masque « ciel » (29/10/2026)

Demande de Michaël : vérifier tôt que le masque ciel est faisable sans modèle propriétaire,
avant de poursuivre. Prototype dans `Experiments/sky-mask/`, testé sur 13 photos du dossier
d'essai (JPEG 2 Mpx et 26 Mpx, un RAF).

- **Apple fournit les masques sujet, arrière-plan et personnes** (Vision), et sur macOS 27 une
  segmentation « par clic » (`GenerateIterativeSegmentationRequest`, amorce par point,
  rectangle ou gribouillis, points à inclure/exclure). Pas de classe « ciel » publique.
- **Modèle tiers légal** : `apple/coreml-detr-semantic-segmentation` (Apache 2.0, 85 Mo),
  classes COCO panoptique dont `sky (other)`. Détection automatique correcte sur toutes les
  photos de test, mais masque calculé en 448 × 448 donc bords grossiers.
- **Mesures** : DETR 70 à 110 ms par image après chauffe (3,5 s de chargement + 2,3 s au
  premier appel) ; segmentation par clic 80 ms en 2 Mpx, 130 à 200 ms en 26 Mpx, bords fins,
  ressources téléchargées par le système au premier usage (3,9 s).
- **Conclusion : faisable.** Pipeline retenu pour la phase 3 : DETR trouve le ciel, son masque
  sert d'amorce (gribouillis) à la requête Vision qui affine les bords ; l'utilisateur corrige
  par points inclus/exclus. Le même DETR donne aussi mer, route, herbe, bâtiment, etc. Peau et
  cheveux restent hors de portée sans modèle dédié.

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
      undo/redo et comparaison avant/après. Fait le 30/10/2026 : calques dans la recette,
      undo/redo par geste relié au menu Édition. Reste : interface des calques, avant/après.
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
