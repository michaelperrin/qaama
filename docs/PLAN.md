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
      ouverte dans l'éditeur, par la valeur de focus `albumsCommand` ; le retrait depuis
      l'éditeur, d'abord écarté, est venu le 17/11/2026, voir plus bas).
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
      - Albums d'une photo dans le panneau Info, fait le 17/11/2026 à la demande de Michaël :
        section Albums sous Info (grille, carte et onglet Info de l'éditeur), le titre de chaque
        album au-dessus du chemin de ses dossiers ; à plusieurs photos, « Albums in Common »,
        les albums qu'elles ont toutes, comme pour les mots-clés. Un clic sur la ligne ouvre
        l'album par la sélection de la barre latérale ; l'album affiché n'est pas cliquable.
        Depuis l'éditeur, les modifications non enregistrées sont d'abord demandées (même
        dialogue que pour passer à une autre photo).
        - Architecture : `LibrarySource.hasAlbums(for:)` et `albumIDs(containing:)` (identifiants
          seulement, vides par défaut ; Photos interroge
          `PHAssetCollection.fetchAssetCollectionsContaining` hors acteur principal ; la carte
          relaie au membre qui détient la photo), `AssetAlbumsModel` dans LibraryKit
          (intersection des albums de la sélection), `AssetAlbumsSection` dans l'app, qui nomme
          les albums d'après `PhotosAlbumList.tree` : ceux que la barre latérale ne liste pas
          (partagés, synchronisés, Favoris) sont écartés, puisqu'on ne peut pas les ouvrir. La
          fenêtre donne le chemin par la valeur d'environnement `albumNavigation`.
        - Rafraîchissement : ajouter une photo à un album ne change pas la photo, et Photos
          signale des changements toutes les secondes ou deux pendant ses analyses : relire à
          chaque notification coûterait trop. `PhotosAlbumList.contentVersion` est donc
          incrémenté quand Qaama ajoute ou retire lui-même (annulations comprises) et quand la
          liste des albums est relue ; la section relit alors la sélection. Hypothèse non
          vérifiée : qu'un ajout fait dans Photos même fasse relire la liste (Photos signale-t-il
          l'album comme changé ?) ; sinon le panneau ne suit ce changement-là qu'à la sélection
          suivante.
        - Leçon : `.buttonStyle(.link)` reste d'un bleu fixe, quelle que soit la teinte (vu dans
          la sonde, teinte grise appliquée). Pour une liste, ligne entière cliquable en style
          `.plain` avec une flèche grise au bout, comme le bouton ellipse de la ligne File. Le
          lien bleu de la date (Captured) est resté tel quel.
        - Mesure : aucune sur une vraie photothèque. Le modèle journalise « Read the albums of
          N photos in X ms » (catégorie `AssetAlbumsModel`) : à relever par Michaël avec ses
          787 albums, pour une photo et pour 50.
        - Vérifié : 6 tests d'`AssetAlbumsModel`, un de la carte, un de `PhotosAlbumEditor`
          (version incrémentée, annulation comprise), un du parcours de la hiérarchie ; sonde
          hors écran en clair et en sombre (une photo, plusieurs, aucune, titres et dossiers
          longs tronqués dans la colonne de 280). Non vérifié à l'écran : le clic lui-même (un
          bouton SwiftUI ne reçoit pas les clics simulés de la sonde), la vraie requête PhotoKit
          et l'ouverture depuis l'éditeur.
        - Reste possible : sélectionner la photo dans l'album ouvert et y faire défiler la
          grille ; déplier le dossier de l'album dans la barre latérale.
      - Retour depuis un album ouvert par le panneau Info, fait le 17/11/2026 à la demande de
        Michaël : bouton Back de la barre d'outils (le chevron de l'éditeur) et View › Back
        (⌘[), qui ramènent là où l'on était : grille au même endroit, même sélection, même photo
        rouverte dans l'éditeur si l'on en venait. Les albums ouverts l'un depuis l'autre se
        remontent un par un ; un clic dans la barre latérale fait oublier le chemin.
        - Constat (sonde minimale) : un `ScrollView` retiré puis remis à l'écran repart à
          l'offset 0. La grille repartait donc en haut à chaque retour de l'éditeur ; le même
          mécanisme la remet maintenant en place là aussi (autour de la photo affichée en
          dernier si l'on a changé de photo dans l'éditeur).
        - Architecture : `VisitTrail` (LibraryKit, générique, testé) tenu par la fenêtre, avec
          pour chaque visite un `LibraryPlace` (sélection, place de la grille, photo en cours
          d'édition) ; `LibraryVisits` dans l'environnement donne à `LibraryContentView` de quoi
          partir et revenir, et `LibraryArrival` lui remet la place une seule fois. La place de
          la grille est un `GridPlace` : la première vignette entièrement visible et sa distance
          au haut de la zone visible, lue dans les cadres du `GridViewport` et rendue par
          `scrollTo(id:anchor:)` ; `GridPlaceKeeper` la garde d'une grille à la suivante.
        - Leçon : à l'apparition d'une bibliothèque, la fenêtre place ses colonnes en plusieurs
          passes (zone visible de 100 × 100, puis 24 de large, puis la vraie taille) ; un
          `scrollTo` fait dans une taille provisoire est perdu. La place est donc réalignée à
          chaque changement de taille pendant une seconde (`GridViewport.arrive(at:)`).
        - Mesure (sonde, vraie grille, 400 photos d'exemple) : après un aller-retour, la même
          vignette au même endroit à 0,2 pt près (153,3 puis 153,1 ; 53,8 puis 53,6). L'offset
          brut diffère (3137 puis 3188) : les hauteurs estimées de `LazyVGrid` ne sont pas
          celles d'avant, d'où le repérage par vignette et non par offset.
        - Vérifié : 4 tests de `VisitTrail` ; sonde de `LibraryContentView` à l'arrivée d'un
          retour (bouton Back avec son aide, sélection, grille à la place demandée, éditeur
          rouvert). Non vérifié à l'écran : le parcours complet dans l'app (clic sur l'album,
          Back, View › Back), et le retour de l'éditeur sur la photothèque de 74 000 photos.
      - Reste : renommer et déplacer un album ou un dossier, supprimer un dossier, glisser sur
        Favoris, faire suivre le jumeau JPEG d'un RAW ajouté à un album, filtrer les albums de
        la barre latérale par leur nom. (Raccourci pour Remove from Album : ⌫, le 17/11/2026.)
- [x] Supprimer, dupliquer, retirer de l'album depuis l'éditeur, fait le 17/11/2026 à la demande
      de Michaël. Image › Duplicate Photo (⌘D) et Delete Photo (« Delete 3 Photos » selon la
      sélection), dans le menu contextuel des vignettes et dans celui de la photo ouverte (clic
      secondaire sur le canevas, où figure aussi Remove from Album). Dans l'éditeur, la photo
      supprimée ou retirée de l'album laisse la place à la suivante (sinon la précédente, sinon
      retour à la mosaïque) ; le retrait demande d'abord quoi faire des retouches non
      enregistrées (`UnsavedChangesPrompt`, partagé avec les flèches), la suppression non.
      - Menu : Image plutôt que File, comme Photos : c'est le menu de ce qu'on fait aux photos
        sélectionnées, à côté des albums ; File garde ce qui crée ou sort des fichiers. Pas de
        points de suspension : une confirmation ne demande aucune information de plus (HIG).
      - Touche ⌫, convention de Photos : supprime, sauf dans un album où elle retire de l'album
        (annulable, sans question) et où supprimer devient ⌘⌫. À valider par Michaël, qui avait
        demandé ⌫ pour supprimer.
      - Confirmation : dans un dossier, alerte de l'appli (« Delete » par défaut, sans style
        destructif puisque l'action est choisie exprès, HIG). Pour Photos, la question du
        système ne peut être ni évitée ni reformulée : l'appli n'en ajoute pas une seconde
        (constaté par Michaël le 17/11 : « Allow “Qaama” to delete this photo? », avec la
        mention de Recently Deleted pour 30 jours ; une alerte par lot, pas par photo. Pas de
        contournement par AppleScript : la commande `delete` de Photos ne prend que des albums
        et des dossiers). Le
        HIG déconseille l'alerte pour une suppression annulable (cas des dossiers) : gardée à
        la demande de Michaël, à revoir à l'usage.
      - Dossiers : le fichier et son sidecar vont à la corbeille (`FileTrash`, un dossier dans
        les tests) et l'annulation les en ressort. Sonde du 17/11 : une appli sandboxée peut
        déplacer hors de la corbeille le fichier qu'elle vient d'y mettre (essai dans le
        conteneur d'une appli de test ; à confirmer sur un dossier ouvert par signet et sur un
        volume externe). La photo revient sous le même identifiant : le catalogue retrouve son
        fichier (identifiant système) et son sidecar. La liste suit tout de suite
        (`CatalogStore.markMissing`), sans attendre le prochain listage du dossier.
      - Copie d'un dossier : nom du Finder (« IMG_1 copy.jpg », puis « copy 2 »), sidecar
        recopié sous un nouvel identifiant. Bogue trouvé par les tests : l'indexeur rattachait
        la copie à l'élément de l'original par l'empreinte (« IMG_1 copy.jpg » est listé avant
        « IMG_1.jpg »), et l'original devenait une nouvelle photo. L'empreinte ne vaut plus que
        pour un élément dont le fichier a disparu ; cela vaut aussi pour une copie faite dans
        le Finder.
      - Photos : `PHAssetChangeRequest.deleteAssets` (corbeille de Photos, 30 jours). PhotoKit
        ne sait pas en ressortir une photo : la suppression n'est pas annulable, seule
        exception à la règle. La copie est une nouvelle photo créée depuis les ressources de
        l'original (`PHAssetCreationRequest`), avec la version retouchée et les données
        d'ajustement quand il y en a (`supportsAssetResourceTypes` répond oui pour photo +
        fullSizePhoto + adjustmentData, sondé le 17/11) ; date, lieu, favori, note et mots-clés
        sont recopiés, et la copie rejoint l'album affiché. Annuler la copie la supprime, avec
        la question du système.
      - Rubrique « Recently Deleted » avec restauration, demandée par Michaël le 22/11/2026
        (« au moins pour Apple Photos ») : pas faite. Constaté dans le SDK 27.2 : aucune API
        publique ne liste les photos supprimées ni n'en ressort une. Ce qui existe : en privé,
        `PHFetchOptions.includeTrashedAssets` et `PHAssetChangeRequest.undeleteAssets:` (noms
        vus à l'exécution, non essayés ; refus du Mac App Store, fragile) ; en AppleScript,
        `recently deleted album` en lecture seule, sans commande de restauration. Autre voie
        propre proposée : une corbeille propre à Qaama (la photo masquée dans l'appli, la vraie
        suppression PhotoKit au vidage ou après 30 jours), qui rendrait aussi la suppression
        annulable. Arbitrage de Michaël : « Mince dommage en effet. Je pense que pour le moment
        on ne va rien implémenter alors. » Puis : « C'est vrai que la corbeille Qaama n'est pas
        bête à y réfléchir quand même. » Piste gardée ouverte, à reprendre aussi si Apple
        ouvre l'API.
      - Paire RAW + JPEG affichée comme une seule photo : supprimée et copiée d'un bloc, sinon
        le JPEG resterait et apparaîtrait comme une photo à part.
      - `UndoableSteps` : la file de changements annulables d'`PhotosAlbumEditor`, extraite pour
        servir aussi aux fichiers des dossiers et aux copies de Photos. Leçon : la fermeture
        qu'elle garde doit être typée `@MainActor`, sinon une fermeture synchrone isolée
        s'exécute hors de l'acteur principal et l'exécution s'arrête sur l'assertion
        d'isolation.
      - Clic secondaire sur une photo hors sélection (remarque de Michaël le 17/11) : le menu
        agissait bien sur la photo cliquée, mais l'anneau de sélection et le panneau Info
        restaient sur l'autre. La photo cliquée est maintenant sélectionnée à l'ouverture du
        menu, comme dans Photos ; sur une photo déjà sélectionnée, la sélection reste. SwiftUI
        n'a pas de « ce menu contextuel s'ouvre » : c'est le `body` d'une vue placée dans le
        menu qui le dit (`ContextMenuOpening`), rapproché du début de suivi d'un menu
        (`NSMenu.didBeginTrackingNotification`). Mesuré par sonde (vraie mosaïque hors écran,
        `menu(for:)` puis notifications de suivi) : ce `body` n'est évalué qu'à la
        construction du menu, jamais lors des mises à jour de la mosaïque, y compris pour un
        menu déjà ouvert une fois ; il ne l'est pas si la vue n'ajoute aucun élément au menu
        (`EmptyView`) ; et il ne l'est qu'une fois tant que le contenu du menu ne change pas,
        d'où un compteur donné à toutes les vignettes à chaque fermeture de menu
        (`menuGeneration`). Six cas vérifiés : première et deuxième ouverture sur la même
        photo, clic sur une photo de la sélection, sur une troisième, changement de la
        photothèque puis ouverture d'un autre menu, autre menu juste après une fermeture.
        Non vérifié avec un vrai clic à l'écran.
      - Non vérifié en conditions réelles (rien n'a été lancé ni supprimé dans la photothèque
        de Michaël par l'agent ; la suppression dans Photos a été essayée par Michaël) : la
        copie dans Photos, la copie d'une photo retouchée
        (la retouche est-elle bien rouverte par Qaama ?), le menu contextuel sur le canevas
        Metal, la touche ⌫ selon l'endroit où est le focus. Une Live Photo est copiée sans sa
        vidéo.
- [ ] Grille performante (vignettes en cache, prefetch), tri et filtres (date, type,
      RAW, édité/non édité, favoris), recherche simple.
      Fait le 30/10/2026 : tri (dates, note, nom), filtres (note, drapeau, modifié, RAW,
      favoris), recherche noms et mots-clés pour les dossiers ; Photos en natif pour dates,
      favoris, note (prédicats confirmés par sonde, PhotoKit ne documente pas la note).
      Prefetch des vignettes Photos le 30/10/2026 (fenêtre de 60 lignes autour de l'écran via
      `PHCachingImageManager`, libérée au-delà). Reste : filtre par type de fichier.
      Panneau de filtres le 19/11/2026 (demande de Michaël, sur le principe de celui de
      Photomator) : le menu de filtres devient un popover à cases à cocher (Favorites, Edited,
      RAW, Rating, Flag, Date, Location), avec interrupteur général et remise à zéro.
      - Nouveaux filtres : note comparée dans les deux sens (au moins, au plus, exactement, et
        « Unrated »), bornes incluses, sinon « plus de 5 étoiles » ne listerait rien ; plage de
        dates en jours entiers du calendrier ; lieu avec rayon de 50 m à 1 000 km (borne basse à 1 km d'abord, abaissée le même jour à la demande de Michaël ; mètres ou pieds affichés sous 1 km ou 1 mile) (curseur
        logarithmique, champ, carte qui dessine le disque et où l'on clique le centre, recherche
        de lieu partagée avec le panneau Info : `PlaceSearchModel`).
      - Modèle : `LibraryQuery.filters` (`LibraryFilters`) ne dit que ce qui s'applique, c'est
        tout ce que lisent les sources ; ce que montre le panneau (cases, valeurs gardées case
        décochée, interrupteur) est `LibraryFilterSettings`, gardé par bibliothèque dans
        `LibraryFilterPanels`. Si la requête a été changée autrement, le panneau se relit
        depuis elle.
      - Dossiers : SQL (dates et position corrigées prises en compte, position retirée = aucun
        lieu). Pour le lieu, SQLite garde la boîte autour du disque (antiméridien et pôles
        traités) et la distance (haversine) est mesurée en Swift, SQLite n'ayant pas de
        trigonométrie garantie. Photos : dates et note en prédicat natif ; lieu par l'index
        local (positions déjà indexées pour la carte), rendu en liste d'identifiants comme la
        recherche, donc partiel tant que l'index n'est pas fini (bandeau).
      - Mesures (Debug, données synthétiques) : lieu sur 74 000 photos indexées, 7 ms pour un
        rayon de 25 ou 200 km, 32 ms pour 1 000 km (55 000 photos retenues) ; dossier de
        20 000 photos, 4 ms à 25 km, 59 ms à 200 km, le coût étant le décodage des lignes
        retenues (377 ms sans filtre). Le rayon n'est appliqué qu'au relâchement du curseur
        (ou après 300 ms de pause), le disque suit en direct.
      - Vérifié : tests des filtres, du SQL, du prédicat, de l'index et de l'état du panneau ;
        mise en page par sonde hors écran, clair et sombre. Non vérifié par moi, à confirmer
        par Michaël dans l'appli : le popover lui-même (carte MapKit dans un popover, clic sur
        la carte, champ de recherche et ses résultats au clavier, sélecteurs de date), le
        disque en couleur d'accent grise sur la carte, le filtre par lieu et par dates sur la
        vraie photothèque.
      - Écarts voulus avec Photomator : pas de ligne « File Name » (la recherche de la barre
        d'outils couvre noms et mots-clés) ; libellés et icônes de Qaama.
      Filtres enregistrés le 19/11/2026 (demande de Michaël) : « Save as Preset… » en bas du
      panneau de filtres, nom demandé par la fenêtre, puis une entrée par preset dans une
      section « Saved Filters » de la barre latérale ; clic droit : « Rename Preset… » et
      « Delete Preset ».
      - Choix : un preset = les réglages du panneau + la bibliothèque où il a été enregistré
        (Photos, un album, un dossier ou un sous-dossier), comme un album intelligent. Il n'y a
        pas de grille de toutes les bibliothèques à filtrer, et un preset « sans bibliothèque »
        n'aurait rien à montrer au clic. Pas de preset depuis la carte de toutes les
        bibliothèques (elle ne liste aucune photo) : à faire si le besoin se présente, au prix
        d'une `CombinedLibrarySource` par preset.
      - Chaque preset a sa propre source (`LibraryCatalog.library(for:)`, créée au premier
        clic avec les filtres déjà posés, gardée pour la session), comme la carte : filtrer
        dans un preset ne touche pas à ce que montre l'entrée « Photos » ou le dossier. Pour un
        dossier, la vue suit le catalogue sans scanner (`FolderLibrarySource.makeView()`), et
        la source du dossier est chargée à côté pour le scan et la surveillance.
      - Les filtres restent modifiables dans un preset, sans le modifier : revenir sur le
        preset le remontre tel qu'enregistré.
      - Mise à jour d'un preset (le même jour, validé par Michaël) : dans un preset, le bouton
        du panneau devient « Update Preset », bouton scindé du système (`Menu` avec
        `primaryAction`) dont la flèche ouvre « Save as New Preset… ». Actif seulement si les
        filtres ne demandent plus la même chose que le preset
        (`LibraryFilterSettings.asksTheSame`, qui ignore les valeurs derrière une case
        décochée). Annulable (« Update Filter Preset »).
      - Dates relatives (le même jour) : la ligne Date porte un sélecteur « Between » / « In the
        Last », le second avec un nombre et une unité (jours, semaines, mois, années),
        `RelativeDateSpan`. La plage va du même jour il y a N unités à la fin d'aujourd'hui.
        `LibraryFilters` reste en dates absolues (les sources n'ont rien appris) : c'est
        `LibraryFilterSettings.filters(now:)` qui calcule, et `LibraryFilterPanels` redemande
        aux bibliothèques concernées au changement de jour (`NSCalendarDayChanged`). Le panneau
        compare désormais la requête à ce qu'il avait demandé, pas à ce que ses réglages
        diraient maintenant, sinon minuit transformait « 30 derniers jours » en deux dates
        fixes. Un preset relatif est recalculé à chaque fois qu'on y vient. Champ optionnel
        dans le JSON : les presets déjà enregistrés se relisent.
        Non vérifié par moi : le bouton scindé et les champs dans le vrai popover, le passage
        de minuit avec l'appli ouverte (testé par horloge injectée seulement).
      - Édité / non édité (le même jour, demande de Michaël) : la case « Edited » devient la
        ligne « Edits » avec un menu « Edited » / « Not Edited » (`EditsFilter`). Dossiers :
        `hasEdit` du catalogue (une recette Qaama). Photos : « modifiée par n'importe quelle
        appli » (choix validé par Michaël, c'est aussi le sens du badge des vignettes), par le
        l'index local. Le prédicat natif `hasAdjustments` a été sondé d'abord et PhotoKit le
        refuse sur macOS 27 (journal du 19/11/2026 : « edited filter false ») : colonne
        `hasAdjustments` de `photosAsset` (migration v10, l'index repart de zéro, une
        demi-minute en fond), lue par `PhotosIndexer` avec le reste, et le filtre passe par la
        même recherche dans l'index que le texte et le lieu (liste d'identifiants). « Not
        Edited » donne une longue liste : 200 ms environ hors acteur principal d'après les
        mesures de la recherche (52 000 identifiants) ; à optimiser en `NOT IN` si ça gêne.
        Une retouche enregistrée fait repasser l'index (une seconde après) et relister.
        Non vérifié par moi sur la vraie photothèque.
      - Stockage : `FilterPresets.json` dans Application Support (`FilterPresetStore`), pas le
        catalogue, qui doit rester reconstructible. Enregistrer, renommer et supprimer sont
        annulables (la suppression ne demande donc pas confirmation).
      - Vérifié : tests du magasin (tri, fichier, annulation) et des sources propres aux
        presets ; mise en page du bouton et de la section par sonde hors écran. Non vérifié par
        moi, à confirmer par Michaël dans l'appli : l'alerte de nom à la fermeture du popover,
        le clic sur un preset (Photos, album, dossier), le menu contextuel, l'annulation.
      Sélection au clavier le 18/11/2026 (bogue signalé par Michaël : les flèches ne faisaient
      rien après un clic) : la grille prend le focus au clic (`.focusable()` + `@FocusState`,
      sans anneau), sinon la liste de la barre latérale garde les flèches et changerait de
      bibliothèque ; `.onKeyPress` sur les quatre flèches, ⇧ pour étendre depuis l'ancre.
      Haut et bas gardent la colonne en tenant compte des mois, qui commencent chacun une
      rangée (`DateTimeline.row(from:moving:columns:)`, testé) ; colonnes par l'arithmétique
      de `LazyVGrid` adaptative (`GridViewport.columns(forSide:)`). Non vérifié à l'écran par
      moi : à confirmer par Michaël (focus au clic, bord flou sous la barre d'outils intact
      avec `.focusable()` sur le `ScrollView`, nombre de colonnes juste). Validé par Michaël le
      même jour. Touche maintenue (signalé par Michaël : un seul pas puis plus rien) : les
      répétitions arrivaient bien toutes les 33 ms (journal), mais SwiftUI rappelle le
      gestionnaire de l'appui initial, dont le `@Binding` de la sélection garde la valeur de cet
      instant (les `@State` sont lus à jour) ; chaque répétition repartait de la même photo.
      Reproduit et corrigé dans une sonde : le gestionnaire passe par `AssetGridActions.move`,
      repointé à chaque mise à jour de la grille.
      Rectangle de sélection le 20/11/2026, demandé par Michaël (« pouvoir sélectionner les
      photos à l'aide d'un rectangle de sélection si le clic démarre sur une zone blanche »),
      pour toutes les mosaïques, celle d'un appareil comprise (même `AssetGridView`) :
      `GridMarquee`, un `DragGesture` posé en fond du contenu de la grille, donc atteint
      seulement là où aucune photo n'est dessinée (entre les vignettes, à côté d'une photo
      entière dans son carré, sous la dernière rangée : le contenu fait au moins la hauteur
      visible). Tout est dans le repère du contenu (espace nommé), où les cellules remontent
      leur cadre une fois posées, ce qui ne bouge pas au défilement ; les cellules sorties de
      l'écran pendant un tracé restent comptées. Sans touche il remplace la sélection, ⇧
      ajoute, ⌘ inverse ; un simple clic à côté des photos désélectionne, comme dans le
      Finder. Au-delà du haut ou du bas de la zone visible, défilement automatique
      (`scrollTo(y:)`, un quart du dépassement par pas de 16 ms, 60 pt au plus) et le
      rectangle suit. Seul le rectangle est observé, par la vue qui le dessine : la grille
      n'est mise à jour qu'au changement de sélection. Non vérifié à l'écran par moi (les
      gestes SwiftUI ne se pilotent pas dans la sonde) : à confirmer par Michaël (départ du
      tracé à côté des photos et pas sur elles, glisser d'une photo vers un album intact,
      défilement automatique sous la barre d'outils, bord flou de la barre intact).
      Validé par Michaël le même jour. Retour : en vignettes carrées, « ce n'est pas facile
      de trouver un endroit où commencer la sélection » (12 pt entre deux vignettes). Là où
      une photo ne se glisse nulle part (appareil, dossier, carte : pas d'albums), le tracé
      part aussi d'une photo, au-delà de 3 pt pour qu'un clic reste un clic ; dans Photos,
      glisser une photo la range dans un album, le tracé ne part donc que d'entre les photos.
      Retour suivant de Michaël : dans la photothèque, « la majorité des zones blanches entre
      les photos sélectionne déjà la photo ». Seule différence avec les dossiers : la vignette
      y est glissable (`.draggable`), supposée prendre les clics dans tout le carré. Puis
      « certaines lignes sont plus faciles, d'autres quasiment impossibles ». Sonde hors écran
      (60 vignettes carrées de 160 pt, test de `menu(for:)` point par point le long de lignes
      et de colonnes) : sans forme de contact, une cellule réclame bien plus que sa photo, et
      de façon inégale selon les rangées (une ligne entière, marges comprises ; deux rangées
      fusionnées sur une colonne), avec ou sans `.draggable`. Correction : `.contentShape` en
      dernier modificateur de `AssetGridCell`, le rectangle de la photo au centre du carré
      (`ThumbnailFit.displaySize` avec `asset.aspectRatio`) ; la même sonde trouve alors
      exactement 160 pt par photo et des espaces libres de 12 à 17 pt dans toutes les rangées.
      Mesuré pour le menu contextuel ; pour les gestes, à confirmer par Michaël.
      Pas suffisant : « quand je drag & drop entre la colonne 1 et 2 (quel que soit l'endroit
      sur l'axe Y), ça ne démarre jamais la sélection », avec 20 pt libres entre les colonnes.
      La sonde ne trouve aucune vue AppKit à cet endroit (seul `PlatformGroupContainer`) : le
      clic se perd dans l'arbitrage des gestes SwiftUI, que la sonde ne pilote pas, et le
      menu contextuel ne dit pas ce que voient les gestes. Changement d'approche : le geste
      n'est plus en fond, derrière les cellules (atteint seulement là où aucune ne prend le
      clic), mais en `simultaneousGesture` sur tout le contenu, et `GridMarquee` décide
      lui-même d'après les cadres des photos (la photo dessinée, plus le carré) si l'appui
      est sur une photo : il l'ignore alors là où la photo se glisse vers un album, et trace
      le rectangle ailleurs (ce qui remplace le second geste posé sur les cellules des
      appareils et dossiers). Validé par Michaël le même jour (« ça marche très bien »).
      Leçon : un geste posé en fond, derrière les cellules d'une grille paresseuse, ne reçoit
      pas tous les appuis là où rien n'est dessiné ; mieux vaut un geste simultané sur tout
      le contenu qui décide lui-même d'après les cadres.
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
      Note et drapeau dans les menus, fait le 19/11/2026 à la demande de Michaël
      (`DecisionMenuItems`) : dans le menu contextuel des vignettes (sur la sélection si la photo
      en fait partie) et dans celui de la photo ouverte, une rangée de cinq étoiles (palette du
      système, comme les étiquettes du Finder), Remove Rating, puis Pick, Reject et Remove Flag ;
      Remove Rating et Remove Flag seulement si une photo en a un, les drapeaux seulement là où la
      bibliothèque en a. Le menu Image garde ses sous-menus Rating et Flag, qui portent les
      touches (1 à 5, 0 pour Remove Rating, P, X, U).
      - Taille des étoiles : la palette dessine à sa propre taille, plus grande, un symbole
        donné par son nom ou dans un `Label`, et ignore police et `imageScale` ; elle garde la
        taille d'une `Image(nsImage:)` donnée seule (agrandie d'environ un cinquième) : symbole
        de 11 points, vu dans un menu ouvert par sonde. Ses étoiles sont toujours réparties sur
        toute la largeur du menu : sonde sur la palette avec titre, dans une `Section` et en
        `Picker` (`.pickerStyle(.palette)`), même répartition ; rien pour les serrer à gauche.
      - Sous-menu Rating : entrées en étoiles (« ★★★☆☆ »), à la demande de Michaël. Une
        `accessibilityLabel` sur la bascule n'atteint pas l'entrée de menu (sonde) : VoiceOver
        lit les caractères.
      - Essayé et abandonné le même jour : une rangée dessinée par l'appli, qui remplit les
        étoiles jusqu'à celle survolée, comme Photos (la palette encadre l'étoile survolée, et
        rien dans le SDK 27.2 ne change ça). SwiftUI ne met pas de vue à nous dans un menu :
        il fallait retrouver ses entrées par leur titre dans le menu AppKit, leur donner une
        `NSMenuItem.view`, surveiller tous les menus (`NSMenu.didAddItemNotification`…) et caler
        les étoiles sur des retraits mesurés sur macOS 27.2. Michaël a préféré revenir aux
        composants du système plutôt que de garder ce bricolage. Ce que les mesures ont appris,
        dans un menu vraiment ouvert (sonde : menu contextuel affiché une fraction de seconde,
        fenêtre à `alphaValue = 0`, cadres des vues des entrées relevés pendant le suivi ;
        `NSMenu.size` trompe) : les titres commencent à 14 points ; une entrée visible cochée
        décale tous les titres de 14 points ; dans un menu contextuel, une icône se place à 15
        points et décale son seul titre (33), alors que dans la barre de menus les entrées à
        icône ont en plus la colonne des coches sans rien de coché (icône à 27, titre à 47).
      - Icônes : depuis macOS 27, un menu masque les images de ses entrées
        (`NSMenuItem.preferredImageVisibility`, automatique par défaut) et SwiftUI n'a pas de
        réglage pour les montrer. Pick et Reject sont donc sans icône, comme le veut le système.
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
      Définir / redéfinir la localisation, commencé le 18/11/2026 à la demande de Michaël :
      section Location du panneau Info (mosaïque, une photo ou une sélection jusqu'à 50, et
      onglet Info de l'éditeur). Edit (ou Assign… sans position, « Several locations » si la
      sélection en a plusieurs) ouvre un mode d'édition : champ de recherche système
      (`SearchField`, petite taille) dont les résultats viennent de `MKLocalSearch` (adresses et
      lieux, six au plus, la région de la photo en indice), flèches et Retour comme dans Add to
      Album ; clic sur la carte pour poser l'épingle (`MapReader` + `SpatialTapGesture`, actif
      seulement en édition, pour qu'un clic de consultation ne déplace pas la photo) ; épingle
      déplaçable (`Annotation` + `DragGesture`, position suivie par la translation depuis le
      point de l'épingle). La carte ne se recentre que sur une autre photo ou un lieu choisi
      dans la recherche (`LocationEditModel.focus`), pas sous le pointeur.
      Paquets : capacité `.location`, `LibrarySource.location(for:)` / `setLocation(_:for:)`,
      `LibraryAsset.location` (les vues suivent donc la position comme la date corrigée) ;
      dossiers : clé `location` du sidecar et colonnes `latitudeOverride` / `longitudeOverride`
      de `item` (migration v8, l'en-tête reste dans `latitude` / `longitude`, une position égale
      à celle de l'en-tête à un mètre près efface la correction) ; Photos :
      `PHAssetChangeRequest.location`. `MetadataEditing.setLocations`, une étape annulable
      « Assign Location », partage désormais son écriture générique avec les dates ;
      `LocationEditModel` dans EditorKit (recherche injectée, délai de 300 ms, jumeau JPEG
      inclus via `LibrarySource.withTwins`, aussi utilisé par Adjust Date & Time).
      Vérifié : 215 tests de LibraryKit et 87 d'EditorKit (sidecar, migration, source dossier,
      modèle : recherche, annulation, jumeau, sélection mixte), compilation de l'appli, et sonde
      hors écran du panneau (photo placée avec « Edit », sans position avec « Assign… »,
      sélection de deux lieux). Non vérifié, à essayer à l'écran : le mode d'édition lui-même
      (la sonde ne presse pas les boutons SwiftUI), le glisser de l'épingle (un `DragGesture`
      dans une `Annotation` pourrait aussi faire glisser la carte), le clic sur la carte et le
      double clic de zoom (qui pose aussi l'épingle), les résultats réels de `MKLocalSearch`,
      et l'écriture dans la vraie photothèque.
      Essai de Michaël le même jour (vidéo) : la carte, la recherche et le clic vont, mais le
      glisser de l'épingle « vibre et ne suit pas bien le curseur » ; sur les images, l'épingle
      traîne derrière le pointeur avec une image fantôme. Deux causes : la translation du
      `DragGesture` était lue dans le repère de l'épingle, qui bouge avec elle (rétroaction), et
      MapKit replace ses annotations une ou deux images en retard. Repris : translation lue en
      `.global` (repère fixe), épingle dessinée par SwiftUI au-dessus de la carte pendant le
      geste (calque `overlay`, `position`), l'annotation restant en place, invisible, pour garder
      le geste ; au lâcher, la position lâchée reste affichée jusqu'à ce que celle de la photo
      suive (une seconde au plus si l'écriture échoue). Non vérifié à l'écran.
      Puis, accordé par Michaël : position corrigée dans les exports, retrait et retour à la
      position du fichier, menus.
      - Correction à trois états (`LocationCorrection` dans ImageIOKit : un lieu, retirée, ou
        rien) : sidecar `"location": "none"`, colonne `locationRemoved` (migration v9 ; la v8
        était déjà appliquée chez Michaël). `setLocation(nil)` dit « sans position » même si
        l'en-tête en a une ; écrire ce que dit l'en-tête efface la correction, donc l'annulation
        (qui réécrit la position lue avant) retrouve exactement l'état d'avant.
        `LibrarySource.originalLocation(for:)` et capacité `.originalLocation` (dossiers ; pas
        Photos, dont PhotoKit ne donne pas la position d'origine).
      - Exports : `ExportInput.location`, comparée à l'en-tête comme la date
        (`LocationCorrection.between`) ; `ImageMetadataWriter.applying` remplace le bloc GPS par
        latitude et longitude seules (l'altitude était celle de l'autre lieu) ou le retire.
        « Remove location » de l'export retire aussi une position corrigée.
      - `MetadataEditing.removeLocations` / `revertLocations` (« Remove Location », « Revert to
        Original Location », jumeau JPEG compris) ; menu ⋯ dans l'en-tête de la section ; menu
        Image › Location (Assign Location…, Remove Location, Revert to Original Location, valeur
        de focus `locationAction`) ; sous-menu Location du menu contextuel des vignettes (sans
        lire les photos, le menu étant construit pour chaque vignette : les éléments ne font
        rien aux photos qu'ils ne concernent pas). Assign Location… sélectionne les photos,
        montre l'inspecteur (onglet Info dans l'éditeur) et passe par `LocationEditRequest`,
        que la section prend quand elle montre ces photos ; le champ de recherche se fait
        défiler en vue avec la carte (`scrollToVisible`), la section étant souvent sous le pli.
      Vérifié : 215 tests de LibraryKit, 88 d'EditorKit, 97 de RenderEngine, 10 d'ImageIOKit,
      compilation de l'appli, sonde du panneau (menu ⋯ à côté d'Edit). Non vérifié : tout ce
      qui passe par les menus et les gestes, et le défilement vers la section.
      Essai de Michaël après correction : glisser et menus vont. Il trouvait le bouton « Done »
      peu visible, et craignait qu'on déplace l'épingle sans valider ; en fait chaque changement
      est écrit aussitôt, le bouton ne fait que sortir du mode. Écartés : une phrase sous la
      carte (trop d'éléments, selon Michaël) et une validation explicite (un état non enregistré
      à gérer). Retenu, sur son idée : « Edit » / « Done » remplacés par un bouton-bascule crayon
      (`Toggle` en `.toggleStyle(.button)`, style `.accessoryBar`, forme `.circle`), enfoncé
      dans un rond gris pendant l'édition, comme le bouton d'annotation d'Aperçu ; libellé et
      infobulle changent avec l'état. Rendu vérifié par sonde, clair et sombre : le style
      `.borderless` ne montrait l'état que par la teinte de l'accent (grise dans l'appli, donc
      invisible), le style par défaut en cercle ne le montrait pas du tout. Puis, le crayon
      faisant « quasiment juste un trait » (Michaël), symbole `mappin.and.ellipse` (une épingle
      posée), choisi parmi six comparés par sonde ; `square.and.pencil` était l'autre candidat.
      Reste : suggestions au fil de la frappe (`MKLocalSearchCompleter`) si `MKLocalSearch`
      déçoit ; Location dans le menu contextuel du canevas de l'éditeur.
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
      - [x] Satellite (13/11/2026, demandé par Michaël) : préférence `libraryMapStyle`
            (`LibraryMapStyle`), bouton bascule dans la barre d'outils quand la carte est
            affichée (`SatelliteToggle`, à la place du bouton de forme des vignettes, sur le
            même modèle) et View › Standard Map / Satellite. Le satellite est le style hybride
            de MapKit : noms de lieux et routes par-dessus l'imagerie, sans quoi on ne sait
            plus où est un groupe. Plutôt qu'un troisième segment « Satellite » dans le
            sélecteur comme chez Apple : Grille / Carte dit ce qu'on regarde, le style dit
            comment la carte est dessinée, et la barre d'outils de la mosaïque est déjà pleine.
            Vérifié par sonde : bouton présent, `MKMapView` en configuration hybride. Le rendu
            de l'imagerie reste à voir à l'écran.
      - [x] Retour sur une bibliothèque (13/11/2026). Signalé par Michaël : en passant des
            dossiers à Photos en mode carte, la carte montrait la France vide pendant le
            chargement, puis sautait sur le monde entier. Deux causes : le modèle de carte
            vivait dans l'état de `LibraryContentView`, recréé à chaque changement dans la
            barre latérale, donc tout était relu ; et la `Map` s'affichait avant la lecture des
            positions, sur la région par défaut du système (le pays de l'utilisateur). Corrigé
            par `PhotoMapModels`, tenu par la fenêtre (`MainWindowView`) : un modèle par
            bibliothèque, gardé tant qu'elle vit, donc photos, vignettes, lieu et zoom sont
            retrouvés tels quels ; et par `PhotoMapView`, qui n'affiche la carte
            (`PhotoMapCanvas`) qu'une fois les positions lues, déjà cadrée, avec un indicateur
            d'attente d'ici là. Sonde avec deux bibliothèques : première ouverture directement
            cadrée sur les photos, retour sur la première carte au lieu et au zoom laissés, sans
            passage par un état sans carte. Coût : chaque bibliothèque vue en carte garde son
            index et jusqu'à 400 vignettes (26 Mo au plus) pour la durée de la fenêtre.
      - [x] View › Zoom In / Zoom Out sur la carte (13/11/2026) : valeur de focus
            `mapZoomAction` posée par `PhotoMapCanvas`, prioritaire sur la mosaïque et après le
            canevas de l'éditeur ; double ou divise par deux ce que la carte montre, autour du
            même centre, et compte comme un déplacement de l'utilisateur (plus de recadrage
            automatique). Compilé, non vérifié à l'écran : la sonde n'a pas le menu de l'appli.
      - [x] Nom du lieu dans le panneau Info (13/11/2026, accord de Michaël après évaluation).
            `PlaceNames` (LibraryKit, sans MapKit) : une question par lieu, la position arrondie
            au millième de degré (une centaine de mètres) servant de clé de cache et étant ce
            qui est envoyé ; une recherche en cours est partagée, un échec (réseau, débit) est
            redemandé, un lieu sans nom est retenu. La recherche elle-même est injectée :
            `PlaceNames.apple` (appli) passe par `MKReverseGeocodingRequest` (`CLGeocoder`
            est déprécié depuis macOS 26) et compose « ville, pays » (`cityName`,
            `regionName`, à défaut le nom rendu : un océan, un massif). Essai sur des lieux
            publics : « Paris » + « France », « Étretat » + « France », « Courmayeur » +
            « Italy », « North Atlantic Ocean ». `LocationSection` remplace la section des
            deux panneaux Info : le nom est le pied de section, la carte ne bouge donc pas
            quand il arrive. Vérifié par tests et par sonde (« Étretat, France » sous la carte).
            Cache en mémoire seulement, le temps d'une session. Pas fait, et pas simple : nommer
            les groupes de la carte ou chercher par lieu, qui demanderaient un index des lieux
            construit lentement, Apple limitant le débit des requêtes.
      - [x] Bibliothèque fusionnée « All Photos », premier temps (13/11/2026 ; réduite le
            même jour à la carte de tout, voir plus bas). Décidé avec
            Michaël : une entrée « All Photos » en tête de la barre latérale, les sections
            « Apple Photos » et « Folders » inchangées dessous, et une bibliothèque complète
            (mosaïque et carte) plutôt qu'une carte seule, qui aurait été une impasse dès
            qu'on ouvre un groupe mêlant les deux origines.
            `CombinedLibrarySource` ne tient aucune photo : chaque membre liste les siennes sous
            la même requête, leurs listages sont tissés par date (`ListingMerge` : fusion de
            listes triées, hors du fil principal, qui donne pour chaque rang la ligne de quel
            membre, l'inverse, et les mois), et tout ce qu'on demande sur une photo va au
            membre qui la tient. Les identifiants restent ceux des membres : une photo est la
            même ici et dans sa bibliothèque. Les vues ne changent pas, elles ne voient qu'une
            `any LibrarySource` ; la carte, le panneau Info, l'éditeur et l'annulation suivent
            sans code particulier.
            Les membres sont des instances propres à « All Photos », puisqu'elle règle leur
            requête : un second `PhotosLibrarySource` sur le même index, et pour chaque dossier
            une seconde vue qui suit le catalogue sans analyser (`scans: false`) ; ouvrir « All
            Photos » lance l'analyse des dossiers par leur source habituelle (`prepare`).
            Filtrer « All Photos » ne touche donc pas à ce que montrent Photos et les dossiers.
            Nouveau dans `LibrarySource` : `listingDates()`, la date par laquelle chaque ligne
            est listée. Photos les lit hors du fil principal et les garde tant que le listage
            ne gagne, ne perd ni ne déplace de photo (Photos signale des changements toutes
            les une à deux secondes pendant ses analyses) ; les dossiers les ont en mémoire, et
            rendent nul pour une photo sans date de prise de vue, listée en dernier.
            Limites de ce premier temps : seuls les tris par date (prise de vue, modification)
            sont proposés, les listages triés par note ou par nom ne se tissant pas ; seules
            les capacités communes sont offertes, donc ni drapeaux (dossiers seulement), ni
            favoris, ni albums, ni Show in Finder dans « All Photos » ; chaque changement d'un
            membre retisse tout (dates en cache, donc quelques dizaines de ms hors du fil
            principal, mais la mosaïque est redessinée). La première ouverture attend la
            lecture des dates de Photos (une à deux secondes pour 74 000 photos, à mesurer :
            journaux `PhotosLibrarySource` « Listing dates » et `CombinedLibrarySource`).
            Vérifié : tests du tissage, de la source combinée (ordre, filtres, décisions,
            retouches, carte, membres qui changent, dossier et sa seconde vue sur un catalogue
            partagé), sonde sur deux bibliothèques d'exemple (barre latérale, mosaïque de 50
            photos tissées avec ses mois, carte de 5 groupes mêlant les deux). Non vérifié :
            tout ce qui touche la vraie photothèque et de vrais dossiers.
      - [x] Plantage à l'ouverture d'un sous-dossier (13/11/2026, signalé par Michaël). Rapport
            de crash : `assets[index]` hors limites dans le `ForEach` de la mosaïque
            (`ForEachChild.updateValue`). Reproduit par sonde sur un dossier de 40 PNG datés
            sur plusieurs mois dont 3 dans un sous-dossier, que le dossier soit déjà à l'écran
            ou listé d'avance ; pas avec des photos toutes du même mois, ce qui explique que
            l'essai du 12/11 (62 photos, sous-dossier de 2) ne l'ait pas vu. Rejoué sur le
            code d'avant cette session (commit 857f1c7) : le plantage y est déjà, depuis la
            navigation par mois. Cause : une cellule ne lit que `assets[index]`, mais elle peut
            être recalculée avant les sections de mois qui la portent quand le listage
            rétrécit ; elle demande alors une ligne qui n'existe plus. Corrigé par une
            vérification des bornes dans la cellule (leçon ajoutée à AGENTS.md). Sonde après
            correction : les quatre scénarios passent.
      - [x] Lenteur causée par cette vérification, signalée par Michaël le 17/11/2026 (photothèque
            Photos : sélection d'une photo affichée au moins 1 s après le clic, repli de la barre
            latérale en 3 à 4 s). Cause : le `if` nu dans le `ForEach` fait de chaque rangée
            zéro ou une vue ; la grille paresseuse ne sait alors plus où est une rangée sans
            construire toutes celles au-dessus, et le refaisait à chaque mise à jour, d'autant
            plus cher qu'on est loin dans la photothèque (et chaque rangée construite demande
            sa photo à PhotoKit). Corrigé en mettant la vérification dans un `ZStack` : une
            rangée, une vue (leçon ajoutée à AGENTS.md).
            - Mesures (sonde, Debug, 74 000 photos factices sur 237 mois, grille au milieu) :
              sélection d'une photo 124 ms avant, 13 ms après (12 ms en haut de la grille dans
              les deux cas) ; un pas de changement de largeur 60 à 500 ms avant, 7 à 42 ms
              après ; repli de la barre latérale dans la vraie `LibraryContentView` : un tour de
              boucle bloqué 3 643 ms avant, 66 à 211 ms cumulés après (pire tour 76 ms).
            - Effet de bord découvert : avec le `if` nu, `scrollTo(id:)` n'amenait pas la grille
              à une rangée lointaine dans cette photothèque (elle restait en haut) ; le retour à
              sa place (bouton Back) n'y aurait donc pas marché.
            - Au repos l'app ne consomme rien (échantillon du fil principal). Lecture des albums
              d'une photo, relevée dans les journaux de Michaël : 70 à 312 ms, hors acteur
              principal.
            - Confirmé par Michaël le 17/11/2026 (« beaucoup mieux »). Reste : le journal signale
              « OnScrollGeometryChange tried to update multiple times per frame » (3 fois en
              12 min), non traité.
      - [x] Grille qui se décale au repli de la barre latérale, signalé par Michaël le
            17/11/2026 : en la cachant, des photos plus anciennes s'affichaient ; en la
            remontrant, on revenait aux premières. Cause : plus ou moins de colonnes font
            d'autres rangées, et le défilement gardait le même décalage en points. La grille
            garde maintenant en place la première vignette entièrement visible d'avant le
            changement de largeur (`GridViewport.update`, même repérage que `GridPlace`), pour
            toute la durée du redimensionnement.
            - Trois façons essayées (sonde, 74 000 photos, grille au milieu, cumul des tours de
              plus de 20 ms par repli) : réaligner à chaque image de l'animation, exact mais
              250 à 390 ms (autant que la mise en page elle-même) ; réaligner une seule fois au
              début, 100 ms mais la place est perdue au changement de colonnes suivant
              (SwiftUI ne tient pas une rangée par son identifiant quand la largeur change) ;
              réaligner quand la hauteur du contenu change, c'est-à-dire quand les rangées
              sont refaites : exact (159,5 pt avant, 159,5 après élargissement, rétrécissement
              et retour) pour 60 à 120 ms à l'affichage de la barre et 180 à 310 ms au repli.
              Retenu.
            - La place est lue quand les cellules ont rapporté leurs cadres
              (`updateVisibleRows`), pas au rapport de géométrie du défilement, qui a une image
              de retard : lue là, elle était décalée d'un cran de molette (80 pt).
            - Dans la sonde, un défilement fait sur la `NSClipView` après un `scrollTo(id:)` est
              refusé, alors que la molette (`scrollWheel(with:)`) passe : tester le défilement
              par la molette.
            - Animation de la barre latérale encore « un peu lente » (Michaël) : le profil
              (`sample`) montre que le temps est dans la mise en page de la grille paresseuse à
              chaque image (`LazySubviewPlacements`, parcours des 237 sections), pire tour 60 à
              110 ms en Debug. Pistes non faites : figer la largeur de la grille pendant
              l'animation et la refaire une fois à la fin ; ne garder dans la grille que les
              mois proches de ce qui est affiché.
            - Largeur de la grille figée pendant l'animation, fait le 17/11/2026 (choix de
              Michaël après essai de la version Release) : `SettledWidth` autour de la grille,
              `GridWidthSettler`. Au repos la grille est épinglée à la largeur offerte ; quand
              celle-ci change, la grille garde la sienne, contre le bord qui ne bouge pas, et
              prend la nouvelle une seule fois, 100 ms après le dernier changement. Une fenêtre
              redimensionnée à la main n'attend pas (la grille suit en direct, épingle levée
              entre `willStartLiveResize` et `didEndLiveResize`).
              - Mesure (sonde, 74 000 photos, repli par `toggleSidebar`, tours de plus de
                20 ms) : avant, 6 à 9 tours lents de 21 à 157 ms répartis sur l'animation ;
                après, aucun pendant les 250 ms de l'animation, puis un ou deux à la fin (30 à
                60 ms) pour refaire les rangées. Les mêmes dates restent à l'écran.
              - Essais écartés. (1) Déclencher par `onChange(of: columnVisibility)` : par le
                menu système, la liaison ne change qu'à la fin de l'animation (tracé dans la
                sonde), trop tard. (2) Une `Layout` sur mesure qui décide de la largeur
                pendant la mise en page, puis un `GeometryReader`, puis une surcouche
                (`overlay`) : la vue de défilement y perd l'estompage sous la barre d'outils,
                les photos passent nettes sous le titre (couleur moyenne sous la barre 92/143/103
                au lieu de 217/226/219) ; `scrollEdgeEffectStyle` ne le rétablit pas, et
                `frame(minWidth: 0, maxWidth: .infinity)` le casse aussi. Seuls les cadres
                `frame(width:)` et `frame(maxWidth:)` le gardent. (3) Un cadre à maximum seul
                s'élargit avec une grille épinglée plus large que la place offerte : le
                rétrécissement n'était jamais vu. D'où le cadre de largeur nulle autour de la
                grille épinglée, qui la sort du calcul de largeur sans la rogner.
              - Retour de Michaël le même jour : très rapide, mais au repli une grande zone
                blanche là où était la barre latérale, puis la mosaïque qui s'y place d'un coup.
                Corrigé selon sa première idée, placer la mosaïque d'abord : quand la largeur
                grandit, la grille prend dès la première image la largeur qu'elle aura (sa
                largeur plus la place que la barre latérale occupait depuis le bord de la
                fenêtre, ou la largeur de l'inspecteur), sous la colonne, qui découvre en
                glissant des photos déjà en place. Quand la largeur diminue, rien ne change :
                la colonne recouvre une grille qui remplit encore sa place, refaite à la fin.
                Pas de prédiction bouton de souris enfoncé (bord tiré à la main). Mesure
                (sonde) : au repli, un tour de 80 à 98 ms à la première image, plus rien
                pendant l'animation, et pas de seconde mise en page à la fin (la largeur
                prédite est la bonne). Autres idées de Michaël non faites : animer le
                déplacement des vignettes, supprimer l'animation de la barre latérale.
              - Limites : la première image d'un maintien peut garder l'autre bord (le bord
                qui bouge n'est connu qu'après la mise en page) ; quand le changement n'est pas
                animé, les rangées sont refaites 100 à 150 ms après. Non vérifié à l'écran :
                le bouton de la barre d'outils dans l'app (animé ou non), l'inspecteur, le
                redimensionnement de la fenêtre à la main, le bord de la barre latérale tiré.
            - Mesure en Release (même sonde, 17/11/2026) : le repli ne change pas (226 à 330 ms
              cumulés au repli, 92 à 117 ms à l'affichage, pire tour 69 à 107 ms, comme en
              Debug) : le temps est dans SwiftUI, déjà optimisé, pas dans notre code. La
              sélection d'une photo passe de 13 ms à 5 à 9 ms. La compilation n'est donc pas un
              levier pour l'animation.
      - [x] Mesures sur la photothèque de Michaël (journaux du 13/11/2026, 74 051 photos, un
            dossier de 25 fichiers) : premier listage de Photos 1 304 ms, le second (membre
            d'« All Photos ») 103 ms ; dates du listage 1 300 ms, lues deux fois en même temps
            par deux tissages ; tissage de 74 075 photos 1 361 ms, lecture des dates comprise ;
            positions pour la carte 1 480 ms (47 601 photos placées), presque tout dans
            l'énumération des identifiants par PhotoKit ; index de la carte 120 ms.
            Corrigé dans la foulée : une lecture des dates en cours est partagée
            (`listingDatesReading`) ; les positions de la photothèque entière sans filtre
            viennent de l'index seul, moins les jumeaux JPEG masqués, sans énumérer le listage.
            À remesurer à l'écran.
      - [x] « All Photos » réduite à la carte de tout (13/11/2026). Question de Michaël après
            essai : la pertinence d'une mosaïque fusionnée, vu qu'elle n'offre que les
            capacités communes et vu son coût. Décision, sur ma recommandation : on garde la
            carte fusionnée, qui était le besoin de départ, et on abandonne la mosaïque de
            tout. Raisons : Photos et les dossiers n'ont pas les mêmes fonctions (drapeaux d'un
            côté ; favoris et albums de l'autre), donc la mosaïque commune est toujours en
            retrait de chacune, et chaque fonction à venir aurait dû être pensée pour le cas
            mixte ; elle coûtait la lecture des dates de toute la photothèque à chaque
            ouverture et à chaque changement (1,3 s mesurés). Le nombre de photos des dossiers
            n'entre pas dans le raisonnement : le dossier de Michaël n'était qu'un essai.
            Ce qui change : l'entrée s'appelle « Map » (`LibrarySelection.map`,
            `MapLibraryView`, `LibraryCatalog.everywhere`) et montre toujours la carte, sans
            sélecteur Grille / Carte (`LibraryContentView.showsOnlyMap`).
            `CombinedLibrarySource` ne liste rien tant qu'aucun groupe n'est ouvert : pas de
            lecture de dates, pas de tissage ; le double clic sur un groupe tisse les seules
            photos du groupe (quelques ms). Tout le reste du travail du premier temps sert tel
            quel : membres propres, tissage, routage par photo, carte commune. View › Map Style
            est actif dès qu'une carte est à l'écran (elle le dit par son action de zoom).
            Vérifié : 182 tests de LibraryKit, sonde (carte de 25 photos de deux bibliothèques
            d'exemple, groupe de 5 ouvert en mosaïque avec ses mois et le bouton de retour,
            retour à la carte). Limite : dans la mosaïque d'un groupe, seules les capacités
            communes sont offertes, donc ni drapeaux, ni favoris, ni albums, ni Show in Finder.
      - [x] Carte sous la barre d'outils (13/11/2026, remarque de Michaël sur capture : « le
            panneau de droite apparaît un peu bizarrement »). La `Map` s'étendait sous la barre
            d'outils (mesuré par sonde : de 0 à 800 dans une fenêtre de 800), ce que la colonne
            Info, faite à la main dans un `HStack`, ne fait pas : barre aux couleurs de la carte
            d'un côté, de la fenêtre de l'autre, champ de recherche à cheval. Corrigé par un
            filet au-dessus de la carte, qui la tient sous la barre comme les photos de la
            mosaïque (mesuré après : de 0 à 747). Elle passe toujours sous la barre latérale,
            qui est en verre.
      - [x] Inspecteur système (`.inspector(isPresented:)`) à la place de la colonne faite à la
            main, essayé puis gardé le 16/11/2026 (question de Michaël : le panneau de droite
            devrait-il avoir le design de celui de gauche ? Oui : barre latérale et inspecteur
            sont la même couche flottante dans les recommandations d'Apple). Converti pour la
            mosaïque, la carte et l'éditeur ensemble, pour que le panneau ne change pas de
            nature quand on ouvre une photo ; largeur fixe de 280 points
            (`inspectorColumnWidth`), même réglage d'affichage qu'avant.
            Carte : le filet qui la tenait sous la barre d'outils est retiré, elle repasse sous
            la barre, la barre latérale et l'inspecteur (sonde : 0 à 1358 en largeur, 0 à 800
            en hauteur). Mesuré : la région que MapKit annonce et la taille que SwiftUI donne
            sont celles de la zone que rien ne couvre (878 points de large pour une carte de
            1358), donc le calcul du zoom reste juste ; les groupes situés sous les panneaux
            sont demandés en plus (marge élargie de ce que les panneaux couvrent).
            Éditeur : l'inspecteur est posé sur le canevas seul, la barre du bas garde toute la
            largeur (posé sur l'ensemble, elle perdait 280 points et tronquait ses boutons).
            Masqué, il reste vivant : les 214 vues du formulaire sont les mêmes avant, pendant
            et après (comparaison d'identités), donc pas de reconstruction de 150 ms au retour.
            Leçon de sonde : un inspecteur système ne se replie pas dans une fenêtre hors
            écran ; il faut la poser sur un écran, à 1 % d'opacité et sourde à la souris.
            Bascules à état (16/11/2026, demande de Michaël après essai de l'inspecteur : que
            le bouton du panneau affiche son état, et celui de la barre latérale aussi). Les
            recommandations d'Apple (page Toggles, relue) : hors d'une liste, un bouton qui se
            comporte en bascule, aux états visiblement différents. `ColumnVisibilityToggle`
            (`Toggle` en style bouton, composant système déjà utilisé pour la forme des
            vignettes et le satellite) sert aux deux côtés : `InspectorVisibilityToggle` et
            `SidebarVisibilityToggle`. Pour la barre latérale, le bouton du système, qui ne
            montre pas d'état, est retiré (`.toolbar(removing: .sidebarToggle)`) et le nôtre
            suit `columnVisibility` ; View › Show / Hide Sidebar continue de marcher.
            Essais de placement, par sonde : avec un espace fixe entre Add Folder et la
            bascule, celle-ci partait dans le menu de débordement une fois la barre latérale
            masquée (plus moyen de la rouvrir d'un clic) ; en élément de navigation, elle
            restait visible mais sortait de l'en-tête de la barre latérale. Retenu : espace
            flexible puis Add Folder et la bascule, au bord droit de l'en-tête comme le bouton
            du système, tous deux visibles barre masquée ; le système les réunit dans une même
            capsule. Vérifié par sonde en changeant l'état (volets repliés, infobulles « Show
            the… », bascule de l'inspecteur surlignée quand il est montré) ; le clic lui-même
            n'a pas pu être simulé.
            Couleur d'accent (16/11/2026). À l'écran, Michaël trouve les deux bascules et la
            sélection « un peu trop bleu » pour un logiciel de photo, et montre Pages, où
            l'état des boutons d'inspecteur est un gris neutre. Les recommandations d'Apple
            (page Color, relue) : une appli peut fixer sa couleur d'accent, appliquée aux
            boutons, à la sélection et aux icônes de barre latérale tant que le réglage du
            système est « Multicolore » (c'est le cas chez Michaël : aucune clé
            `AppleAccentColor`), et remplacée par le choix de l'utilisateur sinon. Fait :
            `AccentColor` dans un catalogue de ressources (`Qaama/Resources/Assets.xcassets`),
            le gris système (142, 142, 147 en clair ; 152, 152, 157 en sombre), proche de
            l'accent Graphite de macOS ; `NSAccentColorName` dans l'Info.plist. Vérifié dans le
            paquet compilé (clé présente, couleur dans `Assets.car`). Pas vu : les captures de
            la sonde dessinent tout en gris, appli inactive, même en lui faisant croire qu'elle
            est active ; `.tint` sur une bascule de barre d'outils et `ControlGroup` n'y
            montraient donc rien de plus. Écart avec Pages : ses deux boutons sont un contrôle
            segmenté (segment choisi en gris clair, icône sombre), comme notre sélecteur
            Grille / Carte ; nos bascules seront un disque gris à icône blanche.
            Sélection (16/11/2026, retour de Michaël après essai du gris : « les photos
            sélectionnées sur la mosaïque se distinguent peu des autres »). Le liseré suivait
            l'accent, qu'une photo avale une fois gris. Premier essai : anneau épais de la
            couleur du texte posé sur le bord de la photo, doublé d'un filet clair (« pas très
            beau, mais ça marche »). Trois variantes montrées à Michaël, rendues par sonde en
            clair et en sombre : cet anneau, un anneau détaché, une plaque grise façon Finder.
            Il préférait la plaque à l'œil, a retenu l'anneau détaché comme plus universel.
            `SelectionRing` : anneau de 2 points à la couleur du texte autour de la photo, dont
            une bande de 3 points à la couleur du fond la sépare ; la bande couvre le bord de
            la photo au lieu de la rétrécir et l'anneau est tracé juste hors de ses limites,
            donc rien ne bouge quand la sélection change. Sert à la mosaïque (vignettes
            carrées ou entières), au groupe choisi sur la carte et à la liste d'export. Vu par
            sonde sur les vraies cellules, en clair et en sombre.
            Essayé à l'écran par Michaël et gardé (« ça me semble très bien »). Pas mesuré
            sous un vrai glissement : le tremblement des curseurs de l'éditeur, à surveiller.
      - [ ] Dans la mosaïque d'un groupe de la carte de tout : offrir photo par photo ce qui
            n'existe que d'un côté (drapeaux, favoris, Show in Finder), si le besoin s'en fait
            sentir.
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
      Interrupteur par catégorie de réglages (demandé le 11/11/2026), fait : `AdjustmentGroup`
      dans la recette (groupes coupés, valeurs gardées), `AdjustmentSet.effective` pour le
      rendu, `SectionSwitch` en tête de chaque carte de l'inspecteur.
      Noms précis des étapes d'annulation dans le menu Edit (18/11/2026, `EditActionName`).
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
- [x] Débruitage (« Denoise »), étape 1, demandé par Michaël le 19/11/2026. Fait le même jour.
      - Deux curseurs, luminance et couleur, dans une carte « Denoise » à interrupteur, à la place
        de l'ancien curseur « Noise Reduction » de la carte Detail (`CINoiseReduction` appliqué
        tard dans la chaîne, sur un bruit déjà amplifié par l'exposition et les courbes).
      - Le débruitage appartient au décodage, pas à la chaîne : `AdjustmentSet.denoise`
        (`Denoise`, deux quantités optionnelles) n'est lu que sur le calque global
        (`EditRecipe.sourceDenoise`) et la carte est absente d'un calque masqué. Une quantité
        absente laisse le réglage par défaut de la photo ; zéro est donc un vrai réglage (un RAW
        reçoit du débruitage de couleur par défaut : 0,5 sur les RAF essayés, 0 en luminance à
        160 ISO). Les curseurs partent de ces valeurs par défaut (`SourceImage.defaultDenoise`).
      - RAW : les réglages du moteur d'Apple (`CIRAWFilter.luminanceNoiseReductionAmount` et
        `colorNoiseReductionAmount`), qui connaît le capteur et la sensibilité. `RAWDecoder` garde
        le filtre du premier décodage, sous verrou (`Mutex`), et `SourceImage.image(denoise:)`
        redemande une image à chaque position du curseur.
      - JPEG, HEIC et RAW sans ces réglages : `DenoiseFilter`, en filtres Core Image sans noyau
        maison, en valeurs d'affichage (courbe sRGB). Couleur : la luma de l'image et les couleurs
        d'une copie floutée à demi-échelle (rayon 8 px au maximum). Luminance : `CINoiseReduction`.
        C'est le niveau « simple » : au maximum, les couleurs bavent un peu autour des contours
        très saturés.
      - Retouches : un remplissage copie le grain qui l'entoure, donc il dépend du débruitage.
        `EditorModel` recalcule les remplissages 300 ms après le dernier changement de débruitage,
        en gardant les anciens à l'écran entre-temps, et un rendu demandé pendant ce délai calcule
        les siens (`currentFills`).
      - Le brouillon d'un RAW (demi-échelle, affiché un instant à l'ouverture) ne porte pas le
        débruitage de la recette : il arrive avec la pleine résolution.
      - Mesures (RAF public de X-T4, 26 Mpx, raw.pixls.us, contexte Metal comme celui du canevas,
        vue de 3000 px, Debug) : curseur de luminance sur le décodage 5 à 15 ms par position en
        vue entière et 2 à 7 ms à 100 % ; curseur de couleur 17 à 20 ms en vue entière (au-dessus
        d'une image, c'est le moteur RAW sur le GPU) ; ensuite un autre curseur (exposition) sur
        un débruitage stabilisé : 2 ms, Core Image garde l'image. Même image en non-RAW :
        luminance 5 à 6 ms, couleur 4 à 11 ms (15 à 70 ms avant de flouter à demi-échelle).
      - Leçon : changer un réglage de bruit sur le même `CIRAWFilter` ne refait pas le
        dématriçage (Core Image garde cet étage), alors qu'un nouveau filtre sur le même fichier
        redécode tout (250 à 700 ms).
      - Leçon : ne pas marquer en `insertingIntermediate(cache: true)` une image par position de
        curseur. Mesuré sur 40 positions : 6 Go d'empreinte et des rendus de 25 à 260 ms, contre
        une empreinte stable et 18 ms sans marquage. Une image réutilisée telle quelle est gardée
        par Core Image sans qu'on le demande.
      - Leçon : `CIGuidedFilter` (lissage guidé par les contours) a donné des couleurs fausses et
        des taches sur l'essai : écarté. Le flou de couleur en lumière linéaire fait des taches
        arc-en-ciel sur fond clair : le faire en valeurs d'affichage.
      - Limite : pas de RAW bruité à haut ISO dans les fichiers publics essayés (160 ISO, poussés
        de 3 IL pour voir le bruit), où le curseur de luminance du moteur RAW agit peu puisqu'il
        se cale sur la sensibilité. La qualité à haut ISO reste à juger par Michaël sur ses photos.
      - Retour de Michaël le 19/11/2026, à l'usage : « pas mal » ; le curseur de luminance floute
        un peu la photo, mais aide à petites doses. Pas de suite prévue : c'est le comportement
        attendu d'un débruitage sans modèle, et le développement des RAW bruités peut passer par
        un outil dédié (PureRAW).
      - Le champ `noiseReduction` disparaît de la recette : les sidecars qui le portaient
        s'ouvrent sans lui (pas de rétrocompatibilité à ce stade).
- [ ] Recadrage, redressement, rotation, perspective simple.
      Fait le 30/10/2026 : cadre à poignées, grille des tiers, rapports verrouillables
      (original, carré, 3:2, 4:3, 16:9, 5:4), redressement ±45° avec rognage automatique des
      coins, quarts de tour, retournement. Reste : perspective, rapports personnalisés et
      préréglages de rapports (demandé par Michaël, plus tard).
- [ ] Préréglages (sauvegarde/import de recettes), copier/coller les ajustements.
      Fait le 30/10/2026 : préréglages en fichiers JSON dans Application Support (appliquer,
      enregistrer, supprimer), copier/coller des ajustements entre photos (le recadrage reste
      propre à chaque photo). Reste : import/export de préréglages, dossiers de préréglages.
- [x] LUT, demandé par Michaël le 16/11/2026 (« un peu comme dans Photomator », avec un aperçu
      des LUT avant d'en choisir un, et des fichiers importés qui restent dans l'appli).
      Fait le 16/11/2026.
      - Recette : `AdjustmentSet.lut` (`LUT` : interrupteur, nom de la table, intensité 0 à 1),
        donc par calque et masquable comme le reste. La recette porte le **nom** de la table, pas
        ses couleurs (36 000 à 275 000 triplets : trop pour un sidecar ou `PHAdjustmentData`).
        Limite assumée : le sidecar n'est plus portable seul, il faut aussi le fichier `.cube`.
        Une table absente de la bibliothèque laisse la photo telle quelle, le menu l'affiche
        « (Missing) », et la réimporter sous le même nom rend son rendu à la photo.
      - Bibliothèque : `LUTLibrary` (RenderEngine) garde les `.cube` d'origine dans
        `Application Support/LUTs`, un fichier par table, nom du fichier = nom de la table (même
        principe que les préréglages et les filigranes ; le dossier se complète à la main).
        L'import lit le fichier en entier pour le refuser tout de suite s'il n'est pas utilisable
        (erreur typée, affichée telle quelle) ; réimporter le même fichier ne crée pas de
        doublon, un autre fichier du même nom prend un compteur. Les rendus (canevas, export,
        vignettes, lots) passent tous par `LUTLibrary.shared` : aucun appelant à modifier, et un
        paramètre `luts:` pour les tests. Cache mémoire borné à 64 Mo, dernières tables servies.
      - Format : `.cube` 3D seulement (Resolve, Adobe), avec `DOMAIN_MIN/MAX` et
        `LUT_3D_INPUT_RANGE` (table réajustée sur 0…1), commentaires, titre, BOM, fins de ligne
        Windows. Les LUT 1D sont refusés avec un message clair. Autres formats (`.3dl`, images
        HALD) : à voir si le besoin se présente.
      - Lecture : cible `CubeLUT` du paquet RenderEngine, Swift pur, compilée en `-O` même en
        Debug comme `HealingFill`. Mesuré : table de 65 points (275 000 lignes, 6,6 Mo de texte)
        lue en 14 ms, donnée Core Image comprise 15 ms ; une table de 33 points en 2 ms environ.
        Assez rapide pour lire la table au premier survol, sans tâche de fond. Au-delà de 65
        points, la table est rééchantillonnée à 65 (trilinéaire) : `CIColorCube` accepte 128
        (vérifié sur macOS 27), mais ce serait 34 Mo de flottants par table.
      - Rendu : `CIColorCubeWithColorSpace` en sRGB (les LUT photo sont faits pour des valeurs
        d'affichage), puis `CIMix` avec l'image d'avant pour l'intensité : le mélange reste sur
        le GPU, rien n'est recalculé par mouvement de curseur. Ordre : après le noir et blanc
        (un LUT peut le virer en sépia), avant le grain et la vignette. Mesuré sur GPU à
        24 Mpx, cache de Core Image coupé : 4,5 ms sans LUT, 4,7 ms avec une table de 33 points,
        6,4 ms avec une table de 65 points (dont 2 ms à construire le graphe : Core Image
        relit les 4,4 Mo de la table).
      - Interface : interrupteur, menu local, bouton « … » (importer, montrer dans le Finder,
        supprimer), curseur d'intensité. Le menu est un vrai `NSPopUpButton` plutôt qu'une liste
        maison : son délégué (`menu(_:willHighlight:)`) dit quel élément est survolé, à la souris
        comme aux flèches du clavier, et le canevas montre ce LUT en taille réelle avant tout
        choix (`EditorModel.previewLUT`, hors recette, hors annulation, non observé par les
        vues). Choisir est une seule étape annulable (`chooseLUT`). Bibliothèque vide : un
        bouton « Import LUTs… » à la place du menu. Importer un seul fichier l'applique à la
        photo ; en importer plusieurs les ajoute seulement au menu.
      - Écarté : des vignettes par LUT dans une liste ou un popover. Le survol du menu donne
        l'aperçu en grand, sur la vraie photo, sans rien construire de plus ; à rouvrir si la
        bibliothèque devient trop longue pour un menu (dossiers, recherche, favoris).
      - Vérifié hors écran (sonde) : mise en page de la section dans une colonne de 280 pt, nom
        long tronqué sans élargir la colonne, états vide / choisi / manquant, survol puis choix
        par le délégué. **À vérifier dans l'appli** : l'aperçu pendant que le menu est ouvert
        (le suivi du menu par le système ne se reproduit pas hors écran).
      - Reste : renommer une table, ranger par dossiers, exporter les réglages en LUT
        (inventaire Photomator), glisser-déposer un `.cube` sur la section.
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
      Débruitage, état des lieux du 19/11/2026 (l'étape 1, sans modèle, est dans la phase 2) :
      - macOS 27 apporte un décodeur RAW « version 9 » (`CIRAWDecoderVersion.version9`, API
        publique) qui dématrice et débruite par un modèle Core ML en tuiles ; à choisir par
        fichier (`supportedDecoderVersions`), ressources téléchargées à la demande
        (`downloadResources`). Sur cette machine (27.2) : 69 boîtiers listés
        (`supportedCameraModels(with:)`), chez Fujifilm seulement X-T5 et X-T50 ; un RAF de X-T4
        et un de X100V l'acceptent quand même, un RAF de X-T30 (le boîtier de Michaël) non.
        Essai sur le RAF de X-T4 : rendu nettement plus propre que la version 8 (plus de
        « vermicelles » X-Trans), premier décodage 1,4 s au lieu de 0,6 à 0,7 s, curseur de
        luminance 10 à 14 ms, pas de réglage du bruit de couleur. Piste : un choix « Enhanced »
        là où le fichier l'accepte ; `RAWDecoder` est le bon endroit.
      - Modèles tiers déjà en Core ML sous licence permissive (recherche du 19/11/2026, non
        téléchargés) : seul SCUNet (`scunet_color_real_psnr`, Apache 2.0, conversion
        communautaire `markhamilton/scunet-coreml` sur Hugging Face, 67 Mo, tuiles de 512 px,
        sans réglage de force) passe le filtre de la licence ; à reconvertir depuis les poids
        d'origine ou à valider contre PyTorch. NAFNet (MIT, entraîné sur SIDD) n'existe pas en
        Core ML pour le débruitage : à convertir soi-même. Écartés pour licence non commerciale :
        Nagi Denoise (poids CC BY-NC), MPRNet et MIRNetv2. Un tel modèle se calcule une fois, hors
        du fil principal, puis se mélange à l'original (comme les retouches), et servirait
        surtout aux JPEG/HEIC et aux boîtiers sans version 9.
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
- [ ] Historique des modifications d'une photo (demande de Michaël, 18/11/2026) : la liste des
      modifications faites, datées, avec la possibilité de revenir à une version donnée.
      Point de départ : depuis le 18/11/2026, chaque étape d'annulation de l'éditeur porte un
      nom précis (« Exposure », « Rotate Right », « Add Sky Mask »…), déduit de la différence
      entre la recette avant et après (`EditActionName`, EditorKit) ou donné par l'opération
      (« Apply Preset », « Paste Adjustments »). Aujourd'hui ce nom est une chaîne anglaise, en
      mémoire seulement (`EditorModel.undoNames`), et l'historique d'annulation se perd à la
      fermeture de la photo. À prévoir le moment venu :
      - faire de `EditActionName` une valeur structurée et `Codable` (réglage, action, calque),
        traduite en texte à l'affichage : un historique enregistré doit survivre à un
        changement de langue de l'appli ;
      - une entrée par étape : nom, date, et la recette d'après (ou un écart), pour revenir à
        n'importe quelle version ;
      - où l'enregistrer : le sidecar pour les dossiers ; pour Photos, `PHAdjustmentData` a une
        taille limitée, donc probablement le catalogue, avec la recette courante qui reste la
        vérité ;
      - les gestes regroupés tels qu'aujourd'hui (une entrée par geste, pas par mouvement de
        curseur), et peut-être fusionner les retouches successives d'un même réglage.
- [ ] Import de photos depuis une carte SD ou un appareil (demande de Michaël, 19/11/2026) :
      la carte apparaît dans la barre latérale, on voit ses vignettes, on choisit les photos, la
      destination (dossier ou album Photos) et les options, puis on importe. Rien n'est codé
      dans l'appli ; ce qui suit est le cadrage discuté ce jour-là et le résultat du prototype.
      - **Brique système** : ImageCaptureCore, présent aussi sur iPadOS. Lu dans les en-têtes du
        SDK : `ICDeviceBrowser` annonce cartes en stockage de masse et
        appareils USB ; `ICCameraFile` donne vignette (`requestThumbnailData`, taille maximale
        réglable), métadonnées et téléchargement vers un dossier (`requestDownload`, options
        `ICDownloadsDirectoryURL` et `ICDeleteAfterDownload`) ; `ICCameraDevice` supprime
        (`requestDeleteFiles`, résultat par fichier, erreurs typées), éjecte (`requestEject`)
        et dit si la carte est verrouillée (`isLocked`, aussi par fichier sur `ICCameraItem`).
      - **Faisabilité vérifiée le 19/11/2026** (`Experiments/card-import/`, sonde signée avec
        quatre jeux de droits, sur une carte de 16 Go en FAT32 : 1154 JPEG, 77 CR2, 2 RAF,
        23 MOV, environ 23 Mo/s en lecture) :
        - **Bac à sable** : seul ou avec les droits actuels de Qaama, la carte n'est même pas
          annoncée. Avec `com.apple.security.device.usb` en plus, tout passe (liste, vignettes,
          copie dans le conteneur, suppression), sans autre droit ni question bloquante.
        - **Liste** : premiers fichiers après 0,4 s, un par rappel, les 1256 après 20 à 25 s :
          à afficher au fur et à mesure. Types réduits à `public.image` et `public.movie`,
          `isRaw` juste. Les THM des vidéos ne sont pas listés. Un fichier nommé hors de la
          convention des appareils (`QAAMATST.JPG`) n'a pas été listé, renommé `QAMA0001.JPG`
          il l'a été (pas creusé).
        - **Pas de chemin** : `mountPoint` et `fileSystemPath` sont vides, bac à sable ou non,
          et le volume ne se lit pas directement depuis le bac à sable. Tout passe par
          l'appareil : pas de lecture par ImageIOKit sans télécharger.
        - **Vignettes, le point dur** : `requestThumbnailData` coûte 650 ms par photo, pareil
          à 160 px, à 400 px, ou pour 40 demandes envoyées d'un coup (servies une à une) : le
          temps de lire le fichier entier. Un écran de 40 vignettes : 25 s ; la carte : plus de
          13 minutes. En lisant seulement les 128 premiers ko (`requestReadData`) et en sortant
          la vignette EXIF avec ImageIO : 82 ms à froid, 8 ms ensuite, mais 160 × 120 px.
        - **Aperçu en grand** : la vignette se demande jusqu'à 4096 px, JPEG comme RAF
          (4096 × 2731), en 0,4 à 0,8 s la première fois, 50 à 250 ms ensuite.
        - **Copie** : un RAF de 28,6 Mo en 1,27 s, taille vérifiée. **Suppression** : 3 ms, le
          fichier quitte la carte sans passer par son dossier `.Trashes`, le délégué est prévenu.
        - **Pour comparaison**, ImageIO directement sur le volume, hors bac à sable (ce que
          donnerait la carte désignée par `fileImporter`) : 1154 JPEG listés en 0,36 s,
          vignette EXIF en 10 ms, vignette de 400 px décodée en 349 ms.
        - **Non essayé** : paires RAW + JPEG (aucune sur cette carte), vignette EXIF des RAW,
          carte ou fichier verrouillé, éjection, carte retirée pendant une copie, sort du THM
          d'une vidéo copiée ou supprimée, appareil branché en USB.
        - **Conséquences** : ajouter le droit USB à l'appli ; la grille affiche d'abord les
          vignettes EXIF (lecture partielle), puis affine les seules cellules visibles par
          `requestThumbnailData`, en file, annulable au défilement ; l'aperçu en grand est une
          grande vignette, sans téléchargement.
      - **Architecture** (revue le 19/11/2026 en lisant la grille) : la carte ne stocke rien
        (ni notes, ni recettes, ni catalogue), mais elle se présente quand même comme un
        `LibrarySource`, sans aucune capacité (`CameraLibrarySource`) : `AssetGridView` sert
        alors telle quelle, avec ses mois, sa sélection, ses flèches et son zoom. Ce qui parle
        à l'appareil est derrière un protocole (`CameraConnection`, `CameraBrowser`), pour
        tester sans carte ; ImageCaptureCore n'en est qu'une mise en œuvre
        (`ImageCaptureBrowser`). Vers un dossier, on copiera et le scan sur changement externe
        fera apparaître les photos. Vers Photos, la création d'une photo depuis un fichier et
        son rangement dans un album sont à écrire.
      - **Étape 1 faite le 19/11/2026 : voir la carte dans l'appli.**
        - Droit `com.apple.security.device.usb` ajouté ; section « Devices » en haut de la
          barre latérale tant qu'un appareil est branché (`CameraDevices`), symbole selon le
          type (carte, téléphone, appareil). L'iPhone de Michaël, branché, y apparaît aussi :
          ImageCaptureCore l'annonce comme les cartes.
        - `CameraLibraryView` : la grille, le nom et le nombre de photos en titre, un bandeau
          pendant la lecture. La carte n'est lue qu'une fois sélectionnée.
        - Liste : les fichiers annoncés un par un sont regroupés (une mise à jour de la grille
          toutes les 0,5 s), triés du plus récent au plus ancien, les paires RAW + JPEG d'un
          même dossier en une photo, les vidéos comptées et laissées de côté (décision à
          prendre). Mesuré sur la carte, vue affichée : premières photos à 0,9 s, les 1233
          à 22,5 s.
        - Vignettes en deux temps, `LibrarySource.quickThumbnail` (nouveau, nil par défaut)
          puis `thumbnail` : la vignette EXIF lue dans les 128 premiers ko, rognée à la forme
          de la photo (les appareils la livrent en 4:3 avec des bandes noires pour une photo
          en 3:2 : vu sur la première capture), puis la vignette nette. Les CR2 ont une
          vignette EXIF, les RAF non (ils attendent la nette).
        - `CameraRequestQueue` : une demande à la fois, les lectures courtes avant les
          lectures de fichier entier, et une demande dont la tâche est annulée (cellule sortie
          de l'écran) n'atteint jamais l'appareil.
        - Leçon : demander les vignettes nettes pendant que l'appareil liste ses fichiers
          ralentit la liste (1000 fichiers en 34 s au lieu de tous en 25 s) et lit pour rien,
          les rangées bougeant encore. Elles attendent donc la fin de la liste. Un écran de
          24 vignettes est net en moins de 30 s après.
        - Nouvelle capacité `LibraryCapability.editing`, que la carte n'a pas : le menu
          contextuel de la grille n'offre alors ni l'éditeur, ni copier/coller les réglages,
          ni l'export. Un double-clic ne fait encore rien.
        - **Retour de Michaël le même jour** : « ça marche pas mal », mais pendant le
          chargement une vignette passait d'une photo à une tout autre. Vérifié d'abord sur la
          carte que la vignette EXIF et la vignette nette montrent bien la même photo (73
          photos comparées en 8 × 8 niveaux de gris : écart moyen 2/255, maximum 9). Puis
          reproduit dans une sonde avec un faux appareil lent (photos anciennes rouges,
          nouvelles bleues). Trois causes, corrigées :
          1. **La grille, pour toutes les bibliothèques** : quand un mois s'insère au-dessus,
             ses rangées sont celles qu'un autre mois tenait l'instant d'avant, et le
             `LazyVGrid` garde à l'écran les anciennes cellules sans jamais installer les
             nouvelles (les rangées sont bien construites avec les nouvelles photos, mais ni
             `==` ni `body` de leurs cellules ne sont appelés ; pareil fenêtre à l'écran). La
             carte y tombait sans arrêt, ses mois arrivant au fil de la lecture. Les cellules
             sont désormais identifiées par leur rangée et leur section (`GridRowID`,
             LibraryKit) : une rangée qui change de mois est une nouvelle cellule. Mesuré
             avant et après sur 74 000 photos en 238 mois : sélection 10 à 24 ms, saut à un
             mois 73 à 93 ms, mêmes dates à l'arrivée, redimensionnement 35 à 46 ms : pas de
             différence.
          2. Une cellule gardait les pixels de la photo précédente de sa rangée jusqu'à
             l'arrivée de la nouvelle vignette : sans conséquence quand elle arrive en
             quelques millisecondes, une autre photo affichée pendant des secondes avec une
             carte. `AssetThumbnailView` les efface après 150 ms si rien n'est arrivé.
          3. L'attente de la fin de la liste, dans `thumbnail`, ignorait l'annulation : les
             demandes des cellules sorties de l'écran ou changées de photo restaient en
             attente jusqu'au bout. Elle rend la main dès l'annulation.
          Leçon : une sonde avec un faux appareil lent et des couleurs par lot dit en une
          seconde ce qu'une cellule affiche vraiment ; les captures sur la vraie carte ne le
          montraient pas.
        - **Cases grises au bon nombre (demande de Michaël, 19/11/2026)**, à la place des
          photos qui arrivent au fur et à mesure : pendant la lecture, la vue montre une
          grille de vignettes vides et une barre de progression, puis les photos prennent
          leur place d'un coup, triées (`CameraLibrarySource` ne liste plus rien avant la
          fin ; `listingProgress` dit combien en attendre). Les remplir avant la fin n'est pas
          possible : la place d'une photo dépend des dates de toutes les autres, et l'appareil
          les annonce sans ordre. Le nombre vient du pourcentage que l'appareil donne
          (`contentCatalogPercentCompleted`) : photos trouvées divisées par la part annoncée.
          Mesuré : son compte court devant les fichiers remis, donc 560, 950 puis 1129 dans la
          première seconde pour 1233 photos, 1188 à partir de la deuxième ; l'estimation
          n'est donc prise qu'à partir de 10 % et gardée tant qu'une suivante ne s'en écarte
          pas de plus de 5 %. Sur la carte : cases grises à 0,7 s, « About 1 188 photos »,
          photos en place à 21 s, toutes les vignettes rapides de l'écran 0,3 s après.
          Essayée et écartée : l'option `ICEnumerationChronologicalOrder`, qui ne livre pas
          les fichiers par date sur cette carte et ne change pas la durée (13 à 21 s avec ou
          sans, d'une fois sur l'autre). Du coup l'attente de fin de liste dans `thumbnail`
          (cause 3 ci-dessus) n'existe plus : aucune cellule ne demande rien avant la fin.
        - **Les cases grises se remplissent pendant la lecture (demande de Michaël, même
          jour)** : `CameraLibrarySource.foundPhotos` donne les photos trouvées dans l'ordre
          où l'appareil les annonce, et la grille de lecture (`CameraReadingGrid`, non
          sélectionnable) montre leur vignette EXIF sur les premières cases. Cet ordre n'est
          pas celui de la grille finale (dates mêlées, vu sur la capture à 8 s) : à la fin de
          la lecture, toutes les photos changent de place une fois, pour se ranger par date.
          Durée de lecture inchangée (21 s). Pour que chaque photo arrive directement à sa
          place, il faudrait connaître tous les fichiers d'emblée : possible seulement en
          lisant le volume directement (0,4 s pour 1154 fichiers), donc avec un accès à la
          carte accordé par l'utilisateur dans un dialogue. Non fait, à décider.
        - **Étape 2 faite le 19/11/2026 : aperçu en grand et import vers un dossier.**
          - Aperçu (`CameraPhotoViewer`) : double-clic ou barre d'espace, à la place de la
            grille comme l'éditeur ; l'image est demandée à la taille de la vue, par pas de
            1024 px, 4096 au plus (`previewPixels`), sur une voie de la file qui passe avant
            les vignettes de la grille ; les deux photos voisines sont lues d'avance. Mesuré
            sur la carte : vignette EXIF tout de suite, image nette en moins de 1,5 s, photo
            suivante déjà nette 0,15 s après la flèche. Flèches et Échap vérifiés par des
            touches envoyées à la sonde ; le retour à la grille remet sa place et sélectionne
            la photo vue (`GridPlaceKeeper`, comme l'éditeur), non vérifié à l'écran.
          - Import (`CameraLibrarySource.startImport`, `CameraImport`) : chaque fichier est
            copié par l'appareil dans un dossier temporaire de l'appli, comparé à la taille
            annoncée, puis déplacé à sa place : une carte retirée ne laisse pas de fichier
            partiel parmi les photos. Rangement par jour (`ImportLayout`). Un fichier de même
            nom et même taille déjà là est compté « déjà importé » ; même nom et autre taille :
            le nouveau prend le nom libre suivant. Annulation : le dossier de destination
            enregistre « Import Photos », qui met les fichiers à la corbeille
            (`FolderLibrarySource.registerImport`). Éjection en option, et par le menu
            contextuel de la barre latérale.
          - Choix d'interface : pas de cases à cocher, la sélection de la grille dit quoi
            importer (« Import 12 Selected… » ou « Import All… »), comme dans Photos.
          - Mesuré sur la carte : 3 photos dont un RAF, 51 Mo, en 2,6 s (le débit de la
            carte) ; un second passage les trouve déjà là.
          - Pas vérifié : le parcours dans l'appli lancée (bouton, feuille, barre, undo,
            écriture dans un vrai dossier depuis le bac à sable, éjection réelle) ; la feuille
            et la barre ne sont vues que rendues hors écran.
          - Retour de Michaël (19/11/2026) : « ça marche impeccable », « un très bon début » ;
            il faudra l'import dans Apple Photos avec choix de l'album et une case de recherche
            du nom d'album, les nouvelles photos seulement, et le reste du MVP.
          - **Destination Apple Photos, faite le même jour** : `ImportDestination.library`
            reçoit, photo par photo, les fichiers copiés et vérifiés ;
            `PhotoKitAssetChanges.create` en fait une photo (un RAW venu avec son JPEG : le
            JPEG en ressource principale, le RAW en ressource alternative, convention des
            paires dans Photos, non vérifiée sur une vraie paire), ajoutée à l'album choisi
            dans la même modification. La feuille propose « Apple Photos » au-dessus des
            dossiers, et l'album se choisit par la recherche d'« Add to Album »
            (`AlbumSearchView`, réutilisée telle quelle). Annulation : supprime les photos
            créées, ce que Photos demande à l'utilisateur, sans rétablissement possible.
            Testé avec une fausse bibliothèque ; **rien n'a été écrit dans la photothèque de
            Michaël** : la création réelle dans Photos reste à essayer dans l'appli.
          - Bouton « New… » à côté de « Choose… » (demande de Michaël, même jour) : une
            feuille demande le nom du nouvel album et le dossier d'albums où le créer
            (`NewAlbumSheet`, `PhotosAlbumFolderChoice`), création annulable par l'éditeur
            d'albums. Albums multiples à l'import : non fait, avis donné à Michaël (un seul
            album à l'import, le classement dans d'autres se fait ensuite depuis « Dernier
            import » avec « Add to Album »), à décider.
          - Reste du MVP : « nouvelles photos seulement » (photos déjà importées grisées ;
            Photos ne refuse pas les doublons par lui-même, il faudra donc garder une trace
            des imports), aperçu de l'arborescence de destination, « Dernier import »,
            suppression sur la carte.
        - **Étape 3 faite le 19/11/2026 : le reste du MVP.**
          - Nouvelles photos seulement : `ImportHistory` (fichier JSON d'Application Support,
            donnée de l'utilisateur comme les préréglages de filtres, pas le catalogue : rien
            sur le disque ne dit qu'une photo vient d'une carte) retient la signature de
            chaque fichier importé (nom, taille, date de prise de vue). Les photos déjà
            importées portent `LibraryAsset.isImported` : grisées avec une coche, bouton
            « Import N New… », sous-titre « N new ». Annuler un import les rend nouvelles
            (même étape du menu Édition que la corbeille).
          - Dernier import : entrée « Last Import » en haut de la barre latérale, vue du
            dossier ou de Photos restreinte aux photos importées
            (`LibraryCatalog.library(forLastImport:)`). Leçon : la restriction
            `onlyAssetIDs` est celle d'un groupe ouvert depuis la carte, avec son bouton
            « Back to the Map » qui la lève ; l'import a donc la sienne,
            `LibraryQuery.fixedAssetIDs`, que rien dans l'interface ne lève.
          - Demande de Michaël après essai : plusieurs entrées, avec la date et l'heure,
            conservées au relancement. Fait : section « Imports » de la barre latérale, les
            dix derniers imports (`ImportHistory.imports`), chacun sous sa date ; les fichiers
            d'un import sorti de la liste restent connus comme importés. Le premier format du
            fichier (un seul import, quelques heures le 19/11) est encore lu.
          - Retours de Michaël (19/11/2026) : section renommée « Last Imports » ; un import
            peut recevoir un nom (clic droit › « Rename… », annulable, `ImportRecord.name`),
            et retrouve sa date si le nom est vidé ; case « Hide Already Imported » dans la
            barre d'outils de l'appareil (`CameraLibrarySource.hidesImported`, retenue).
            Question posée : faut-il confirmer l'annulation d'un import ? Avis donné : non,
            vers un dossier les fichiers vont à la corbeille et le rétablissement les en
            ressort ; vers Photos, c'est Photos qui demande. À décider par Michaël.
          - Noter et marquer pendant la revue sur la carte : remis à plus tard (Michaël,
            19/11/2026).
          - Suppression sur l'appareil après import (case de la feuille, jamais retenue) :
            seules les photos arrivées à destination sont supprimées
            (`deleteImported(by:)`), une fois l'import fini.
          - Seconde copie de sauvegarde (19/11/2026) : la feuille propose un dossier, retenu
            par un signet de sécurité ; chaque fichier y est copié en plus, toujours rangé
            par jour, depuis la copie déjà lue de l'appareil (pas de seconde lecture). Une
            photo déjà à destination mais absente de la seconde copie est relue pour elle
            seule. Une seconde copie qui échoue n'arrête pas l'import : elle est signalée, et
            son fichier n'est jamais supprimé de l'appareil (`importedFileIDs` ne retient que
            ce qui est aux deux endroits). Pas vérifié : le signet et l'écriture sur un
            autre disque depuis le bac à sable, à essayer dans l'appli.
          - Retours de Michaël sur ce lot (19/11/2026) : la case à cocher dans la barre
            d'outils se lisait comme une case dans un bouton. Remplacée par un bouton à
            bascule au symbole de filtre du système (`line.3.horizontal.decrease`), allumé
            quand il filtre, avec la même commande dans le menu View (« Hide Already
            Imported ») : une barre d'outils porte des boutons, et chacune de ses commandes
            existe aussi dans la barre des menus. Et « Organize » propose cinq rangements par
            date au lieu d'un (`ImportLayout` : année/jour, année/mois/jour, année/mois,
            année, jour), l'aperçu des dossiers suivant le choix.
          - Vidéos (20/11/2026) : décision prise par défaut, à confirmer par Michaël : une
            case « Import the N videos too » de la feuille, cochée par défaut et retenue,
            quand on importe les nouvelles photos (pas avec une sélection, les vidéos n'étant
            pas dans la grille). Elles sont copiées comme les photos (rangement, seconde
            copie, historique : jamais deux fois) ; vers Photos, créées comme vidéos
            (ressource `.video`, non vérifié dans une vraie photothèque). Qaama ne les montre
            pas, et leurs fichiers THM restent sur la carte. Puis, sur demande de Michaël le
            même jour (« une vignette de la vidéo (sélectionnable ou non) et un élément visuel
            clair ») : les vidéos sont listées dans la grille de l'appareil, à leur date, sous
            une pastille « Video » (`LibraryAsset.isVideo`), sélectionnables, importables et
            supprimables comme les photos. Pas vérifié : que l'appareil fournit une vignette
            pour une vidéo (carte retirée) ; Michaël essaiera avec une vidéo sur une carte.
          - Tri de ce qui restait (20/11/2026), validé par Michaël : on fait les mots-clés à
            l'import et l'ouverture de la carte à l'insertion ; on laisse le renommage par
            modèle, les préréglages d'import, les cases par journée, auteur et copyright, et
            le préréglage d'ajustements.
          - Mots-clés à l'import : Michaël a demandé « une interface plus sympa pour les
            saisir (facilité de sélectionner les existants + en créer des nouveaux, avoir des
            petits "tags" », à reprendre ensuite dans le panneau Info. Fait avec le champ à
            jetons du système (`NSTokenField`, `KeywordTokenField`), qui propose en tapant les
            mots-clés déjà utilisés (`LibraryCatalog.knownKeywords()` : dossiers et index
            Photos). Vers un dossier, les mots-clés vont dans un sidecar écrit à côté de
            chaque photo importée (sur le RAW d'une paire, pas sur les vidéos) ; vers Photos,
            dans la demande de création. Reste : reprendre ce champ dans le panneau Info et
            la barre de l'éditeur (`KeywordsField`, encore un champ texte à virgules). Souhait
            noté pour plus tard : une hiérarchie de mots-clés.
          - Réglages : première fenêtre « Settings » de l'appli (`SettingsView`), un volet
            General avec « Show a card or a camera when it is plugged in », actif par défaut.
            La fenêtre passe alors sur l'appareil dès qu'il est annoncé, jamais pour un
            téléphone (branché pour d'autres raisons).
          - Apparence (20/11/2026) : réglage « Appearance » (System, Light, Dark) en tête du
            volet General, `AppAppearance` dans `SettingsView.swift`. Appliqué par
            `NSApp.appearance` (nil pour le système) et non `preferredColorScheme`, qui ne
            touche que les fenêtres de sa scène (ni menus, ni alertes, ni panneaux d'ouverture,
            ni la fenêtre de réglages) et ne revient pas à l'apparence du système une fois
            posé. Appliqué depuis les deux scènes (`onChange(initial:)`), pour qu'un
            changement prenne même sans fenêtre principale ouverte.
            Cartes (même jour, captures de Michaël, macOS en clair et Qaama en sombre : la barre
            d'outils claire au-dessus de la carte, sombre dès que l'inspecteur est ouvert ; « je
            pense que c'est ça le problème »). La barre est transparente : c'est la carte, restée
            claire, qui se voit dessous ; avec l'inspecteur, un fond de fenêtre sombre la
            surmonte. Mesuré par sonde : MapKit suit l'apparence du système et ignore celle dont
            il hérite (`MKMapView` d'une `Map` en `aqua` sous `NSApp.appearance` sombre, comme
            un `MKMapView` nu ; ni l'apparence de la fenêtre, ni `colorScheme`, ni
            `-AppleInterfaceStyle` n'y changent rien) ; seule une apparence posée sur la vue
            elle-même compte. Options présentées : ce contournement, une carte refaite en
            `MKMapView`, ou laisser suivre le système ; Michaël a choisi le contournement.
            `mapFollowsAppAppearance()` (`MapAppearance.swift`) pose derrière la `Map` une vue
            vide qui retrouve dans la fenêtre le `MKMapView` au cadre le plus proche du sien et
            lui donne sa propre apparence, à chaque changement. Sonde : trois cartes côte à
            côte, les deux qui l'ont suivent sombre, clair, sombre, système ; la troisième reste
            sur le système. Posé sur la carte de la bibliothèque, celle du filtre de lieu et
            celle du panneau Info. Si un macOS futur dessine `Map` autrement, la carte suit
            simplement le système de nouveau. Vérifié dans l'appli par Michaël (« ça marche »).
            Reste un écart, laissé tel quel : au-dessus de la carte, la barre n'a qu'un flou
            léger inspecteur fermé, une bande sombre coupée net inspecteur ouvert (effet de bord
            « soft » puis « hard », choisis par le système). Michaël préférerait peut-être la
            bande partout, « à voir si c'est du bricolage ou pas. Si c'est du bricolage on laisse
            comme ça ». Sonde : l'effet appartient au `MKMapView` (son `NSScrollPocket`), et
            `.scrollEdgeEffectStyle(.hard, for: .top)` ne l'atteint pas sur une `Map` (style
            inchangé), alors qu'il change bien celui d'une `List` dans la même fenêtre. Le forcer
            demanderait de toucher une vue privée ou de peindre notre propre bande : laissé au
            système.
          - Pas vérifié dans l'appli : la saisie dans le champ à jetons (complétion, Retour,
            virgule), les mots-clés réellement écrits dans Photos, la fenêtre de réglages
            ouverte par le menu, la bascule à l'insertion d'une carte.
          - Préréglages d'import (20/11/2026), repris par Michaël après les avoir d'abord
            laissés de côté (« bien utile dans pas mal de cas ») : `ImportPreset` et
            `ImportPresetStore` (fichier JSON d'Application Support), menu « Preset » en haut
            de la feuille sur le modèle de l'export (nom du préréglage reconnu ou « Custom »,
            « Save Preset… », « Delete Preset »). Un préréglage garde destination et album,
            rangement, mots-clés, vidéos, seconde copie, éjection ; pas la suppression sur
            l'appareil, redemandée à chaque import. Feuille refondue le même jour sur ses
            retours : Organize et ses dossiers dans une seule zone, chemins à chevrons, badges
            clairs avec le nombre de photos dans un cercle plein.
          - Aperçu des dossiers de destination dans la feuille (jour et nombre de photos) ;
            pas de case pour décocher une journée.
          - Suppression sur la carte : menu contextuel et Image › Delete, après confirmation,
            sans annulation (seconde exception à « tout est annulable »). Vérifié sur la
            carte avec un fichier de test posé pour l'occasion : supprimé en 30 ms, le compte
            de fichiers de la carte est revenu à sa valeur de départ.
          - Pas vérifié dans l'appli lancée : tout ce qui précède à l'écran, et « Last
            Import » pour Photos (aucune photo créée dans la photothèque de Michaël).
          - Reste : cases pour décocher une journée, noter pendant la revue sur la carte,
            suppression après import, seconde copie, application de mots-clés et de
            préréglages à l'import, renommage, préréglages d'import, vidéos.
        - Vérifié : 36 tests avec un faux appareil ou sur les identifiants de rangée ; la vraie vue rendue hors écran sur la
          carte (sonde). Pas vérifié : l'appli elle-même lancée (une instance de Michaël
          tournait sur le même conteneur), donc le droit USB dans Qaama, la section de la
          barre latérale à l'œil, le retrait de la carte.
      - **MVP de l'import** (reste, après l'étape 1) :
        - cases à cocher, import vers un
          dossier, en arrière-plan : les photos apparaissent au fur et à mesure et on peut déjà
          travailler dessus ;
        - « nouvelles photos seulement » : les photos déjà importées restent visibles, grisées
          et décochées (nom, taille, date de prise de vue ; demande de garder une trace des
          imports) ;
        - rangement par date à destination, avec l'aperçu des dossiers qui seront créés et du
          nombre de photos dans chacun, une journée entière pouvant être décochée ;
        - éjecter la carte après l'import (case à cocher) ;
        - « Dernier import » dans la barre latérale.
      - **Sur la carte, avant l'import** :
        - clic droit « Delete » : suppression directe sur la carte, grisée avec une explication
          si la carte ou le fichier est verrouillé ;
        - double-clic : aperçu en grand, une grande vignette demandée à la taille de l'écran
          (mesuré : jusqu'à 4096 px). Le zoom à 100 %, qui demande de télécharger le fichier,
          n'est pas nécessaire (Michaël, 19/11/2026 : « le but est de voir l'image un peu plus
          grande que la vignette ») : seulement si c'est simple. Une visionneuse (zoom, flèches,
          supprimer, cocher), pas l'éditeur : une photo ne se modifie qu'une fois importée ;
        - noter et marquer pendant la revue : gardé en mémoire puis écrit dans le sidecar à
          l'import, les rejetées n'étant pas importées.
      - **Ensuite** :
        - destination Photos et album ;
        - suppression sur la carte après import, seulement une fois la copie vérifiée ;
        - seconde copie de sauvegarde vers un autre disque pendant l'import ;
        - appliquer à l'import : mots-clés, auteur et copyright, préréglage d'ajustements (une
          recette écrite dans le sidecar ; dépend des préréglages) ;
        - renommage par modèle (date, nom de la séance, numéro de séquence) ;
        - préréglages d'import (destination, rangement, renommage, options sous un nom) ;
        - ouvrir l'import à l'insertion d'une carte, en option dans les réglages.
      - **Écarté** (accord de Michaël) : conversion en DNG, aperçus 1:1 et « smart previews »
        (`PreviewCache` suffit), mode « déplacer » (copier puis supprimer après vérification
        est plus sûr), prise de vue connectée, dossier surveillé (les dossiers se rescannent
        déjà à chaque changement).
      - **Points qui demandent du soin** :
        - annulation : annuler un import vers un dossier met les copies à la corbeille ; toute
          suppression sur la carte est définitive (pas de corbeille), donc confirmation et pas
          d'annulation, seconde exception à « tout est annulable » après Photos ;
        - paires RAW + JPEG importées et supprimées comme une seule photo ;
        - fichiers annexes écrits par l'appareil (XMP, son, vignette vidéo) : les emporter à la
          suppression ou les laisser, à décider ;
        - carte retirée en plein import : pas de fichier à moitié copié ;
        - vidéos présentes sur la carte : les ignorer ou les copier, à décider ;
        - fichiers nommés hors de la convention des appareils, que l'appareil ne liste pas :
          accepté tel quel (Michaël, 19/11/2026).
      - Idées reprises de Lightroom Classic (de mémoire, sans l'avoir rouvert) : nouvelles
        photos seulement, aperçu de l'arborescence de destination, seconde copie, application
        à l'import, renommage, préréglages d'import. Noter pendant la revue et supprimer sur
        la carte vont au-delà de ce que proposent Lightroom et Photos.
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
