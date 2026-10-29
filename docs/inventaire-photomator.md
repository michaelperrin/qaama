# Inventaire fonctionnel de Photomator 3.4.15 (étude REA, 29 octobre 2026)

Objet : cahier des charges de référence pour Qaama. Tout ce qui suit est **observé** sur
le bundle installé, sauf mention « inféré ». Rien n'est copié : il s'agit de la liste des
comportements et des fonctions, pas de leur implémentation.

## 1. Méthode et sources

| Source | Ce qu'elle apporte | Fiabilité |
|---|---|---|
| `Info.plist`, entitlements, `otool -L`, `nm -u` | architecture, frameworks Apple, API PhotoKit | observé |
| Clés des `.strings` (`fr.lproj`, les clés sont le texte anglais source) | inventaire exhaustif des libellés : menus, réglages, infobulles, nouveautés, onboarding | observé |
| `Adjustments.library` / `Crop.library` (préréglages livrés) | structure du format de recette, familles de préréglages, ratios de recadrage | observé (structure) / inféré (sens des clés) |
| Noms de fichiers Swift dans `PTPhotoKit` | découpage du modèle de bibliothèque | observé |
| Décompilation | **exclue** par décision du 29/10/2026 (cadre légal, voir §8) | — |

Attention : le framework `PXMPro` est partagé avec Pixelmator Pro. Les chaînes qui
concernent calques, texte, formes, vidéo, pinceaux ou effets ont été écartées : elles ne
font pas partie de Photomator.

## 2. Bibliothèque

### 2.1 Sources

- **Photothèque Apple** : Toutes les photos, Récents, Favoris, Albums, Albums partagés,
  Dossiers d'albums, album Masqué (option « Show Hidden album »), Imports, « From My
  Mac » (Événements, Visages). Détection d'une photothèque introuvable, à la corbeille,
  verrouillée (Touch ID), téléchargement iCloud en cours, absence de réseau.
- **Fichiers** (depuis la 3.3) : dossiers choisis par l'utilisateur, dossier Images
  proposé par défaut, disques externes et services cloud, sous‑dossiers (option
  « Display items from nested folders »), dossiers en lecture seule, disque déconnecté,
  dossier verrouillé. Un dossier virtuel **Linked Files** regroupe les fichiers ouverts un
  par un (`PTLinkedPhotoFile`).
- **Appariement RAW + JPEG** : paire détectée, réglage « Open RAW by Default » /
  « Open JPEG by Default », commandes « Open RAW » / « Open Original ».
- Option « Create Photomator album in Photos » : chaque photo éditée est ajoutée à un
  album dédié dans Photos.

### 2.2 Tri (culling) et organisation

- **Notation** 1 à 5 étoiles, **drapeau** (Flag / Unflagged), **rejet** (Reject),
  **favori** (synchronisé avec Photos), état **Edited**.
- Vues intelligentes : photos éditées, marquées, notées, rejetées (« Any photos you've
  flagged in Photomator will appear here »).
- Filtres combinables (« %d Filters ») : Date, Nom, Types de média, RAW, Édité, Note,
  Drapeau, Favori, Lieu. Recherche textuelle (« Fetching data about your photo library to
  enable searching » : un index est construit).
- Tri : par nom, plus récent / plus ancien d'abord, ordre de l'album, date de création /
  modification.
- Albums : créer, renommer, dupliquer, supprimer (avec ou sans les photos), nouvel album
  depuis la sélection, retirer des photos. Dossiers d'albums.
- Affichage : grille carrée ou en ratio réel, description de collection.
- Inféré : la note / le drapeau sont persistés par Photomator lui-même (message « %d
  photos were successfully checked… flagged… rejected… star ratings »), probablement
  dans le sidecar ou les données d'ajustement. À confirmer par décompilation.

### 2.3 Métadonnées et sidecars

- Inspecteur : EXIF, objectif (« Loading lens info… », « No Lens Info »), ISO, lieu
  (MapKit), mots‑clés (« Add a Keyword », « Keywords Change »), version.
- **Sidecar** : réglage « Preserve nondestructive edits » (sidecar lié à l'original),
  emplacement configurable (« Save Sidecar Files In »), usage disque, gestion (supprimer
  tout, supprimer les plus de 30 jours, révéler le fichier / le dossier), détection de
  désynchronisation original ↔ sidecar, sidecar nécessitant une version plus récente.
  Pour les ressources Photos, le sidecar passe par `PHAdjustmentData` (observé dans les
  symboles).
- Réglage « Modify originals » : écrit directement dans le fichier (formats inscriptibles
  seulement, pas le RAW). Réglage « Image Quality » pour l'enregistrement automatique.
- « Revert to Original », « Reprocess RAW », historique de versions limité pour les
  images à sidecar.

### 2.4 Modèle interne observé (`PTPhotoKit`)

`PTBrowserDataController` (+Photos, +Files, +Scan, +Caching, +Filter) orchestre deux
sources de données : `PTPhotosBrowserData` (+Fetch, +Sidecar, +URLPairing) et
`PTFilesBrowserData` (+Update) adossée à `PTFilesLibrary` (persistée en Codable).
Chargement d'images via `PTCachingImageManager` (+CustomRaw) au‑dessus de
`PHCachingImageManager`. Observation des changements Photos via
`PHFetchResultChangeDetails`. Gestion des albums via `PHAssetCollectionChangeRequest`
et `PHCollectionListChangeRequest`.

## 3. Édition

### 3.1 Ajustements de couleur (« over 30 nondestructive color adjustments »)

Chaque ajustement a un bouton **Auto** quand c'est pertinent, et l'ensemble s'active ou
se réinitialise individuellement.

| Ajustement | Paramètres observés (infobulles) | Auto |
|---|---|---|
| White Balance | Temperature, Tint, pipette de gris neutre | oui |
| Lightness | Exposure, Highlights, Shadows, Brightness, Contrast, Black Point | oui |
| Hue & Saturation | Hue, Saturation, Vibrance | oui |
| Color Balance | pour Shadows / Midtones / Highlights : Red‑Cyan, Magenta‑Green, Yellow‑Blue, Brightness, Saturation | oui |
| Selective Color | par gamme de couleur : Hue, Saturation, Brightness, Luminance Range (étendue tonale) | — |
| Levels | noirs / blancs / tons moyens, par canal RGB, pipettes noir / gris / blanc | oui |
| Curves | RGB, Rouge, Vert, Bleu, Luminance ; pipettes noir / gris / blanc | oui |
| Replace Color | couleur source, tolérance (« how much of the colors similar… »), couleur cible, mélange | — |
| Channel Mixer | matrice 3 × 3 de contribution par canal + constante par canal | — |
| Black & White | contribution des canaux R, V, B ; contraste des hautes lumières ; teinte | — |
| Sharpen | Intensity, Radius (« how much of the area around an edge ») | — |
| Texture / Clarity | « structure and contrast of fine details », version limitée à une gamme tonale | — |
| Grain | Amount, Size | — |
| Fade | intensité dans les hautes lumières et dans les ombres | — |
| Vignette | Exposure‑based, Black Point‑based, Softness | — |
| Invert | — | — |
| Color Fill | couleur + mode de fusion (hérité de Pixelmator Pro, à confirmer dans Photomator) | — |
| Match Colors | transfert de palette depuis une image de référence | — |
| Denoise | Luminance Noise Reduction, réduction du bruit couleur, comparaison en vue partagée, « Use Texture‑Aware Algorithm » | ML |
| Deband / Smart Deband | suppression du banding et de la postérisation | ML |
| Super Resolution | agrandissement × 3, comparaison en vue partagée | ML |
| ML Enhance | auto‑amélioration globale (balance des blancs, lumière, teinte/saturation, gammes de couleurs) | ML |
| Lens Correction | correction optique (infos objectif) | — |

Outils transverses : **histogramme** (RGB, luminance, épinglable, affichage automatique),
**comparaison** avant/après et **Split Comparison**, copier / coller les ajustements,
Reset / Reset All, « Flatten Adjustments », **export des ajustements en LUT**
(avertissement : les ajustements « texture‑aware » ne sont pas reproductibles en LUT),
« Customize Adjustments » (choisir les ajustements affichés), « Enable New Preset
Creation ».

### 3.2 Préréglages

Bibliothèque `Adjustments.library` : 53 préréglages livrés dans 10 collections (Custom,
Black & White, Cinematic, Classic Films, Landscape, Modern Films, Night, Urban, Vintage,
plus une). Chaque collection a un nom, une description et une couleur d'en‑tête. Les
préréglages utilisateur se créent, se renomment, s'épinglent au menu et se partagent.

### 3.3 Recadrage et géométrie

- Ratios livrés (`Crop.library`) : Freeform, Original, Square, 2:3, 3:2, 3:4, 4:3, 3:5,
  5:7, 4:5, 16:9, 9:16, tailles fixes (1024 × 768, 1920 × 1080), ratio et taille
  personnalisés.
- Guides : Rule of Thirds, Golden Ratio, Golden Spiral, Diagonal, Triangle, Grid,
  Aspect Ratio Grid.
- Redressement (± 1° au clic, « Auto Straighten » par ML HorizonDetection),
  Perspective (« Perspective Transform »), rotations 90° / 180°, flips,
  **ML Crop** (AutoCrop), « Fill Edges » (remplissage des bords après redressement,
  inféré lié au modèle d'inpainting).

### 3.4 Retouche

- **Repair** : peindre sur une zone pour la supprimer, option « take into account every
  object in your image » (ObjectDetection), « Repairing Background », reset, comparaison
  avant retouche. Mask Subject (masque de sujet ML), Smart Refine, Smart Erase.
- **Clone** : outil de clonage avec réglages.
- Sky : détection de ciel (modèle `SkyDetection`), usage exact à confirmer.

### 3.5 HDR

Prise en charge complète : affichage EDR (« Extended Dynamic Range Mode »), « Load HDR
Content » / « Load SDR Content » (ProRAW inclus), export HDR en HEIC, AVIF, JPEG (gain
map), PNG. Message si macOS ne supporte pas le HDR.

## 4. Traitement par lot et export

- **Batch workflows** : Adjust Colors (préréglage), Auto Enhance, Crop, ML Crop, Rotate,
  Straighten, Scale, Increase Resolution, Reduce Noise, Smart Deband, Match Colors,
  Export (format, qualité, profondeur), options Preserve Edits et Overwrite, workflows
  personnalisés épinglables dans le menu.
- **Export** (refondu en 3.3) : aperçu en direct, Quick Look intégré, filigranes texte
  ou image, Format / Quality / Scale / Depth (8 ou 16 bits), export RAW, export
  d'album ou de dossier complet, « Convert to sRGB », « Keep Transparency ».
- Formats de sortie observés : JPEG, HEIC, PNG, TIFF, AVIF, WebP, JPEG‑2000, OpenEXR,
  PDF, PSD, GIF/BMP (hérités), variantes HDR.
- Formats d'entrée (Info.plist) : JPEG, JPEG 2000, JPEG XL, PNG, TIFF, RAW
  (`public.camera-raw-image`), GoPro GPR, HEIC/HEIF, AVIF, Radiance, OpenEXR, dossiers,
  sidecar XMP (`com.seriflabs.xmp`).

## 5. Format de recette observé (préréglages)

Chaque préréglage contient une propriété `ColorAdjustmentData` : un JSON de la forme
`[version, { clé: [version, { paramètres }] , … }]`. Clés présentes dans les 53
préréglages, avec l'interprétation **inférée** à partir des sous‑clés :

| Clé | Sous‑clés | Interprétation inférée |
|---|---|---|
| `w` | `T`, `t`, `A`, `E`, `V` | White Balance : Temperature, Tint, Auto, Enabled, Version |
| `l` | `e`, `h`, `s`, `b`, `c`, `B`, `A`, `T`, `E`, `V` | Lightness : exposure, highlights, shadows, brightness, contrast, black point, auto, (T ?) |
| `hS` | `h`, `s`, `v`, `A`, `E`, `V` | Hue & Saturation : hue, saturation, vibrance, auto |
| `cL` | `a`, `E`, `V` | Color balance ou Clarity (une seule valeur `a` = amount) |
| `ca` | `a`, `A`, `E`, `V` | ajustement à un paramètre avec auto (inconnu) |
| `C` | `rgb`, `r`, `g`, `b`, `l`, `E`, `V` | Curves : courbes RGB, R, G, B, luminance |
| `L` | `rgb`, `r`, `g`, `b`, `l`, `E`, `V` | Levels, même découpage |
| `B` | `A`, `M`, `h`, `s`, `E`, `V` | Black & White (A ?, M = mix ?, h, s) |
| `S` | `i`, `r`, `E`, `V` | Sharpen : intensity, radius |
| `g` | `i`, `s`, `E`, `V` | Grain : intensity, size |
| `f` | `c`, `f`, `E`, `V` | Fade (deux intensités) |
| `v` | `e`, `b`, `s`, `E`, `V` | Vignette : exposure, black point, softness |
| `M` | `c`, `i`, `E`, `V` | Channel Mixer ou Match Colors |
| `b`, `i`, `m`, `r`, `s` | `t`/`i`/`b`, `i`, `b`, `r`, `i` | ajustements mono‑paramètre non identifiés |
| `ctx.cs` | — | espace colorimétrique de travail |
| `cl`, `csr`, `e`, `u`, `in` | scalaires | métadonnées de recette (version, unité…) |

Leçons pour Qaama, indépendantes du détail : une recette est une **collection ordonnée
d'ajustements**, chacun **versionné** et **activable** (`E`), avec un drapeau **Auto**
distinct de la valeur, et un **espace colorimétrique** de travail porté par la recette.
Qaama fera la même chose en JSON `Codable`, avec des noms de clés lisibles.

## 6. Correspondance avec les API Apple pour Qaama

| Fonction Photomator | Brique Apple candidate | Écart attendu |
|---|---|---|
| White Balance | `CITemperatureAndTint` ; `CIRAWFilter.neutralTemperature/.neutralTint` sur RAW | aucun |
| Lightness | `CIExposureAdjust`, `CIHighlightShadowAdjust`, `CIColorControls` (contraste, luminosité), courbe pour le point noir ; `CIRAWFilter` (exposure, boost, shadowBias, localToneMapAmount) | aucun |
| Hue & Saturation | `CIHueAdjust`, `CIColorControls`, `CIVibrance` | aucun |
| Color Balance | `CIKernel` Metal maison (3 gammes tonales) | à écrire |
| Selective Color | `CIKernel` Metal maison (masque HSL par gamme) | à écrire |
| Levels / Curves | `CIToneCurve` (5 points), `CIColorCurves` (table) ou kernel maison pour n points | kernel pour la fidélité |
| Channel Mixer | `CIColorMatrix` | aucun |
| Black & White | `CIColorMatrix` pondérée + `CIToneCurve` | aucun |
| Sharpen / Texture | `CIUnsharpMask`, `CISharpenLuminance`, `CIHighPass` combinés | proche |
| Grain | `CIRandomGenerator` + fusion, ou kernel | proche |
| Fade / Vignette / Invert | `CIToneCurve`, `CIVignetteEffect`, `CIColorInvert` | aucun |
| Replace Color | kernel maison | à écrire |
| Match Colors | histogramme (`CIAreaHistogram`) + mapping, kernel | version simple d'abord |
| Denoise | `CINoiseReduction`, `CIRAWFilter` (luminanceNoiseReduction, colorNoiseReduction) | qualité inférieure au ML |
| Super Resolution | modèle open source converti en Core ML (phase 3) | à évaluer |
| ML Enhance / Auto | `CIImage.autoAdjustmentFilters()` + heuristiques | proche |
| Auto Straighten | Vision `VNDetectHorizonRequest` | aucun |
| ML Crop | Vision saillance (`VNGenerateAttentionBasedSaliencyImageRequest`) | approximatif |
| Repair | Vision `VNGenerateForegroundInstanceMaskRequest` pour le masque ; inpainting : pas d'API publique, approche simple (clonage, patch) en phase 3 | fort écart |
| Mask Subject | Vision `VNGenerateForegroundInstanceMaskRequest`, `VNGeneratePersonSegmentationRequest` | aucun |
| Sky | aucune API publique de ciel ; segmentation sémantique via modèle open source | phase 3 |
| Lens Correction | `CIRAWFilter.isLensCorrectionEnabled` sur RAW | RAW seulement |
| HDR / EDR | `CIImage` HDR, `MTKView` EDR, gain map via ImageIO | natif |
| LUT export | `CIColorCube` échantillonné | aucun |
| Histogramme | `CIAreaHistogram` + rendu SwiftUI | aucun |
| Bibliothèque Photos | PhotoKit complet (`PHCachingImageManager`, `PHAdjustmentData`, albums) | aucun |
| Bibliothèque fichiers | security‑scoped bookmarks, `FileManager` énumérateur, `QuickLookThumbnailing`, surveillance FSEvents | aucun |
| Sidecar | fichier JSON à côté de l'original, XMP optionnel pour l'interopérabilité (note, drapeau, mots‑clés) | aucun |
| Export | ImageIO `CGImageDestination` (JPEG, HEIC, PNG, TIFF, AVIF, JXL, EXR) | WebP et PSD absents d'ImageIO en écriture |

## 7. Ce qui reste à étudier (observation et boîte noire)

1. Ordre réel du pipeline d'ajustements et espace de travail (linéaire ? ProPhoto ?).
2. Contenu exact d'un sidecar et du `PHAdjustmentData` (identifiant de format, version).
3. Où sont stockés note, drapeau, rejet et mots‑clés pour une photo Photos vs un fichier.
4. Règles d'appariement RAW + JPEG et de reconnaissance des sidecars XMP tiers.
5. Stratégie de scan de dossiers (incrémental ? surveillance ?) et de cache de vignettes.
6. Rôle du service XPC `ExtendedRAWSupport` (formats hors Apple RAW ? isolement ?).
7. Flux UI : observation de l'application en marche (`observe_native_ui`) pour documenter
   l'ergonomie écran par écran avant de dessiner celle de Qaama.

Méthode retenue pour chaque point : utiliser Photomator sur ses propres photos, puis
regarder ce qu'il produit (fichiers, sidecars, changements dans Photos), et observer son
interface en marche. Pour le pipeline (point 1), comparer nos rendus aux siens sur les
mêmes réglages et ajuster.

## 8. Pas de décompilation : cadre légal

REA n'avait aucun moteur de décompilation configuré, et la question s'est posée d'en
installer un (Ghidra). Réponse négative, décidée le 29 octobre 2026 : l'article
L122-6-1 du Code de la propriété intellectuelle autorise à observer, étudier et tester
un logiciel qu'on utilise, mais ne permet la décompilation que pour l'interopérabilité,
et interdit d'utiliser les informations obtenues pour développer un logiciel
« fondamentalement similaire ». La licence Mac App Store d'Apple interdit la
rétro‑ingénierie hors de ce que la loi permet. L'étude de Qaama reste donc en boîte
noire : exécution, ressources en clair, fichiers produits sur nos photos, documentation
Apple. Recréer des fonctionnalités reste licite : le droit d'auteur protège
l'expression, pas les idées ni les fonctions (CJUE, SAS Institute, C‑406/10).
