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

### Étude de faisabilité : pinceau correcteur (9/11/2026)

Demande de Michaël : un outil de retouche en pinceau, de taille réglable, qui efface un objet
« intelligemment », si possible sans modèle d'IA. Prototype dans `Experiments/heal/`, testé sur
six scènes de synthèse de 1200 × 900 (ciel nuageux, herbe, briques, horizon, sable), avec du
grain, faute d'avoir le dossier de photos d'essai.

- **Deux méthodes sans modèle comparées.** (1) Correcteur par source : une zone de même forme
  copiée d'ailleurs, raccordée par une membrane (fusion de Poisson). (2) Remplissage par patchs
  7 × 7 du flou vers le net (Wexler et al. 2007) : chaque patch touchant le trou cherche son
  plus proche semblable autour, chaque pixel du trou prend la moyenne pondérée des propositions,
  la dernière passe ne garde que la meilleure pour conserver texture et grain.
- **Le remplissage par patchs réussit les six scènes**, y compris celles où une source unique
  échoue : objet à cheval sur l'horizon (la source laisse un fantôme flou), fil traversant
  l'image et grande serviette (aucune zone de même forme disponible). Briques réalignées,
  rides du sable prolongées. Défaut : un léger contour visible sur l'herbe et le ciel, qu'une
  membrane fine au bord devrait effacer.
- **Mesures** : 22 à 104 ms en 1200 × 900 ; sur les mêmes scènes agrandies en 17 Mpx, 380 ms
  pour un fil traversant l'image, 390 ms pour un objet de 600 px, 1,1 s pour 1364 × 1044 px.
  Le calcul ne porte que sur les alentours du trou (4 fois son épaisseur, 48 à 600 px). Donc
  calculable au relâchement du trait, en tâche de fond, jamais par mouvement de curseur.
- **Brevets** : PatchMatch (recherche aléatoire, Adobe, US 8 285 055, déposé en février 2009)
  serait en vigueur jusque vers 2029. Le prototype s'en passe : recherche exhaustive à
  l'échelle la plus grossière, puis locale et par cohérence avec les voisins (Ashikhmin 2001).
  L'inpainting par exemplaires de Criminisi (Microsoft, déposé en 2003) aurait expiré vers
  2023. Statuts à vérifier auprès de l'office avant de livrer.
- **Limite** : les scènes de synthèse sont favorables (textures identiques partout). Sur de
  vraies photos, attendre des répétitions et des lignes tordues quand le trou grandit ou
  couvre une structure unique ; c'est là qu'un modèle (LaMa, Apache 2.0) prendrait le relais.
- **Essai sur trois photos de Michaël (10/11/2026, 1280 px)**, zones peintes à la main.
  Bateau bleu sur l'eau avec son reflet : propre (71 ms). Poteaux électriques et sept câbles
  sur ciel bleu : ciel propre, pied du poteau plausible devant clôture et arbres, mais barbelé
  interrompu et un fragment de piquet dans le ciel (135 ms). Escargot sur gravier vert en
  perspective : l'escargot disparaît mais la zone se voit, gravier de la mauvaise taille (pris
  plus près de l'objectif) et plage plus sombre à bord net (109 ms).
- **Leçons des vraies photos** : (1) le masque doit couvrir tout l'objet, chaque oubli (cou de
  l'escargot, câble décalé de quelques pixels) est recopié dans le remplissage comme du fond ;
  prévoir de dilater la zone peinte et de pouvoir repasser sur un reste à peu de frais.
  (2) La perspective est la première vraie limite : une texture dont l'échelle varie n'a pas de
  patch de la bonne taille au bon endroit ; réduire la zone de recherche n'y change rien.
  (3) Les zones fines (câbles, poteaux) sont le meilleur cas, même sur fond détaillé.
- **Retour de Michaël (10/11/2026)** : « assez propre même si pas parfait » ; très bien sur
  le ciel, dommage que la texture des arbres ne soit pas reprise là où un poteau passait
  devant un arbre ; on ne fera sans doute pas beaucoup mieux pour le moment. Vérifié : à ces
  endroits le remplissage pose une bande de ciel uni. Piste essayée sans succès : ajouter des
  caractéristiques de texture à la comparaison des patchs (gradient absolu moyen, Newson et
  al. 2017, option `--texture`) ; à poids 50 la bande reste, à 200 de l'herbe et un arbre
  entier arrivent dans le ciel. Prolonger une structure unique (branches, toit) dépasse les
  patchs : ce sera le rôle d'un modèle. L'option reste dans le prototype, désactivée.
- **Conclusion : faisable sans modèle pour une première version**, sur la base du remplissage
  par patchs, bonne pour les objets fins ou petits et les fonds réguliers ; les gros objets
  sur texture en perspective resteront visibles tant qu'il n'y a pas de recherche à plusieurs
  échelles ou de modèle.

### Phase 2 — MVP (une appli utilisable au quotidien)

Bibliothèque

- [ ] Vue unifiée Photos + dossiers, barre latérale (albums, dossiers, favoris, récents).
      Gestion des albums de Photos, fait le 6/11/2026 à la demande de Michaël : créer un album
      ou un dossier d'albums (menu contextuel de la ligne Albums pour la racine, d'un dossier
      pour y créer dedans, et File › New Album… / New Album Folder…), supprimer un album après
      confirmation, glisser des vignettes sur un album de la barre latérale, Add to Album
      (arborescence, avec New Album… en tête pour créer depuis la sélection), Add to “<dernier
      album>” (⌃⌘A, comme Photos ; retenu dans les préférences) et Remove from Album, dans le
      menu contextuel des vignettes et dans le menu Image (sélection de la mosaïque ou photo
      ouverte dans l'éditeur, par la valeur de focus `albumsCommand` ; pas de retrait depuis
      l'éditeur, où l'on parcourt l'album).
      - Architecture : protocole `PhotosAlbumLibrary` (identifiants seulement),
        `PhotoKitAlbumLibrary` pour PhotoKit (`canPerform` vérifié avant chaque demande, sinon
        la demande de changement est nil et ne fait rien en silence), `PhotosAlbumEditor` par
        dessus, tenu par le catalogue : c'est lui qui rend tout annulable.
      - Annulation : un album recréé par une annulation reçoit un nouvel identifiant de Photos.
        L'éditeur garde la correspondance ancien → nouveau, pour que les étapes antérieures de
        la pile (et le dernier album) le retrouvent, et enchaîne les changements un par un : un
        rétablissement dépend de ce que l'annulation d'avant a produit, et l'annulation est
        enregistrée avant que son travail ait tourné (`PendingStep`). Un album supprimé revient
        avec son titre, son dossier et ses photos ; des photos retirées reviennent en fin
        d'album (leur place dans l'ordre manuel de Photos n'est pas rendue) ; un dossier créé
        n'est défait que s'il est encore vide (Photos supprime un dossier avec son contenu).
      - Mesure par sonde (fenêtre hors écran, 40 vignettes, menu de 800 entrées) : SwiftUI
        exécute la closure d'un menu contextuel pour chaque vignette à chaque mise à jour de la
        mosaïque (280 fois en 7 mises à jour), mais n'évalue le `body` d'une vue placée dedans
        qu'à l'ouverture du menu (0 fois). L'arborescence des albums est donc une vue à part
        (`AlbumMenuItems`). Dans la barre de menus, elle est `Equatable` avec une cible stable
        à la place d'une closure, pour ne pas être reconstruite à chaque changement de
        sélection ; ce second point n'est pas mesuré.
      - Bogue vu par Michaël le 6/11/2026 : le sous-menu Add to Album se refermait tout seul au
        bout de 2 à 3 s, le menu contextuel restant ouvert. Cause, établie par sonde (menu ouvert
        par `menu(for:)` puis `popUpContextMenu`, identités des `NSMenuItem` relevées toutes les
        100 ms ; lancer la sonde depuis un timer du run loop, pas depuis la main queue, sinon les
        mises à jour SwiftUI ne passent pas pendant le suivi du menu) : à chaque mise à jour de la
        vue qui porte `.contextMenu`, SwiftUI remplace tous les éléments de premier niveau du menu
        ouvert (le sous-menu, lui, est réutilisé), ce qui ferme le sous-menu déployé. Or la
        photothèque de Michaël changeait toutes les 1 à 2 s ce jour-là (analyse ou synchro de
        Photos, 4 506 photos modifiées depuis le lancement précédent) et chaque changement
        reconstruit la mosaïque. Avec un contenu stable, il reste un unique remplacement, à la
        première mise à jour de la fenêtre après l'ouverture du menu. Correction : chaque vignette
        est une `AssetGridCell` `Equatable` (photo, index, sélection, état du menu, identités de
        la source et d'un objet `AssetGridActions` qui porte les closures), donc les mises à jour
        de la mosaïque ne l'atteignent pas ; et la mosaïque se met à jour elle-même à
        `NSMenu.didBeginTrackingNotification` pour consommer l'unique remplacement avant qu'un
        sous-menu soit ouvert (sonde : plus aucun remplacement ensuite). La barre de menus n'a
        pas ce défaut (sonde : éléments inchangés quand les commandes se réévaluent). Leçon
        générale : une vue qui porte un menu contextuel avec sous-menu doit avoir des entrées
        stables. Non vérifié à l'écran par moi ; à confirmer par Michaël.
      - Journal de Michaël au lancement : « Listed 787 albums in 222 folders in 266 ms »
        (Debug). La liste est relue tout de suite après une création ou une suppression (pour
        pouvoir sélectionner le nouvel album), puis une seconde fois à la notification de
        Photos : environ une demi-seconde sur l'acteur principal par création. À sortir de
        l'acteur principal si ça se sent.
      - Vérifié : 10 tests de `PhotosAlbumEditor` sur une fausse photothèque (annulation,
        rétablissement, identifiants remplacés, ordre des changements, échecs), compilation et
        lancement. Non vérifié à l'écran : tout ce qui écrit dans la vraie photothèque, le
        glisser-déposer (départ depuis la mosaïque à côté des clics de sélection, surbrillance
        et dépôt sur la ligne d'album), le dialogue de nom et la fluidité des menus avec 787
        albums.
      - Recherche d'un album par son nom, fait le 12/11/2026 à la demande de Michaël (787
        albums : l'arborescence du menu est longue à parcourir) : Add to Album › Search… en tête
        du sous-menu (menu contextuel et menu Image, ⌥⌘A) ouvre une feuille avec le champ en
        haut et les albums trouvés dessous, tous dossiers confondus, le chemin des dossiers en
        gris à droite (icônes d'album et de dossier de la barre latérale, en gris, ajoutées le
        jour même : la liste en texte seul était « un peu austère »). Le clavier reste dans le champ : flèches pour déplacer la surbrillance,
        Retour pour ajouter, clic sur une ligne pour la choisir. L'album affiché est écarté.
        - Pourquoi pas un champ dans le menu lui-même : un `Menu` SwiftUI n'accepte pas de champ
          de saisie, et le SDK 27.2 n'ajoute rien à `NSMenu` pour ça. Il faudrait reconstruire le
          menu contextuel en AppKit (`NSMenuItem.view`) et y perdre ce qui a été réglé le 6/11.
        - Règle de recherche, celle de `SearchText` (sans casse ni accents, par morceau de mot) :
          chaque mot tapé doit se trouver dans le titre de l'album ou dans le nom d'un de ses
          dossiers. Ordre : titre qui commence par la saisie, puis mots en début de mot, puis
          n'importe où dans le titre, puis trouvé grâce à un dossier ; par titre à rang égal.
        - Architecture : `PhotosAlbumSearch` (index plié et trié une fois, interrogé à chaque
          frappe) et `PhotosAlbumPickerModel` (saisie, résultats, surbrillance) dans LibraryKit,
          `AlbumSearchView` dans l'app. La liste est dessinée à la main (`LazyVStack`) : une
          `List` prendrait le focus pour montrer sa sélection.
        - Le champ est le champ de recherche du système (`SearchField`, un `NSSearchField` :
          SwiftUI ne le propose que par `.searchable`, lié à une barre d'outils). Le premier jet,
          un `TextField` nu dans un rectangle gris, était une imitation : pas de bouton d'effacement
          et une couleur à moi, ce que Michaël a relevé. Flèches et Retour passent par le délégué
          (`doCommandBy`) ; Échap efface d'abord la saisie, puis ferme, comme partout dans macOS.
        - Bogue vu par Michaël le 13/11/2026 sur sa bibliothèque : des titres tronqués à côté
          d'un vide. Cause : `frame(maxWidth:)` sur le chemin des dossiers prend toute la largeur
          permise même quand le chemin est court (mes données de sonde n'avaient que des chemins
          longs). Remplacé par un `Layout` (`TitleAndDetailLayout`) : le chemin reçoit ce qu'il
          demande jusqu'à un plafond, le titre le reste, et ce que le titre laisse revient au
          chemin. Leçon : sonder avec des données de la forme de celles de Michaël (titres longs,
          chemins courts « 2010 › 05 - Mai »).
        - Relu les pages Sheets, Lists and tables et Buttons des guidelines le 13/11/2026 :
          conforme pour la feuille (tâche courte, Cancel et un seul bouton mis en avant, verbe),
          l'ellipse au milieu des titres et l'icône en tête de ligne. Écart connu : la liste
          est dessinée à la main (couleurs de sélection du système reprises).
        - Feuille redimensionnable (la page Sheets le conseille quand le contenu y gagne), sa
          taille retenue dans les préférences. Sonde : un cadre flexible ne suffit pas (la feuille
          garde 470 pt de large et n'est pas redimensionnable) ; il faut en plus
          `.presentationSizing(.fitted)`, et la taille idéale devient la taille d'ouverture
          (bornes 380 × 280 à 900 × 1000 reprises par la fenêtre de la feuille). Non vérifié à
          l'écran : le redimensionnement à la souris.
        - Question de Michaël : réutiliser le champ de recherche du menu Aide ? Non : AppKit ne
          l'installe que dans le menu Aide (`NSApplication.helpMenu`). On peut seulement y ajouter
          des résultats (`NSUserInterfaceItemSearching`). En revanche il cherche déjà dans tous
          les éléments de la barre de menus, donc en principe dans les albums du menu Image ; non
          essayé.
        - Mesure (Debug, 888 albums dans 222 dossiers) : index construit en 9 ms, une frappe
          1 à 2 ms.
        - Vérifié : 10 tests, et par sonde dans une vraie feuille hors écran : le focus arrive
          dans le champ, les flèches déplacent la surbrillance, Retour ajoute une seule fois (par
          le champ comme par le bouton par défaut), Échap efface puis ferme, captures claires et
          sombres avec titres et dossiers longs. Non vérifié à
          l'écran : l'élément Search… dans les deux menus et son raccourci.
      - Reste : renommer et déplacer un album ou un dossier, supprimer un dossier, glisser sur
        Favoris, faire suivre le jumeau JPEG d'un RAW ajouté à un album, raccourci pour Remove
        from Album, filtrer les albums de la barre latérale par leur nom.
- [ ] Grille performante (vignettes en cache, prefetch), tri et filtres (date, type,
      RAW, édité/non édité, favoris), recherche simple.
      Fait le 30/10/2026 : tri (dates, note, nom), filtres (note, drapeau, modifié, RAW,
      favoris), recherche noms et mots-clés pour les dossiers ; Photos en natif pour dates,
      favoris, note (prédicats confirmés par sonde, PhotoKit ne documente pas la note).
      Prefetch des vignettes Photos le 30/10/2026 (fenêtre de 60 lignes autour de l'écran via
      `PHCachingImageManager`, libérée au-delà). Reste : filtre par type de fichier.
- [x] Zoom de la mosaïque et mode d'affichage, cadré avec Michaël le 7/11/2026 : taille des
      vignettes réglable par un curseur dans la barre d'outils et par le menu View (⌘+ / ⌘−),
      et choix entre le carré rogné actuel et la photo entière dans un carré, sans rognage ;
      les deux réglages mémorisés entre les sessions (`@AppStorage`, comme l'inspecteur). La
      taille et le mode deviennent des entrées de `AssetGridCell` (règle `Equatable` dans
      AGENTS.md) ; `AssetThumbnailView` passe en `scaledToFit` avec une demande `aspectFit` à
      la source, et `LibraryAsset.aspectRatio` permet de réserver la place avant la vignette.
      Fait le 7/11/2026 :
      - `GridDisplay` (app) tient les clés de préférences, la plage 80–400 pt, le pas de 40 pt
        de Zoom In / Zoom Out (sur une grille de multiples, quelle que soit la position du
        curseur) et l'arrondi des pixels demandés au pas de 128 px : un glissement du curseur ne
        recharge les vignettes visibles qu'en franchissant un pas, et le prefetch Photos demande
        exactement la même taille (PhotoKit met en cache par taille et mode de contenu ; un
        changement de l'un ou l'autre vide son cache, `stopCachingImagesForAllAssets`).
      - `ThumbnailFit` (LibraryKit, `fill` / `fit`) est passé à `thumbnail(for:pixelSize:fit:)`
        et à `prefetchThumbnails(around:pixelSize:fit:)` ; l'ancienne signature reste en
        extension (`fill`) pour l'export, le dialogue de date et l'histogramme. Photos : mode de
        contenu `aspectFill` / `aspectFit`. Dossiers : Quick Look et `PreviewCache` ajustent dans
        une boîte, donc en mode carré la boîte demandée a le rapport de la photo (petit côté =
        côté du carré, rapport borné à 4 pour les panoramas) ; avant, la vignette d'une photo
        non carrée était demandée au carré puis agrandie à l'affichage, donc légèrement floue.
        Tests : `ThumbnailFitTests`.
      - Les commandes du menu View ne sont actives que lorsque la mosaïque est à l'écran (valeur
        de focus `hasAssetGrid`), pas dans l'éditeur.
      - En mode photo entière, la sélection et les badges suivent le rectangle de la photo, pas
        le carré ; une fois les pixels chargés, leur rapport l'emporte sur `aspectRatio` (une
        photo recadrée par une recette change de forme) : léger saut dans ce cas, accepté.
      - Vu par Michaël le 7/11/2026 : le curseur marche ; ses icônes touchaient les bords de la
        capsule Liquid Glass (la barre d'outils dessine la capsule sur les bornes de la vue) :
        marge horizontale de 8 pt ajoutée. Icônes de grille gardées plutôt que des loupes, qui
        diraient « zoom de l'image » : le curseur choisit entre beaucoup de petites vignettes et
        peu de grandes.
      - Pincement sur la grille (8/11/2026, à la demande de Michaël) : `MagnifyGesture` en
        `simultaneousGesture` sur le `ScrollView`, borné à la plage du curseur ; macOS distingue
        le défilement à deux doigts du pincement, pas de déclenchement en scrollant attendu. La
        rangée du haut reste en place quel que soit le moyen de zoomer (pincement, curseur,
        menu) : `GridViewport` relit la géométrie du défilement (`onScrollGeometryChange`, objet
        simple pour ne pas reconstruire la grille à chaque image), retrouve la première photo
        visible par l'arithmétique des colonnes adaptatives de `LazyVGrid`, et
        `ScrollPosition.scrollTo(y:)` replace cette photo à la nouvelle taille. Ancrage sur la
        photo sous le pointeur : plus tard, si le besoin se fait sentir.
        Bogue vu par Michaël le 8/11/2026 : en agrandissant, la grille défilait parfois nettement
        vers le haut. Cause : l'ancre était recalculée à chaque image depuis la position rapportée
        par `onScrollGeometryChange`, qui a une image de retard sur le `scrollTo` précédent ; lue
        avec la nouvelle hauteur de rangée, elle donnait une rangée plus petite à chaque pas, et
        l'erreur se cumulait (produit des rapports de hauteurs : moitié de la position pour un
        zoom ×2). Correction : l'ancre (première photo de la rangée du haut, fraction de rangée)
        est fixée au premier changement d'un zoom continu et chaque position en découle ; elle
        est abandonnée quand la position rapportée n'est pas celle demandée (défilement de
        l'utilisateur), jamais pendant un pincement.
        Second défaut vu par Michaël le 8/11/2026 : léger défilement vers le bas en agrandissant,
        surtout en haut de la grille. Mesuré par sonde (journal OSLog, fenêtre de 550 pt) : au
        repos `ScrollGeometry.visibleRect.minY` et `contentOffset.y` valent -52 (la hauteur de la
        barre d'outils, `contentInsets.top`, la grille passant dessous sur macOS 27), et
        `ScrollPosition.scrollTo(y: 500)` aboutit à `visibleRect.minY = 448` : `scrollTo(y:)`
        place la coordonnée demandée en haut de la zone sûre, sous la barre. La position lue
        s'exprime donc en `visibleRect.minY + contentInsets.top` pour être dans le repère de
        `scrollTo`, ce qui absorbe aussi la bannière d'indexation. La même sonde confirme les
        formules de `GridViewport` : 7 colonnes calculées et mesurées pour 821 pt de large et des
        vignettes de 95,3 pt, pas de rangée 107,3 pt mesuré = côté + 4 + 8.
        Troisième retour de Michaël le 8/11/2026 : encore un défilement vers le bas en
        agrandissant, vers le haut en réduisant. Ce n'est plus une erreur de calcul mais l'effet
        de l'ancrage en haut : la rangée du haut fixe, tout ce qui est sous le pointeur coule vers
        le bas quand les vignettes grossissent. Photos ancre sur la photo sous le pointeur ; fait
        de même : `MagnifyGesture.Value.startLocation` (repère du `ScrollView`, dont l'origine est
        sous la barre d'outils, donc moins `contentInsets.top`) donne la photo (colonne par le pas
        de colonne, rangée par le pas de rangée) et sa distance au haut de la zone visible, que
        chaque position recalculée conserve. Curseur et menu, sans pointeur : ancrage sur la
        photo au centre de la zone visible.
        Toujours là après ça (Michaël, 8/11/2026). Sondes (zoom simulé par pas de 8 pt, cadre
        de la cellule ancrée relevé par `onGeometryChange` dans l'espace `.scrollView`) :
        (1) le `scrollTo(y:)` est bien appliqué (2052,3 demandé, 2052,5 obtenu), mais la cellule
        n'atterrit à la position calculée qu'au premier pas et après un changement du nombre de
        colonnes ; aux autres pas elle dérive de 100 à 150 pt. La hauteur de contenu de la
        `LazyVGrid` continue d'augmenter pendant une seconde après chaque pas (13,93 M → 15,41 M
        pour 74 007 photos, loin des 17,5 M attendus) : la grille garde des hauteurs estimées pour
        les rangées hors écran et les fait converger peu à peu, donc un décalage calculé à partir
        de rangées uniformes tombe n'importe où. Leçon : avec une grille paresseuse, positionner
        par identité, jamais par décalage.
        (2) Réécriture : `.scrollTargetLayout()` sur la grille, cadres réels des cellules visibles
        remontés au `GridViewport` (`onGeometryChange(.scrollView)`, closure stable dans
        `AssetGridActions` pour garder la cellule `Equatable`), cellule ancrée = celle sous le
        point, et `ScrollPosition.scrollTo(id:anchor:)` avec un `UnitPoint` tel que le haut de la
        cellule tombe à `u × (conteneur − cellule)`. Mesuré : l'alignement se fait dans tout le
        conteneur, zone sous la barre d'outils comprise (948 pt visibles mais 1 000 pt
        d'alignement, écart constant de 16 pt corrigé en prenant `containerSize.height`), et
        l'espace `.scrollView` des cadres a la même origine. Résultat : cellule à 2,5 pt de la
        position visée à chaque pas, sans dérive, retour symétrique. L'ancre est abandonnée à la
        fin du pincement ou après 400 ms sans changement (curseur, menu), plus de comparaison de
        décalages. À confirmer par Michaël avec un vrai pincement : `startLocation` est supposé
        dans le même espace que les cadres (origine sous la barre d'outils) ; sinon, un saut
        unique d'une hauteur de barre au début du geste le trahira.
        Validé par Michaël le 8/11/2026 (« parfait »). Ajouts le même jour à sa demande : bouton
        bascule carré / photo entière dans la barre d'outils (`Toggle` en style bouton à côté du
        curseur ; Michaël n'aimait pas le symbole `aspectratio`, donc symbole dessiné
        (`ThumbnailFitSymbol`, une `Shape` remplie avec la règle pair-impair) : un cadre carré
        et dedans une photo qui le remplit ou une photo paysage avec des bandes, animée de l'un
        à l'autre), et animation des vignettes au changement de mode
        (`.animation(.snappy, value: fit)` sur la vignette, donc valable aussi depuis le menu
        View ; la préférence passe par `@AppStorage`, dont la mise à jour ne porte pas la
        transaction d'un `withAnimation`). Non vérifié à l'écran
        par moi : à confirmer par Michaël (réception du pincement par le `ScrollView`, stabilité
        de la rangée du haut, affichage de ⌘+ sur clavier français, netteté des vignettes de
        dossier en mode carré).
- [ ] Navigation par date, demandée par Michaël le 10/11/2026 (« je sais que ce voyage était en
      mai 2017, ou peut-être juin ») : plutôt que les vues Years / Months d'Apple Photos (sélection
      de photos clés, mise en page en mosaïque), une seule grille continue avec trois repères,
      valables pour Photos, ses albums et les dossiers dès que le tri est par date de prise de vue.
      Fait le 10/11/2026 :
      - **Socle** : `DateTimeline` (LibraryKit), les mois d'un listage et les rangées de chacun,
        construit en une passe sur les dates dans l'ordre du listage (le calendrier n'est
        interrogé qu'au changement de mois : 34 ms pour 74 000 dates en Debug). Les photos sans
        date forment leur propre section. `LibrarySource.timeline`, nil hors tri par date.
        Dossiers : calculé à chaque livraison du catalogue (éléments en mémoire). Photos :
        PhotoKit n'a pas de requête « nombre par mois », les dates sont lues dans le
        `PHFetchResult`, ce qui reste exact avec un album, un filtre ou une recherche.
      - **Mesures sur la photothèque de Michaël** (74 002 photos, 237 mois, Debug) : les
        1 000 premières rangées lues à l'affichage du listage en 21 ms (listage complet 157 ms,
        comme avant), toutes les dates en 1,6 s hors du fil principal. Entre les deux, la
        timeline est partielle (`isComplete` faux, une section « en attente » pour le reste) :
        la grille a ses en-têtes tout de suite et les vignettes du haut ne sont pas recréées à
        l'arrivée du reste, les sections étant identifiées par leur mois et non par leurs
        rangées.
      - **Changements de la photothèque** : Photos en signale toutes les une à deux secondes
        pendant ses analyses ; relire 74 000 dates à chaque fois ne finirait jamais. Les dates
        ne sont relues que si des photos sont ajoutées, retirées ou déplacées, ou si une photo
        modifiée a quitté son mois ; l'ancienne timeline reste en place pendant la relecture,
        ajustée au nombre de rangées (`fitted(to:)`), donc décalée de quelques rangées pendant
        1,6 s au plus.
      - **Grille** : `LazyVGrid` en sections avec `pinnedViews: [.sectionHeaders]`, cellules
        toujours identifiées par leur rangée. Sonde hors écran avant de s'engager (74 000
        cellules, 125 sections épinglées) : un saut `scrollTo(id:anchor:)` vers une rangée
        lointaine arrive en 25 ms, au point près. Leçon de la même sonde, dans une vraie fenêtre
        `WindowGroup` : le repère `.scrollView` commence sous la barre d'outils (et sous le
        bandeau d'indexation), pas en haut de la fenêtre ; les en-têtes s'épinglent à y = 0 de
        ce repère et `containerSize` exclut déjà la barre. Le commentaire de `GridViewport`
        disait l'inverse : corrigé, et le centre d'ancrage du zoom est maintenant le vrai centre
        de la zone visible (il était 26 pt trop bas).
      - **Mois affiché** dans la barre d'outils (`MonthButton`) : `GridViewport` calcule la
        première rangée visible sous l'en-tête épinglé une fois par image (pas une fois par
        cellule), et `TimelineNavigator` n'est écrit que quand le mois change : seul le bouton
        se redessine pendant le défilement.
      - **Sélecteur de mois** (`MonthPicker`, bouton de la barre d'outils ou View › Go to
        Month…, ⇧⌘T comme Go to Date de Calendrier) : tableau années × mois. Un clic amène le
        premier rang du mois juste sous son en-tête ; le sélecteur reste ouvert pour essayer le
        mois voisin. Première version : cases teintées selon le nombre de photos, nombre écrit
        dedans. Vu par Michaël le 10/11/2026 : « assez violent visuellement », une navigation
        plus simple suffit, tant pis pour les nombres. Refait le jour même en tableau sobre :
        noms de mois en texte (plus besoin de remonter à l'en-tête de colonne, où J, M et A
        étaient ambigus), mois sans photo estompés, mois affiché sur fond d'accent, survol
        discret ; le nombre de photos n'apparaît plus que sous le tableau, pour le mois survolé.
        Vu de nouveau le même jour : « la répétition est un peu dérangeante » (Jan Feb Mar… sur
        chaque ligne). Troisième version : les années en colonne à gauche, les douze mois de
        l'année choisie écrits une seule fois à droite (3 × 4) ; cliquer une année y amène la
        grille et montre ses mois.
      - **En-têtes et dates affichées**, revus le 10/11/2026 après essai par Michaël : le
        bandeau de mois épinglé sous la barre d'outils « ne s'intègre pas très bien ». Les
        en-têtes ne sont plus épinglés : un simple titre au-dessus de la première rangée du
        mois, sans fond. À la place, le sous-titre de la fenêtre donne la plage de dates des
        photos à l'écran, comme Apple Photos (« Oct 10 – Nov 2, 2021 », puis les compteurs).
        `GridViewport` donne la première et la dernière rangée visibles ; la plage n'est écrite
        dans `TimelineNavigator` que quand son texte change, et le sous-titre est posé par une
        petite vue à part (`GridSubtitle`, `navigationSubtitle` remonte d'une vue en
        arrière-plan : vérifié par sonde sur `NSWindow.subtitle`), pour que le défilement ne
        réévalue pas `LibraryContentView`.
      - Vérifié : tests (`DateTimeline`, timelines des sources dossier et d'exemple), rendu des
        vraies vues hors écran avec la bibliothèque d'exemple (en-têtes, saut à mai 2017 signalé
        en 56 ms, tri par note sans en-têtes et bouton désactivé, sélecteur), durées ci-dessus
        dans les journaux. Non vérifié à l'écran : la fluidité du défilement dans la vraie
        photothèque pendant et après la lecture des dates, l'allure de l'en-tête épinglé sous la
        barre Liquid Glass (matériau `.bar`), l'ouverture du popover depuis la barre d'outils,
        ⇧⌘T, le comportement pendant une synchronisation de Photos.
      - Pistes : cartes de mois avec photo de couverture façon Apple (favorite ou mieux notée,
        sinon une photo du jour le plus fourni), filtre par période, « mai 2017 » tapé dans la
        recherche, clic sur un en-tête pour sélectionner le mois.
- [ ] Appariement RAW + JPEG, détection des sidecars, mise à jour en direct des
      changements (Photos et système de fichiers).
      Fait le 30/10/2026 : appariement par nom (un RAW + une image non RAW dans le même
      répertoire), jumeau JPEG masqué par défaut avec option pour l'afficher, badge RAW /
      RAW+JPG sur les vignettes ; sidecars détectés et suivis depuis le 29/10. FSEvents le
      30/10/2026 : tout changement externe dans un dossier (Finder, import) relance un scan
      après 1,5 s de calme ; les écritures de Qaama lui-même sont ignorées. Côté Photos, pas de prédicat RAW dans PhotoKit : badge RAW par tuile
      visible (requête de ressources à la demande), puis index local des assets Photos (RAW,
      jumeau) construit en arrière-plan pour filtrer, et option « éditer le RAW » via la
      ressource alternative.
      Fait le 5/11/2026 : filtre RAW Only et option des jumeaux JPEG dans la photothèque Photos
      et ses albums, navigation aux flèches comprise (elle suit la requête), index local tenu à
      jour en arrière-plan. Conception dans `catalogue.md` §10. Mesures par une sonde temporaire
      dans l'app, sur la photothèque de Michaël (74 065 images, originaux surtout dans iCloud,
      build Debug) :
      - **Le RAW ne demande pas d'index.** Photos tient un album intelligent RAW
        (`smartAlbumRAW`) : 1 546 photos listées en 32 ms, identifiants énumérés en 34 ms.
        Comparé aux ressources de 2 000 assets et aux noms des 74 065 : aucun écart, paires
        RAW + JPEG comprises (79 paires en un seul asset dont le JPEG est l'original). Le filtre
        et le badge RAW sont donc complets sans attendre l'index.
      - **`PHAssetResource.assetResources(for:)` est trop lent pour un index** : 2,7 ms par
        asset en séquentiel (1,4 ms à chaud), 2,0 ms à quatre en parallèle, pareil en
        `userInitiated` et en `utility`, soit 200 s pour la photothèque. Pas d'API par lots.
      - **`PHAssetExtendedMetadata`** (macOS 27) chargé avec les assets
        (`prefetchAssetExtendedMetadata`) donne le nom d'origine et les mots-clés à 0,4 ms par
        asset (0,8 ms à la demande), quels que soient la taille des lots (200, 1 000, 5 000),
        leur dispersion et la priorité (0,41 ms en `utility`, 0,44 en `userInitiated`) : la
        priorité basse ne coûte rien ici, contrairement au décodage RAW. Mêmes noms que par les
        ressources sur 500 assets. Énumérer les 74 065 identifiants : 1,6 s.
      - **Filtrage par prédicat** `localIdentifier IN` la liste des RAW : 47 ms (59 ms sans
        filtre), `NOT IN` 80 ms, `index(of:)` correct, exact dans les 787 albums (84 contiennent
        des RAW). `fetchAssets(withLocalIdentifiers:options:)` fait aussi bien mais sans portée
        d'album. On garde donc un `PHFetchResult` (listage paresseux, tri natif, albums).
      - **Index** : table `photosAsset` du catalogue (nom, seconde de prise de vue, RAW),
        construite par lots de 1 000 en priorité `utility` : 37 s pour 74 065 photos, grille
        utilisable pendant ce temps. Il sert à reconnaître les paires RAW + JPEG stockées en deux
        assets (37 RAW et 38 JPEG chez Michaël, des Canon `IMG_…`), masquées par défaut comme
        dans les dossiers ; l'option n'apparaît que s'il en existe. Tant que la passe tourne,
        le sous-titre donne l'avancement et un bandeau prévient que des jumeaux peuvent encore
        apparaître.
      - **Reprise et mise à jour** par l'historique persistant de PhotoKit
        (`PHPersistentChangeToken`, 608 octets archivés, et l'observateur de macOS 27) : un seul
        chemin au lancement et en direct. Le jeton n'est enregistré qu'en fin de passe, une passe
        interrompue reprend donc sur les assets absents de l'index. Relancement vérifié : rien
        à relire, puis 3 assets relus en 59 ms après un changement.
      - **Lancement** : l'ensemble RAW de la session précédente est lu dans le catalogue (34 ms)
        puis corrigé par l'album intelligent en tâche de fond ; le lire d'abord dans PhotoKit
        retardait le premier listage (350 à 370 ms de l'accès au listage, contre 160 ms).
      - Leçons : l'accès dispersé à un `PHFetchResult` (`objects(at:)` sur des index épars)
        coûte 2,8 ms par asset contre 0,02 ms en continu ; GRDB refuse d'écrire dans une tâche
        annulée (`CancellationError`) ; les durées du lancement qui suit une recompilation
        (demande d'accès Photos) ne sont pas représentatives, mesurer au lancement suivant.
      Recherche par nom de fichier et par mot-clé dans Photos et ses albums, le 6/11/2026 :
      - Les mots-clés sont lus dans la même passe que les noms (`PHAssetExtendedMetadata`) et
        rangés dans leur table (`photosAssetKeyword`, une ligne par photo et mot-clé). La
        migration vide l'index, reconstruit en 43 s avec les mots-clés (37 s sans).
      - Recherche par sous-chaîne, sans casse ni accents (texte « plié » à l'indexation, simple
        `LIKE` ensuite), chaque mot devant se trouver dans le nom ou dans un mot-clé : 6 à 19 ms
        sur 74 065 photos, quel que soit le nombre de résultats. Choisie plutôt que FTS5, qui ne
        cherche que par début de mot : « 1234 » ne trouverait pas `DSCF1234.RAF`. Les dossiers
        ont été alignés le même jour à la demande de Michaël : même règle partagée
        (`SearchText`), colonnes pliées dans `item`, table FTS5 `item_fts` retirée par migration.
      - Le listage PhotoKit ralentit avec la taille de la liste d'identifiants : 39 ms pour
        22 résultats, 50 ms pour 2 000, 100 ms pour 15 600, 200 ms pour 52 000 (« img »), sans
        exception ni erreur, et pareil dans un album. `NOT IN` coûte autant à taille égale :
        passer par le complément ne gagnerait que la moitié dans le pire cas, non retenu. Le
        listage d'une recherche se fait donc hors du fil principal, 150 ms après la dernière
        frappe ; RAW Only, jumeaux et recherche sont réunis en une seule liste avant PhotoKit.
      - La recherche suit l'index : un mot-clé modifié dans Photos ou dans Qaama est relu par la
        passe incrémentale puis la recherche en cours est relancée ; pendant une construction,
        le bandeau dit que la recherche ne couvre que les photos déjà indexées.
      Reste : tri par nom (demande un second chemin de listage, PhotoKit ne
      triant pas ainsi). Filtres EXIF (objectif,
      focale) : PhotoKit ne les expose pas et lire l'en-tête exige l'original sur le disque, or
      ceux de Michaël sont surtout dans iCloud ; pistes à essayer : l'EXIF de l'aperçu local
      s'il le porte, sinon une indexation au fil des ouvertures dans l'éditeur, avec une
      couverture partielle affichée comme telle.
- [ ] Inspecteur : métadonnées EXIF, histogramme, localisation (MapKit).
      Fait le 30/10/2026 : EXIF lu sur l'original (boîtier, objectif, exposition, dimensions,
      date) et histogramme RGB (`CIAreaHistogram` sur un échantillon 512 px, comptage en sRGB,
      bins de bord en murs d'écrêtage). Reste : localisation, et revoir le design de
      l'histogramme (Michaël le trouve inhabituel par rapport aux autres logiciels : prévoir
      luminance, échelle, lissage, indicateurs d'écrêtage à la Lightroom).
      Fait le 6/11/2026 : le panneau Info existe aussi en mosaïque, dans la colonne de droite
      (même réglage d'affichage que l'inspecteur de l'éditeur, même bouton et ⌥⌘I). Un clic sur
      une vignette y montre l'histogramme et les informations de la photo sans l'ouvrir :
      `LibrarySource.details(for:)` (dossiers : catalogue, sinon en-tête lu sur place ; Photos :
      nom, dimensions et date depuis la base, EXIF seulement si l'original est sur le disque,
      demandé sans accès réseau, sinon une note dit qu'il est dans iCloud et un bouton Download
      Original le fait télécharger à la demande, `allowingDownload`), `AssetInfoModel`
      dans EditorKit, histogramme calculé sur la vignette 512 px (donc l'aperçu du boîtier pour
      un RAW non retouché). Avec plusieurs photos sélectionnées, le panneau donne leur nombre.
      Le même jour, à la demande de Michaël : note, drapeau et mots-clés dans ce panneau
      (lecture et modification), menus Image › Rating et Image › Flag pour la sélection de la
      mosaïque ou la photo ouverte dans l'éditeur (valeur de focus `decisionsAction`). Les
      touches 0 à 5, P, X, U sont portées par ces seuls éléments de menu, plus par des boutons
      cachés : deux porteurs du même raccourci se déclencheraient tous les deux. À vérifier à
      l'écran : que ces touches sans modificateur n'agissent pas pendant une saisie (recherche,
      mots-clés). Et
      sélection multiple jusqu'à 50 photos : chaque ligne montre ce qui est commun, « Mixed »
      sinon (`InfoSummary`), la date devient une plage ; une note ou un drapeau va à toutes les
      photos, un mot-clé ajouté ou retiré l'est sur toutes, ceux que seules certaines ont ne
      bougent pas. Écriture en une étape annulable par `MetadataEditing.apply`
      (`LibraryDecision`, partagé avec l'éditeur). Borne de 50 : lire les détails d'une photo
      de Photos coûte 15 à 120 ms (journal de Michaël), et résoudre des milliers de photos à
      chaque mise à jour figerait la fenêtre ; au-delà le panneau ne donne que le nombre. Les
      détails déjà lus sont gardés tant que la sélection ne change pas (une note ne relit pas
      les fichiers). Journal « Compared N photos in … ms ». Non vérifié à l'écran : les
      écritures sur la vraie photothèque. Piste si la borne gêne : pour les dossiers, lire le
      catalogue au lieu des fichiers.
      Leçon : dans la colonne de détail, un `HStack` grille + colonne se cale sur la largeur
      idéale de la grille (une seule colonne de vignettes, le tout centré) tant que la grille
      n'a pas `frame(maxWidth: .infinity)` ; vu par une fenêtre sonde hors écran sur la source
      d'exemple, clic simulé compris. Non vérifié à l'écran : le chemin Photos (journal
      « Details of … : header read / original in iCloud … in … ms »). Reste : garder dans le
      catalogue l'EXIF lu à l'ouverture dans l'éditeur, pour l'afficher ensuite même quand
      l'original est reparti dans iCloud (et nourrir les filtres EXIF de Photos).
      Show in Finder, fait le 12/11/2026 à la demande de Michaël, pour les photos de dossier
      seulement : `LibrarySource.fileURL(for:)` (nil par défaut, donc pour Photos), entrée du
      menu contextuel des vignettes (toute la sélection, `NSWorkspace.activateFileViewerSelecting`)
      et bouton `ellipsis.circle` à côté du nom de fichier du panneau Info, en mosaïque et dans
      l'éditeur, qui ouvre un menu (place pour d'autres actions sur le fichier). Rendu vérifié
      par sonde hors écran, clair et sombre ; non vérifié à l'écran : l'ouverture du Finder
      depuis l'appli sandboxée. Puis File › Show in Finder (⇧⌘R, comme Musique et Xcode),
      valeur de focus `showInFinderAction` : sélection de la mosaïque ou photo ouverte ; les URL
      ne sont cherchées qu'au clic, pour ne pas résoudre une grande sélection à chaque mise à jour.
      Plantage le même jour, trouvé par Michaël : clic sur un sous-dossier avec des photos
      sélectionnées, index hors limites à `source.assets[index]` dans la grille. Cause, établie
      par sonde hors écran (grille réelle, dossier de 62 photos, sous-dossier de 2, sélection) :
      chaque vignette appelait `source.fileURL(for:)`, qui lit `itemsByID`, propriété observée ;
      quand la liste rétrécit, SwiftUI recalcule ces vignettes seules, avec leur ancienne ligne,
      avant la grille. Corrigé par `LibrarySource.hasFileURLs`, constante de la source lue une
      fois par la grille. Leçon : dans le contenu d'un `ForEach` de la grille, ne lire de la
      source que `assets[index]`, rien d'autre qui soit observé.
      Localisation, fait le 6/11/2026 : carte MapKit (`LocationMap`) sous le bloc Info, en
      mosaïque et dans l'onglet Info de l'éditeur. D'abord figée avec un clic ouvrant Plans,
      puis, à la demande de Michaël le même jour : plus de clic vers Plans, déplacement et zoom
      (`interactionModes: [.pan, .zoom]`, nord toujours en haut), boutons de zoom
      (`MapZoomStepper`) et bouton de recentrage, actif une fois la carte déplacée
      (`MapCameraPosition.positionedByUser`). Position lue dans l'en-tête
      (`ImageMetadata.location`, dictionnaire GPS, 0°/0° écarté) pour les dossiers, et dans la
      base de Photos (`PHAsset.location`) pour Photos, donc sans original local. Le catalogue ne
      garde pas la position : `details(for:)` des dossiers relit l'en-tête à chaque clic
      (quelques ms) ; à y mettre le jour où l'on veut une carte de toute la photothèque ou un
      filtre par lieu. Première permission réseau de l'appli :
      `com.apple.security.network.client`, nécessaire aux tuiles de carte dans le bac à sable.
      Vérifié par fenêtre sonde hors écran sur la source d'exemple : carte de Paris rendue
      (version figée), puis configuration de la `MKMapView` sous-jacente (centre, zoom et
      déplacement actifs, rotation et inclinaison coupées, boutons de zoom). La sonde ne sait
      pas livrer de vrais gestes à MapKit ni capturer la carte interactive : glisser, zoom et
      recentrage restent à essayer à l'écran.
      Reste : nom du lieu (géocodage inverse).
- [ ] Carte de la bibliothèque, façon Apple Photos : les photos là où elles ont été prises,
      regroupées et dégroupées au zoom. Demandé par Michaël le 13/11/2026, qui a validé
      l'emplacement (mode Grille / Carte de la source courante, pas une entrée à part dans la
      barre latérale), une carte par source en gardant en tête une fusion possible de Photos
      et des dossiers, et l'ordre en trois étapes.
      - [x] Étape 1, preuve de faisabilité (13/11/2026). Position dans l'index Photos :
            `PHAsset.location` lue dans la passe de `PhotosIndexer` (`PhotosAssetReading.location`),
            colonnes `latitude` / `longitude` de `photosAsset` (migration v6, qui vide l'index :
            il se reconstruit au prochain lancement), `PhotosIndexStore.locatedAssets()`.
            Regroupement en Swift pur dans LibraryKit (`PhotoMapIndex`), pas le clustering de
            MapKit, qui aurait reçu 74 000 annotations : positions projetées une fois en Web
            Mercator sur une grille 2³² × 2³², triées le long d'une courbe en Z (bits de x et y
            entrelacés) ; les photos d'un carré de n'importe quelle subdivision en puissances de
            deux sont alors voisines dans le tableau, et regrouper à un niveau est un seul
            parcours qui compare les bits de tête, sans dictionnaire ni allocation par photo.
            Les carrés sont liés au monde, pas à la vue : déplacer la carte ne regroupe rien.
            Chaque groupe : nombre, barycentre, photo la plus récente, étendue, plage de ses
            photos dans le tableau. Mesuré sur 74 000 points (400 lieux en Europe) : index
            construit en 188 ms en Debug (8 ms en Release), un regroupement en 2 ms en Debug
            (0,2 ms en Release) tant qu'il rend quelques centaines de groupes, 5 à 15 ms en
            Debug s'il en rend des dizaines de milliers (cas qu'un écran ne montre pas). Bien
            sous une image : pas besoin d'une cible compilée en `-O`.
            Leçon : dans une migration GRDB les clés étrangères sont coupées, la suppression
            en cascade ne joue pas ; vider `photosAsset` sans vider `photosAssetKeyword` faisait
            échouer la migration (trouvé par le test de migration).
      - [x] Étape 2, MVP pour Photos (13/11/2026). Côté paquet : `LibrarySource.hasPlaces`,
            `locatedAssets()` (positions des photos du listage courant) et `placesVersion` ;
            `PhotoMapModel` (observable, sans MapKit : la vue lui donne la région montrée et
            la largeur du monde en points, il rend les groupes et leurs vignettes, et ne les
            réaffecte que s'ils changent) ; `LibraryQuery.onlyAssetIDs`, portée comme `folderPath`, qui restreint
            le listage aux photos d'un groupe (`PhotosFetchPredicate` la combine aux autres
            listes d'identifiants). Côté appli : sélecteur segmenté Grille / Carte dans la barre
            d'outils (`LibraryDisplayPicker`, préférence `libraryDisplay`) et View › as Grid /
            as Map ; `PhotoMapView` (`Map` SwiftUI, une `Annotation` par groupe) ;
            `PhotoClusterMarker` (vignette de 64 points, nombre en bas à gauche, `Equatable`).
            Clic : sélectionne les photos du groupe, comme dans la mosaïque (le panneau Info et
            le menu Image agissent dessus) ; double clic : la mosaïque liste le groupe, bouton
            Retour vers la carte là où elle était. La carte suit la recherche et les filtres ;
            le sous-titre dit combien de photos listées ont une position. Fonctionne aussi dans
            un album.
            Écart avec ce qui était annoncé (clic = ouvrir, double clic = zoomer) : repris la
            convention de la mosaïque, qui laisse le clic immédiat ; le zoom reste aux gestes
            de la carte et aux boutons.
            Vérifié : 154 tests de LibraryKit (index, migration, regroupement, modèle,
            prédicat), compilation de l'appli, et sonde hors écran sur la source d'exemple
            (barre d'outils, cinq groupes cadrés, aller-retour carte → groupe → carte). La
            sonde ne capture pas le fond de carte (Metal) ni ne livre de gestes : glisser,
            zoom, clic et double clic sur un groupe restent à essayer à l'écran, ainsi que
            tout ce qui touche la vraie photothèque (durée de la réindexation, nombre de photos
            placées, durée de `locatedAssets()` : voir les journaux `PhotosIndexer`,
            `PhotosLibrarySource` « Places » et `PhotoMapModel`).
            Limites connues : la carte ne se remplit qu'à la fin de la réindexation (bandeau
            pendant ce temps) ; deux groupes de carrés voisins peuvent se chevaucher (comme
            chez Apple) ; pas de regroupement à travers l'antiméridien ; ouvrir un groupe de
            dizaines de milliers de photos passe par une liste d'identifiants que PhotoKit met
            100 à 200 ms à traiter, sur le fil principal ; revenir de la mosaïque à la carte
            perd le défilement de la mosaïque, et inversement ; chaque passe d'index qui lit
            des photos recharge la carte, même si aucune position n'a changé.
            Clignotement au zoom, signalé par Michaël à l'essai le 13/11/2026 (« un tout petit
            moment où aucune vignette n'est affichée ») et corrigé le même jour. Deux causes,
            vues dans la sonde en pilotant la `MKMapView` par `setRegion` et en comptant les
            vues d'annotation à chaque tour de boucle : (1) chaque marqueur chargeait sa
            vignette lui-même, donc repartait vide ; (2) l'identité des groupes était leur
            carré, qui change à chaque niveau : la carte retirait toutes les annotations puis
            ajoutait les nouvelles un instant plus tard (état « 0 marqueur » observé). Corrigé
            par : (1) `PhotoMapModel` charge les vignettes (`cover(of:)`) et garde les groupes
            affichés tant que celles des nouveaux ne sont pas là, 300 ms au plus (`patience`,
            compté depuis le premier retard, pas repoussé par les mouvements suivants) ; les
            vignettes déjà vues restent en cache (400 au plus), revenir en arrière est
            immédiat ; (2) `PhotoCluster.id` est la photo de couverture : la plus récente d'une
            fusion est celle d'un des groupes fusionnés, et un des morceaux d'une scission
            garde celle du groupe, donc ce marqueur-là est déplacé au lieu d'être recréé. La
            sélection, elle, reste repérée par le carré (`cell`). Sonde après correction :
            5 → 2 groupes au dézoom et 2 → 5 au zoom sans état vide, vignettes présentes à
            chaque instant. Reste hors de portée de la sonde : l'allure sous un vrai pincement
            et avec les vignettes de PhotoKit.
      - [x] Étape 3a, dossiers (13/11/2026, demandé par Michaël après l'essai de l'étape 2).
            Colonnes `latitude` / `longitude` de `item` (migration v7), remplies par
            `MetadataIndexer` avec le reste de l'en-tête ; la migration remet `metadataRead` à
            nul, donc les en-têtes déjà lus sont relus en arrière-plan à la prochaine ouverture
            de chaque dossier (dimensions, dates et décisions restent en place entre-temps).
            `FolderLibrarySource` : `hasPlaces`, `locatedAssets()` tiré des éléments déjà en
            mémoire, `placesVersion` qui n'avance que si les positions du listage changent
            (la carte se remplit donc lot par lot pendant la lecture des en-têtes). Le groupe
            choisi sur la carte (`onlyAssetIDs`) n'entre pas dans le SQL du catalogue, une
            liste d'identifiants pouvant être longue : la source le découpe dans ce que le
            catalogue a déjà livré, sans relancer l'observation, et garde tous les éléments
            pour retrouver la vignette d'une photo hors du groupe. Vaut aussi pour un
            sous-dossier (`folderPath`). La carte cadre toutes les photos tant que
            l'utilisateur ne l'a pas déplacée (`userMovedMap`), et non plus une seule fois :
            un dossier en cours de lecture apporte ses photos par lots.
            Vérifié par tests (migration, source sur un dossier de JPEG géolocalisés générés,
            modèle de carte branché dessus). Non vérifié à l'écran. Limite : pendant la
            relecture des en-têtes, la carte d'un dossier dit « No Photos on the Map » jusqu'au
            premier lot placé (les dossiers n'exposent pas de progression d'indexation).
      - [ ] Étape 3b : Satellite, nom des lieux (géocodage inverse), Zoom In /
            Zoom Out du menu View sur la carte. Pour la fusion Photos + dossiers :
            `LocatedAsset` et `PhotoMapIndex` ne connaissent pas la source ; il faudra un
            identifiant qui la porte et une vignette demandée à la bonne source.
- [ ] Édition des métadonnées : date de prise de vue, localisation, etc. Cadrage discuté
      avec Michaël le 6/11/2026.
      Date de prise de vue, fait le 6/11/2026 : dialogue Adjust Date & Time (menu Image, en
      mosaïque sur la sélection comme dans l'éditeur sur la photo ouverte, par une valeur de
      focus `adjustDateAction` ; menu contextuel de la mosaïque, clic sur la date du panneau
      Info, bouton quand plusieurs photos sont sélectionnées), deux modes : fixer une date pour toutes, ou décaler chacune d'années, mois, jours,
      heures et minutes (années et mois ajoutés à la demande de Michaël, par le calendrier),
      plus tard ou plus tôt, avec l'avant / après de chaque photo sélectionnée, une à la fois
      à côté de sa vignette (flèches précédente / suivante, de la plus ancienne à la plus
      récente ; demandé par Michaël). En mode décalage, la ligne « After » est un sélecteur de
      date : y saisir la vraie date de la photo affichée en déduit le décalage pour toutes
      (`DateShift(from:to:)`, épelé en années, mois et jours quand le calendrier retombe juste,
      sinon en jours, sinon en heures et minutes écoulées). `LibrarySource.setCaptureDate` / `captureDate(for:)` : sidecar
      (`captureDate`, instant UTC) plus colonne `captureDateOverride` du catalogue (migration
      v5, le tri par date prend la correction d'abord) pour les dossiers, `creationDate` de la
      base de Photos pour Photos. `MetadataEditing` écrit le lot en une étape annulable ; le
      jumeau JPEG d'une paire suit son RAW. Export : `ExportInput.captureDate`, renseigné quand
      la date de la bibliothèque diffère de celle du fichier, réécrit `DateTimeOriginal` dans
      le fuseau du décalage d'origine (sinon celui du Mac, avec le décalage écrit) via
      `ImageMetadataWriter` ; RenderEngine dépend maintenant d'ImageIOKit pour cela. Vérifié
      par tests de bout en bout sur un dossier (correction, export relu, original intact) et
      par fenêtre sonde pour le dialogue. Non vérifié à l'écran : l'écriture dans Photos, et
      le dialogue en feuille dans la vraie fenêtre. Limites : le sélecteur de date de SwiftUI
      n'a pas les secondes sur macOS (le mode « fixer » garde celles de la photo) ; dans
      l'éditeur la correction passe par le menu Image, pas par l'onglet Info ; pas de « revenir à la date d'origine » autrement que par
      l'annulation ; Reste : la localisation.
      Cadrage d'origine :
      - Photos : écriture dans la base de Photos (date, position), sans toucher à l'original,
        donc aussi pour les photos dans iCloud.
      - Dossiers : la correction va dans le sidecar `.qaama`, est reflétée dans le catalogue
        et n'est appliquée à l'EXIF qu'à l'export ; l'original n'est jamais réécrit (comme
        Lightroom, Capture One, darktable pour les RAW).
      - Dates : modification en lot depuis la mosaïque, en absolu et en relatif (ajouter ou
        retirer une heure, un jour, etc.), pour les horloges de boîtier mal réglées.
      - Position : poser le repère sur la carte, recherche de lieu, copie d'une photo vers
        d'autres. Le catalogue doit alors stocker la position (tri, futur filtre par lieu).
      - Tout passe par l'`UndoManager`, lots compris.
      - Plus tard : écrire un `.xmp` standard en miroir (date, position, note, mots-clés)
        pour que les autres logiciels voient les corrections ; `.qaama` reste la vérité. En
        lecture, pas de synchronisation : si un `.xmp` est détecté, proposer dans une boîte
        de dialogue de l'importer vers `.qaama` (dates, etc.). Outils de passerelle entre
        logiciels : à voir ensuite.

Éditeur

- [ ] Pile d'ajustements non destructive, ordonnée, activable/désactivable, avec
      undo/redo et comparaison avant/après. Fait le 30/10/2026 : calques dans la recette,
      undo/redo par geste relié au menu Édition. Avant/après le 30/10/2026 (bouton Compare à
      maintenir). Reste : interface des calques, à faire avec les masques (sans masque rendu,
      un calque supplémentaire n'apporte rien de visible).
      Reste aussi (demandé le 11/11/2026) : un interrupteur par catégorie de réglages (Lumière,
      Couleur, Détail…), comme celui de la vignette. La ligne de titre `SectionSwitch` est prête
      et sert déjà au noir et blanc et à la vignette ; il manque l'état « désactivé » de chaque
      groupe dans la recette (les groupes sont aujourd'hui des champs à plat d'`AdjustmentSet`)
      et son respect par `RenderPipeline`.
- [ ] Ajustements de base : balance des blancs, exposition, contraste, luminosité,
      hautes lumières/ombres, saturation/vibrance, netteté, réduction de bruit simple,
      vignettage, grain, courbes, niveaux, teinte/saturation sélective, noir et blanc.
      Fait le 30/10/2026 : balance des blancs (température, teinte via `CITemperatureAndTint`),
      exposition, hautes lumières (récupération par `CIHighlightShadowAdjust`, remontée par
      courbe), ombres, point noir (courbe tonale), contraste, vibrance, saturation ; netteté,
      réduction de bruit et vignettage le 30/10/2026 (options du vignettage, rayon, dégradé,
      centre, à ajouter plus tard). Courbes le 30/10/2026 (RGB et par canal, spline monotone,
      `CIColorCurves` en sRGB), noir et blanc avec mélangeur de canaux et grain le 30/10/2026.
      TSL le 30/10/2026 (huit plages, cube 3D `CIColorCubeWithColorSpace` construit en Swift).
      Niveaux abandonnés (couverts par point noir et courbes, comme dans les éditeurs RAW
      récents) ; à rouvrir si Michaël y tient.
      Vignette refaite le 11/11/2026, en deux temps. D'abord trois réglages façon Photomator
      (exposition des coins, point noir des coins, douceur) : rejeté par Michaël à l'usage, trop
      fort au maximum et un ovale trop lisible à douceur 100 %. Ensuite les cinq réglages de
      LightCraft (open source, MIT ou Apache 2.0, `github.com/storytold/lightcraft`), qui sont
      ceux des développeurs RAW : quantité (−1 assombrit jusqu'au noir, +1 éclaircit vers le
      blanc), point médian, fondu, rondeur (−1 rectangle arrondi qui suit le cadre, 0 ovale,
      +1 cercle) et hautes lumières (les zones claires résistent à l'assombrissement). Plus un
      interrupteur, qui garde les réglages dans la recette quand la vignette est coupée.
      `VignetteRenderer` reprend la correspondance réglages → forme de LightCraft (début
      0,15 + 0,95 × point médian, largeur 0,05 + 1,1 × fondu, donc jamais de bord dur même à
      fondu 0 ; superellipse d'exposant 2 à 8), réécrite en filtres Core Image sans noyau
      maison : deux `CILinearGradient` portent les coordonnées dans le rouge et le vert, puis
      `CIColorPolynomial`, `CIGammaAdjust` et `CIColorMatrix` calculent la distance et le fondu.
      `VignetteRenderer.Shape` porte la même formule en Swift pur et un test vérifie que l'image
      du masque lui correspond. La vignette suit le cadre recadré et non plus l'image entière.
      Mesuré sur GPU, cache de Core Image coupé : 6 ms à 24 Mpx et 10 ms à 45 Mpx (12 ms avec
      rondeur négative et hautes lumières), contre 5 et 9 ms pour l'ancien `CIVignetteEffect`.
      - Leçon : `CIToneCurve` travaille en valeurs d'affichage (sRGB), pas en lumière linéaire :
        le point noir à fond déplace le noir de 0,15 en sRGB.
      - Leçon : pour chronométrer un rendu Core Image, couper `cacheIntermediates` et changer un
        réglage à chaque passe, sinon les passes suivantes sortent du cache (0,1 ms mesuré à
        tort). Un filtre couleur appliqué après un recadrage peut rendre l'étendue infinie
        (`CIColorClamp` sur le transparent) : recadrer en dernier.
      - Le champ `vignette` de la recette passe d'un nombre à un objet : les sidecars qui
        portaient l'ancienne vignette ne se relisent plus (pas de rétrocompatibilité à ce stade).
- [ ] Recadrage, redressement, rotation, perspective simple.
      Fait le 30/10/2026 : cadre à poignées, grille des tiers, rapports verrouillables
      (original, carré, 3:2, 4:3, 16:9, 5:4), redressement ±45° avec rognage automatique des
      coins, quarts de tour, retournement. Reste : perspective, rapports personnalisés et
      préréglages de rapports (demandé par Michaël, plus tard).
- [ ] Préréglages (sauvegarde/import de recettes), copier/coller les ajustements.
      Fait le 30/10/2026 : préréglages en fichiers JSON dans Application Support (appliquer,
      enregistrer, supprimer), copier/coller des ajustements entre photos (le recadrage reste
      propre à chaque photo). Reste : import/export de préréglages, dossiers de préréglages.
- [x] Persistance : sidecar JSON pour les fichiers, `PHAdjustmentData` pour Photos (29/10/2026).
- [x] Zoom du canevas, demandé par Michaël le 8/11/2026 : curseur dans la barre d'outils, au même
      endroit que celui de la mosaïque, logarithmique sur la plage 0,25–16 du canevas, avec deux
      crans : « adapter » (zoom 1 du renderer) et 100 % (un pixel de la photo par pixel d'écran,
      `CanvasRenderer.actualSizeZoom` = 1 / échelle d'ajustement, calculée de la taille du
      drawable, désormais exposée, et de l'étendue de l'image). Les crans sont des marques sous
      la piste (`Canvas`, alignement vérifié hors écran : demi-largeur du bouton 8 pt) et un
      aimant de ±0,1 doublement (≈ 7 %) dans le setter de la liaison ; pourcentage de la taille
      réelle à côté, largeur fixe. Menu View : Zoom In / Zoom Out agissent sur le canevas quand
      une photo est ouverte (×1,25), sinon sur la mosaïque ; Zoom to Fit (⌘0) et Actual Size (⌘1).
      Tests : `CanvasZoomTests`. Retour de Michaël : le bouton de l'inspecteur doit être seul,
      tout à droite ; la barre d'outils de l'éditeur est désormais construite au même endroit
      (`EditorView`, plus dans `InspectorControls`) pour maîtriser l'ordre, et un
      `ToolbarSpacer(.fixed)` isole le bouton dans sa propre capsule, dans l'éditeur comme dans
      la mosaïque.
      Zoom minimal ramené à « adapter » le 9/11/2026, à la demande de Michaël (plus petit ne
      sert à rien) : `CanvasRenderer.zoomRange` part de 1, ou de 100 % pour une photo plus
      petite que la vue (qu'« adapter » agrandit, sinon Actual Size n'aurait plus d'effet) ; le
      curseur commence donc à « adapter » et n'a plus qu'un cran, 100 %. Revenir à « adapter »
      recentre la photo (`setZoom` remet le décalage à zéro).

Export

- [x] Export unitaire et par lot (format, qualité, taille, métadonnées, profil couleur).
      Conception dans `docs/export.md`. Étape 1 faite le 30/10/2026 : photo seule depuis
      l'éditeur, JPEG/PNG/HEIC/AVIF, qualité, taille par largeur, hauteur ou grand côté, aperçu,
      métadonnées recopiées, réglages mémorisés. WebP absent d'ImageIO en écriture (libwebp plus
      tard si besoin). Étape 2 le même jour : lot depuis la grille (menu contextuel, menu File),
      dossier de destination, noms d'origine avec suffixe numérique, progression, arrêt, échecs
      listés. Fenêtre réorganisée (onglets, aperçu, bande de vignettes) et étape 3, bordure de
      couleur unie, étape 4, filigrane texte ou image, et étape 5, onglet Files (nommage
      séquentiel, écraser ou renommer, métadonnées), étape 6, préréglages d'export, le même
      jour. Reste à valider par Michaël à son retour ; pistes : WebP via libwebp, profondeur
      16 bits, profil couleur autre que sRGB, métadonnées pour les photos de Photos.
      Ordre de l'export par lot, corrigé le 10/11/2026 : la sélection est un `Set`, et les photos
      partaient à l'export dans son ordre arbitraire, différent à chaque fois. Avec un nommage en
      séquence, le même numéro désignait une photo différente d'un export à l'autre. Constaté en
      cherchant un bug signalé par Michaël (« les éditions faites dans Apple Photos ne sont pas
      appliquées à l'export ») qui n'a pas été reproduit : sur ses deux exports de dix photos,
      chaque photo est identique au pixel près d'un export à l'autre et identique à la version
      courante de Photos (sonde temporaire dans l'app, retirée) ; seule la numérotation
      différait (DSCF1875 en 008 puis en 003). `LibrarySource.assets(withIDs:)` rend maintenant
      une sélection dans l'ordre du listage ; la source dossier trouve la rangée d'une photo sans
      parcourir le dossier (`rowsByID`). À retenir sur PhotoKit : pour une photo modifiée dans
      Apple Photos, `requestContentEditingInput` remet le rendu complet
      (`resources/renders/…_1_201_a`), édition incluse, tant que `canHandleAdjustmentData`
      répond non ; le fichier reste lisible après la fin de la session.
- [ ] Enregistrement dans Photos ou dans un dossier, partage système.

Qualité

- [ ] Tests unitaires `EditModel`/`RenderEngine` (rendu de référence par image
      golden), tests de la couche bibliothèque sur un dossier de fixtures.
- [ ] Journalisation `OSLog`, mesures de performance (Instruments).

Interface

- [ ] Revue générale de l'interface une fois les fonctions du MVP en place (demandé par
      Michaël le 30/10/2026) : histogramme, inspecteur, barre du bas, grille, barre latérale.
      Commencée le 5/11/2026 : inspecteur en trois onglets à icônes (Info, Crop & Straighten,
      Adjustments), placés dans la barre d'outils de la fenêtre au-dessus de la colonne : un
      `Picker` segmenté y est dessiné par macOS en capsule Liquid Glass, alors que dans la
      colonne il reste tassé (SwiftUI n'étire pas les segments à icône) ; vérifié par rendu
      hors écran d'une fenêtre sonde. L'onglet Crop est l'outil de recadrage lui-même (y entrer cadre l'image, en
      sortir applique), le modèle restant la source de vérité du mode. L'invite de nom de
      préréglage est attachée à la vue de l'éditeur pour répondre au menu Image quel que soit
      l'onglet, colonne masquée comprise. Bouton et menu View › Hide Inspector (⌥⌘I) pour
      masquer la colonne. Piège rencontré : des modificateurs posés sur un `Group` autour d'un
      `switch` sont appliqués à chaque branche, donc `onAppear` se redéclenche et `onChange` ne
      voit jamais la transition ; l'onglet Crop ne faisait rien. Les commandes de l'inspecteur
      (onglets, touche C, lien avec le mode recadrage) vivent dans un modificateur de la vue de
      l'éditeur, pas dans la colonne, pour fonctionner aussi quand elle est masquée.
      Mesure du 5/11/2026 : réafficher la colonne sur l'onglet Adjustments bloque le fil
      principal 145 à 170 ms en Debug (37 ms pour la masquer), le temps que SwiftUI reconstruise
      le formulaire (une quarantaine de curseurs, courbes, masques) ; le redimensionnement du
      canevas et l'histogramme n'y sont pour rien. Avec le panneau Info, léger, il reste 75 ms :
      coût fixe (barre d'outils, mise en page, redimensionnement du canevas). Corrigé le même
      jour : la colonne masquée reste vivante, rognée hors de la vue (réaffichage 66 à 78 ms,
      soit le seul coût fixe). Sur demande de Michaël, elle n'est construite que si elle a été
      affichée pour cette photo, et seulement 200 ms après l'apparition de la photo : naviguer
      vite d'une photo à l'autre ne paie jamais le formulaire. Navigation aux flèches gauche et
      droite dans l'ordre de la grille (`LibrarySource.neighbor(of:offset:)`), avec invite
      Save / Discard / Cancel s'il y a des modifications non enregistrées ; journal « Opened …
      in … ms » par photo. Mesure en maintenant la flèche (répétition clavier à 30 ms) : une
      photo toutes les 135 à 165 ms pour 35 à 50 ms d'ouverture, le reste étant la recréation de
      la vue, du canevas Metal et de son `CIContext` à chaque photo. Corrigé le même jour par
      `EditorSession` (EditorKit) : la session garde le canevas et la vue, et ne remplace que
      l'`EditorModel` de la photo (un modèle par photo, donc aucun état hérité). Un modèle fermé
      lâche le canevas et ne dessine plus, même si son ouverture ou ses masques finissent après
      coup. Le canevas garde la photo précédente jusqu'au décodage de la suivante, et
      l'indicateur de chargement n'apparaît qu'après 300 ms. Journal « Showed … ms after it was
      asked for » par photo. Mesure après coup : photo à l'écran 31 à 47 ms après la touche
      colonne masquée, 85 à 135 ms colonne affichée, les 60 ms d'écart étant le remplissage du
      formulaire avec les valeurs de la nouvelle photo. (L'intervalle de 150 ms entre photos pris
      d'abord pour une limite de l'app était le rythme d'appui de Michaël : la mesure « avant »
      n'était pas comparable.) D'où le gel du panneau : il suit avec 200 ms de retard, grisé
      (opacité, pas `disabled`, qui redessinerait tous les contrôles) tant qu'il montre encore
      la photo précédente. Préchargement des voisines : à décider après mesure sur des RAW,
      le coût mémoire d'une image décodée (environ 200 Mo pour 24 Mpx) n'étant pas justifié
      pour des JPEG affichés en 36 ms. Gel du panneau mesuré : JPEG à l'écran en 44 à 91 ms
      colonne affichée (85 à 135 avant). RAW de la photothèque Photos (26 Mpx) : environ 400 ms
      ressentis, soit 85 à 150 ms d'ouverture (PhotoKit, `CIRAWFilter`) puis le dématriçage au
      premier rendu ; le journal sous-estimait ce second temps (il prenait pour première image
      un redessin de la photo précédente) et attend désormais l'image réellement présentée
      (`CanvasRenderer.presentedImage`). Piste pour les RAW, à valider par une mesure sur un
      vrai fichier : affichage en deux temps, d'abord un décodage rapide à échelle réduite
      (`CIRAWFilter.isDraftModeEnabled`, `scaleFactor`) par le même moteur donc sans saut de
      couleur, puis la pleine résolution une fois la photo stabilisée ; et préparation des deux
      voisines (entrée d'édition, décodage réduit) après stabilisation, annulée si on repart.
      Fait le 5/11/2026, après mesure sur trois RAF publics de X-T4 (26 Mpx, raw.pixls.us) dans
      un contexte Core Image configuré comme celui du canevas : création du `CIRAWFilter` 50 ms ;
      décodage complet 210 à 520 ms ; brouillon à demi-échelle 100 à 140 ms (un quart n'apporte
      rien, le JPEG embarqué non plus : 100 à 120 ms et un autre rendu) ; une même instance du
      filtre donne les deux images, de couleur identique. Le cache des intermédiaires ne ressert
      un décodage que pour le même objet `CIImage` (un nouveau filtre sur le même fichier
      redécode), d'où la nécessité de garder et de transmettre l'image préparée ; un pré-rendu
      hors écran dans une texture de 256 px suffit à le remplir (affichage ensuite en 12 ms) ; une
      image pleine et trois brouillons y tiennent ensemble et l'empreinte se stabilise (environ
      3 Go avec un RAW ouvert, comme avant). Mise en œuvre : `SourceImage.draft` (brouillon
      étiré à l'étendue de l'image pleine, donc transparent pour le pipeline et les masques),
      `PreparedPhoto` (tout ce que lit `open()`, réutilisable), `EditorSession` qui, une fois la
      photo stabilisée (200 ms), passe en pleine résolution, met à jour le panneau puis lit les
      deux voisines et décode leur brouillon (`CanvasRenderer.warm`). La session possède les
      entrées d'édition lues en avance et les rend à la source ; la photo qu'on vient de quitter
      est toujours relue (elle a pu être modifiée). Effet à surveiller : dans Photos, lire une
      voisine en avance télécharge son original s'il n'est que dans iCloud.
      Mesures sur les RAF compressés de Michaël (X-Trans 26 Mpx, 25 Mo), par le vrai chemin de
      code : avant, 440 à 670 ms jusqu'à l'écran (ouverture 100 ms, première image 340 à 570) ;
      photo non préparée, environ 250 à 350 ms (ouverture 62 ms, brouillon 180 à 290 ms, soit
      60 % d'un décodage complet : la décompression CPU domine, l'échelle n'y change rien) ;
      voisine lue en avance, 17 à 47 ms. Préparer une voisine coûte 60 ms plus 170 à 390 ms de
      décodage en arrière-plan ; à priorité `utility` ce décodage passait sur les cœurs économes
      (500 à 990 ms), d'où la priorité `userInitiated` : c'est l'ordre des opérations qui
      protège la photo affichée, pas la priorité. Après le brouillon, la pleine résolution ne
      demande que 150 ms de plus quand elle suit de près : le deux temps ne coûte rien au total.
      Les mesures varient du simple au triple selon la charge mémoire de la machine. La voisine
      dans le sens de la marche est lue en premier. Ordre retenu, celui demandé par Michaël :
      pleine résolution de la photo affichée, puis voisines ; l'inverse rendrait la voisine
      prête 300 ms plus tôt, à essayer si la navigation à une photo par demi-seconde accroche.
      Correction après la navigation de Michaël : les voisines préparées s'affichaient en 55 à
      160 ms au lieu de 20. Reproduit hors app : le cache d'intermédiaires de Core Image évince
      les brouillons décodés en avance dès que quelques images pleines (200 Mo chacune) le
      remplissent, sans ordre prévisible (42 ms ou 640 ms pour le même pas). On ne s'y fie donc
      plus pour les voisines : `CanvasRenderer.rasterized` décode leur brouillon dans un
      `CVPixelBuffer` demi-flottant (52 Mo, espace de travail linéaire étendu, valeurs au-delà
      du blanc conservées) que la session garde avec la photo préparée. Résultat sur les mêmes
      scénarios : 2 à 30 ms dans tous les cas. Le brouillon de la photo affichée, utilisé tout
      de suite, passe toujours par le cache.
      Confirmé dans l'app par le journal : voisine prête affichée en 30 à 53 ms (96 ms si on
      arrive pendant son décodage), RAW non préparé en 250 à 400 ms avec deux pointes à 570,
      pleine résolution 200 à 450 ms après stabilisation, lecture en avance 200 à 270 ms par
      voisine.
      Restent : le changement d'onglet reconstruit encore le formulaire ; le bouton Close
      abandonne toujours les modifications sans prévenir.
      Inspecteur des ajustements resserré (11/11/2026, demande de Michaël : « pas très
      belle », trop haute). Chaque curseur passe de 56 à 36 pt : libellé et valeur sur une
      ligne, piste fine dessous, pleine largeur (dans un `Form` groupé, le `Slider` système
      n'occupait que la moitié droite : colonne de libellé vide, levée par `.labelsHidden()`),
      et les curseurs d'un groupe empilés dans une seule rangée du `Form` (`SliderStack`), sans
      séparateur ni marge entre eux ; titre du groupe dans la carte (`SectionTitle`), comme
      Vignette et Black & White. Colonne entière : environ 2 330 pt contre plus de 2 700.
      Le `Slider` système en taille mini a été écarté après essai par Michaël : remplissage
      bleu depuis la gauche sur chaque ligne (« trop de traits bleus »), double-clic de remise
      à zéro inopérant (il ne l'était déjà pas avant : le `Slider` garde le double-clic pour
      lui), pas de dégradé possible. Curseur dessiné à la main (`SliderTrack`) : piste grise
      ou en dégradé (`SliderGradients` : température, teinte, vibrance, saturation, les trois
      composantes du mélangeur de couleurs, les trois canaux du noir et blanc), petit pouce,
      valeur en couleur de texte principale quand elle a été modifiée. Souris gérée par une
      `NSView` (`SliderMouseView`) : à côté d'un glissement qui démarre au contact, le double
      tap de SwiftUI ne se déclenche pas, alors qu'une vue reçoit le nombre de clics. Appui
      sur le pouce : il part d'où il est ; appui ailleurs sur la piste : il vient sous le
      pointeur ; double-clic sur la piste ou sur le libellé : valeur par défaut. Vérifié hors
      écran par des événements souris adressés à la vue (une sonde lancée en arrière-plan
      n'est pas l'application active : `NSWindow.sendEvent` y avale les appuis simples).
      Interrupteur par groupe (11/11/2026, demandé par Michaël : éteindre un groupe sans
      perdre ses valeurs). Recette : `AdjustmentSet` liste les groupes éteints
      (`AdjustmentGroup` : balance des blancs, lumière, courbes, couleur, mélangeur, détail,
      effets), dans l'ordre de l'énumération, clé absente du document quand tout est allumé ;
      le moteur applique `AdjustmentSet.effective`, la copie sans les valeurs des groupes
      éteints, et `isIdentity` en tient compte. Noir et blanc reçoit son propre `isEnabled`,
      comme la vignette (éteints par défaut, ils portent leur interrupteur avec leurs
      réglages) : l'éteindre ne perd plus le mélange ; un document écrit avant se lit comme
      allumé. Inspecteur : `SectionSwitch` sur chaque carte, contrôles grisés mais visibles
      quand le groupe est éteint, piste sans dégradé. Annulable (un pas par bascule), par
      calque de masque comme les autres réglages. Limite assumée, la même que pour la
      vignette : une photo dont tous les réglages sont éteints est une photo non modifiée ;
      l'enregistrer retire la recette, donc les valeurs éteintes ne survivent pas à la
      fermeture dans ce seul cas.
      Mélangeur de couleurs repensé (12/11/2026, à partir d'une capture de Photomator que
      Michaël aimait : choix de la couleur et petit histogramme). Huit pastilles, une par plage,
      et les trois curseurs Hue / Saturation / Luminance de la plage choisie, au lieu de huit
      curseurs et d'un sélecteur de composante : la carte passe de 11 à 5 rangées. « Luminance »
      plutôt que « Brightness » : c'est le terme du modèle (`HSLValue.luminance`) et l'usage des
      mélangeurs HSL. Un point signale une plage déjà réglée, puisqu'une seule plage montre ses
      curseurs. Histogramme des teintes (`HueHistogram`, 360 cases d'un degré, les gris ne
      comptent pas) calculé sur l'image telle que
      le mélangeur la reçoit (`RenderPipeline.colorMixerUpstream` : la recette sans le
      mélangeur ni ce qui le suit, noir et blanc, grain, vignette, calques suivants) : il reste
      lisible en noir et blanc et ne bouge pas quand on règle le mélangeur, donc il n'est pas
      recalculé (clé : recette amont, masques et retouches disponibles). Échantillon de 160 px,
      comptage en Swift pur : 1,9 ms en Debug pour 25 600 pixels. Affichage : chaque plage a la
      même largeur (`HSL.hue(atStripPosition:)`), ses teintes sont donc au-dessus de sa
      pastille ; barres en moyenne par degré (les plages n'ont pas la même étendue). Première
      version : hauteur en racine carrée et barres de la plage choisie plus lumineuses, revues
      ci-dessous.
      Retour de Michaël le 12/11/2026, sur la même photo que dans Photomator : histogramme
      « peu lisible », à agrandir et à rendre plus éclatant ; le point sous la pastille décalait
      la pastille choisie vers le haut dans sa case ; reprendre l'idée d'un conteneur pour les
      pastilles. Corrigé : histogramme de 68 pt, 96 barres fines aux couleurs franches, toutes
      à pleine opacité (l'atténuation des plages non choisies ternissait tout quand la plage
      choisie était absente de la photo : retirée, avec `HSL.weight(of:atHue:)`), ligne de base
      de toutes les teintes ; échelle fixée par la huitième barre (sur 96) avec compression de
      ce qui dépasse, à la place de la racine carrée (essai abandonné, voir le second retour).
      Pastilles dans une bande façon contrôle segmenté, case choisie en relief ; marqueur de
      modification devenu un point blanc au centre de la pastille, sans effet sur la mise en
      page.
      Second retour le même jour, sur `DSCF2760.jpeg` : les barres « vont trop haut », l'affichage
      « sature facilement ». Mesuré sur cette photo : la bosse des orangés ne pèse que 2 à 8 % du
      pic bleu selon la pondération ; l'échelle au percentile la poussait à 95 % avec trois
      barres au plafond. Remplacée par une racine cubique de la part de la plus haute barre :
      seule celle-ci atteint le haut, rien ne plafonne, la bosse est à 42 % de la hauteur.
      Pondération revue en même temps : un pixel compte en entier dès que sa chroma atteint
      32/255, en proportion en dessous ; une zone vive ne pèse plus davantage qu'une zone
      simplement colorée, l'histogramme dit quelle surface chaque teinte couvre.
      Restent à décider : groupes repliables, valeurs en entiers.

### Phase 3 — Au-delà du MVP (selon l'envie)

- [ ] Fonctions « intelligentes » via Vision/Core Image : auto‑amélioration, redressement
      automatique de l'horizon, masque de sujet / arrière‑plan, ajustements par zone
      (pinceau, dégradé, masque ML).
      Masques, étape 1 faite le 30/10/2026 (`docs/masques.md`) : modèle en composants,
      dégradés linéaire et radial, plages de luminance et de couleur, fusion par masque,
      géométrie en deux temps, calques dans l'inspecteur avec menu Add/Subtract/Rename/
      Duplicate/Invert/Delete, curseurs par calque, superposition rouge. Étapes 2 à 4 le même jour :
      sujet, arrière-plan, personnes (Vision), ciel et seize classes de scène (DETR embarqué,
      affinage Vision), pinceau et poignées des dégradés sur le canevas (une poignée, une
      fonction : largeur, hauteur et rotation séparées). Reste : pipette de luminance et de
      couleur, choix d'une instance de sujet au clic, masques en vignette dans la liste des
      calques. Retour de Michaël le 30/10/2026 : le pinceau est « un peu lent au dessin, mais
      acceptable » et l'UI/UX des masques sera revue plus tard, sans priorité.
      Pinceau accéléré le 30/10/2026 : mesuré sur 5 traits de 150 points plus un trait en
      cours, chaque point repeignait tout le masque en CPU, 23 ms à rayon 0,03 et 177 ms à
      rayon 0,1 (Debug). Le bitmap du dernier pinceau reste ouvert et seuls les nouveaux
      « dabs » y sont tracés (une tache pré-rendue par trait, tamponnée au pixel près) : 0,14 ms
      et 0,5 ms par point. Le repaint complet (ouverture, annulation) reste à 18 et 166 ms.
      Mais dans l'app (1/11/2026) les points n'arrivaient toujours que toutes les 31 ms, pour
      1 ms de modèle et 6 ms de canevas : le reste était SwiftUI, qui réévaluait l'inspecteur à
      chaque mutation de la recette. Le trait en cours reste désormais hors de la recette
      (`previewRecipe` le fusionne pour l'aperçu) et n'y entre qu'au relâchement : 8,5 ms par
      point, soit la cadence de la souris, une image par point. Leçon : pendant un geste, ne pas
      écrire dans une propriété observée par beaucoup de vues ; le journal « Brush stroke »
      (notice) donne la répartition modèle / encodage / GPU par trait.
- [ ] Super‑résolution et débruitage via modèles open source convertis en Core ML.
- [x] Outil de retouche/suppression d'objets (approche simple d'abord : clonage,
      inpainting basique). Faisabilité sans modèle vérifiée le 9/11/2026, voir « Étude de
      faisabilité : pinceau correcteur » plus haut, essai sur de vraies photos compris.
      Intégré à l'appli le 10/11/2026 :
      - **Recette** : `EditRecipe.retouches`, une `Retouch` par trait (points, rayon, numéro
        d'algorithme pour qu'un futur remplissage ne change pas les photos déjà retouchées).
        Points en coordonnées unitaires de l'original, avant toute géométrie : la retouche
        reste sur l'objet quand on recadre, tourne ou redresse (`Geometry.sourcePoint` /
        `referencePoint`, vérifiés contre `GeometryRenderer`). La clé est absente du JSON des
        photos sans retouche : version de recette inchangée, les sidecars existants restent
        lisibles.
      - **Moteur** : `PatchFill` (porté du prototype) dans une cible à part du paquet
        RenderEngine, `HealingFill`, toujours compilée avec `-O`. Mesuré : 38 s en Debug sans
        optimisation contre 59 ms avec, pour un trou de 147 px dans 700 × 700 ; l'appli étant
        testée en Debug, c'était inutilisable autrement. Leçon : des boucles serrées sur des
        pixels en Swift pur ne supportent pas `-Onone` ; les isoler dans une cible optimisée
        plutôt que d'optimiser tout le paquet.
      - **Rendu** : `RetouchRenderer` rastérise le trait (élargi de 15 %, au moins 2 px, leçon
        des vraies photos), lit les pixels alentour en flottants sRGB étendu (les hautes
        lumières d'un RAW survivent), remplit, et rend une image de la taille de la zone,
        transparente ailleurs. Le pipeline ne fait que la composer sur l'original avant la
        géométrie : rien n'est recalculé par mouvement de curseur. Au-delà de 6 Mpx de zone de
        travail, le remplissage se fait sur une copie réduite.
      - **Éditeur** : le trait en cours reste hors de la recette (leçon du pinceau des
        masques) et se dessine en SwiftUI par-dessus le canevas ; au relâchement il entre dans
        la recette (une étape d'annulation nommée « Retouch ») et son remplissage se calcule
        en tâche de fond avec le contexte du canevas (un RAW n'est pas redécodé). Chaque
        remplissage dépend des précédents : ils sont jetés à partir du point où la liste
        diverge, et gardés pour le « rétablir » quand elle est seulement raccourcie.
      - **Interface** : onglet « Retouch » de l'inspecteur (pansement, touche R), outil au même
        titre que le recadrage ; taille du pinceau (curseur, touches [ et ]), nombre de
        retouches, « Remove All ». Pincer pour zoomer, Option-glisser pour se déplacer. Au
        passage, le calque des masques suit lui aussi le zoom et le déplacement du canevas
        (`CanvasRenderer.imageRect`), ce qu'il ignorait.
      - **Vérifié sur deux vraies photos par le chemin de l'appli** (`EditRenderer.jpeg`, test
        temporaire non versionné) : bateau bleu effacé puis redressement, miroir et exposition
        appliqués par-dessus, au bon endroit ; poteau effacé d'un seul trait. 58 à 174 ms par
        retouche en 1280 px, dont la moitié à lire les pixels. Deux défauts que les scènes de
        synthèse ne montraient pas, corrigés avec tests : (1) un trait fin dans une zone
        étroite (le poteau) n'était pas rempli, la pyramide descendait jusqu'à une échelle où
        le trou, épaissi, ne laissait plus aucun patch source ; elle s'arrête désormais à la
        dernière échelle qui a plus de matière que de trou ; (2) l'épaisseur du trait était
        mesurée dans son propre cadre, qu'il remplit bord à bord, donc surestimée, et la zone
        de recherche trois fois trop large. Leçon : essayer le chemin réel sur de vraies
        photos avant de conclure, les tests de synthèse étaient verts.
      - **Retour de Michaël (10/11/2026)** après quelques essais dans l'appli : intégration
        validée, mais le résultat de l'outil « n'est pas génial » ; à reprendre plus tard, sans
        priorité. Cas précis à recueillir à ce moment-là. Pistes déjà identifiées : raccord au
        bord, recherche de patchs à plusieurs échelles (perspective), modèle (LaMa) pour les
        structures uniques.
      - **Reste** : essai à la main dans l'appli (peinture, zoom, annulation), non fait ici ;
        raccord au bord (léger contour sur les fonds en dégradé) ; masques de sujet calculés
        sur l'image non retouchée ; à l'ouverture d'une photo retouchée, l'objet réapparaît
        le temps du calcul ; pas de liste pour supprimer une retouche précise.
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
