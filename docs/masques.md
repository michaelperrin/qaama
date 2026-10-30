# Conception des masques

Rédigé le 30/10/2026, à valider avant de coder. S'appuie sur la recette en calques (v2) et sur
l'étude de faisabilité du masque ciel (`PLAN.md`, `Experiments/sky-mask/`).

## 1. Ce qu'on veut

Appliquer un jeu d'ajustements à une partie de l'image seulement, de façon non destructive,
rééditable, annulable, avec le même rendu à l'écran, en vignette et à l'export. Les masques
sont décrits dans la recette (pas de pixels sauvegardés, hors cache), et recalculés depuis
l'original.

## 2. Modèle (paquet `EditModel`)

Un calque (`AdjustmentLayer`) porte déjà `mask: MaskSpec?`. `MaskSpec` devient `Mask` :

```
Mask
  name: String?                    nom affiché, sinon le type du premier composant
  components: [MaskComponent]      combinés dans l'ordre, chacun avec son opération
  isInverted: Bool
  feather: Double                  0…1, adoucissement des bords (flou proportionnel à l'image)
  density: Double                  0…1, opacité maximale du masque (1 par défaut)

MaskComponent
  id: UUID
  operation: add | subtract | intersect
  kind:
    subject(instances: [Int]?)     détourage du ou des sujets (Vision) ; nil = tous
    background                     inverse du sujet
    people                         segmentation des personnes (Vision)
    sky                            DETR + affinage Vision (voir §5)
    luminosity(low, high, softness)  plage de luminance en 0…1
    color(hue, hueRange, saturationMin, softness)  plage de couleur
    linearGradient(start, end)     points en coordonnées unitaires du cadre de référence
    radialGradient(center, radiusX, radiusY, angle, softness)
    brush(strokes: [Stroke])       Stroke = points unitaires, rayon, dureté, flux, effacement
```

Règles :

- **Cadre de référence** : l'image redressée, non recadrée (la « zone sûre » du redressement),
  en coordonnées unitaires, origine en haut à gauche comme le cadre de recadrage. Ainsi,
  modifier le recadrage ne déplace pas les masques ; modifier l'angle les suit (le cadre de
  référence suit l'image). C'est le choix de Lightroom.
- Le premier calque reste global, sans masque. Les calques suivants ont un masque ou rien (un
  calque sans masque = ajustements globaux supplémentaires, autorisé mais sans intérêt).
- Un masque identité n'existe pas : un calque sans composant n'applique rien.
- `isIdentity` d'une recette ignore les calques désactivés ; un calque masqué avec des
  ajustements neutres ne compte pas.

## 3. Rendu (paquet `RenderEngine`)

Ordre d'un rendu :

1. Géométrie, en deux temps désormais : redressement et quarts de tour d'abord (image de
   référence), recadrage à la fin.
2. Calque global : ajustements sur toute l'image.
3. Pour chaque calque masqué activé : `masque = MaskRenderer.render(mask, reference)`
   (image en niveaux de gris, étendue de l'image de référence), `ajusté = apply(adjustments,
   image)`, puis `image = CIBlendWithMask(ajusté, fond: image, masque)`.
4. Recadrage.

`MaskRenderer` combine les composants : `add` = max, `subtract` = multiplication par l'inverse,
`intersect` = multiplication ; puis adoucissement (`CIGaussianBlur` à rayon proportionnel au
grand côté), inversion, densité.

- Dégradés : `CILinearGradient`, `CIRadialGradient` ou un petit `CIColorKernel` pour l'ellipse
  orientée.
- Luminance et couleur : `CIColorKernel` Metal sur l'image de référence (après le calque
  global ? non : sur l'image de référence brute, pour que les curseurs globaux ne fassent pas
  bouger le masque). Écrit en Metal Shading Language, compilé en `.ci.metallib` par le
  paquet (un target Metal dans `RenderEngine` avec `-fcikernel`) ; si l'outillage SwiftPM
  bloque, repli sur un cube 3D ou un LUT 1D comme pour le mélangeur.
- Pinceau : les traits sont tracés dans un `CGContext` 8 bits à la résolution de référence,
  mis en cache par calque et invalidé au trait suivant.
- Masques ML (sujet, personnes, ciel) : calculés une fois par photo et par type sur
  l'original redressé réduit à 1024 px de grand côté, hors du thread principal, puis mis en
  cache sur disque (PNG 8 bits dans `Caches/masks/<identifiant>/<type>-<version>.png`) et en
  mémoire. Le rendu les agrandit à la taille de référence. Changer l'angle recalcule (rare).

**Performance** : pendant un glissement de curseur d'un calque masqué, seul `apply` et le
blend sont recalculés ; le masque vient du cache. Les masques ML prennent 0,1 à 0,5 s la
première fois : état « calcul… » affiché sur le calque.

## 4. Vision (sujet, arrière-plan, personnes)

- `GenerateForegroundInstanceMaskRequest` → `InstanceMaskObservation` :
  `generateScaledMask(for:scaledToImageFrom:)` pour toutes les instances ou une sélection ;
  `instanceAtPoint` permet « cliquer sur le sujet » quand il y en a plusieurs.
- Arrière-plan = 1 − sujet.
- `GeneratePersonSegmentationRequest` (qualité `accurate`) pour les personnes.
- Tout tourne sur le Neural Engine via le nouveau `ImageRequestHandler` asynchrone.

## 5. Ciel

Pipeline validé par le prototype : DETR (Apache 2.0, 85 Mo) détecte le ciel en 448², son
masque sert d'amorce (`seedScribbleBuffer`) à `GenerateIterativeSegmentationRequest` qui
affine les bords. Deux questions ouvertes pour Michaël :

1. **Embarquer le modèle (85 Mo dans l'app) ou le télécharger au premier usage** (depuis
   Hugging Face, somme de contrôle vérifiée, stocké dans Application Support) ? Le
   téléchargement demande l'autorisation réseau sortante dans le sandbox. Proposition :
   télécharger, avec un bouton explicite « Télécharger le modèle ciel (85 Mo) » la première
   fois ; l'app reste légère et le modèle se met à jour sans nouvelle version.
2. Le même DETR donne aussi mer, herbe, route, bâtiment, neige, montagne : proposer plus tard
   un masque « Scène » avec choix de la classe.

Constat du 30/10/2026 : `GenerateIterativeSegmentationRequest` échoue (statut 14) dès qu'on lui
ajoute des points inclus ou exclus en plus du point de départ ; avec le seul point de départ,
choisi bien à l'intérieur du masque DETR, le contour est propre (identique au prototype). Le
masque grossier agrandi et flouté reste le secours.

## 6. Interface

Section **Masks** de l'inspecteur, au-dessus des réglages :

- Liste des calques masqués : nom (type du premier composant), interrupteur, vignette du
  masque, sélection. Bouton « + » : Subject, Background, People, Sky, Luminance Range, Color
  Range, Linear Gradient, Radial Gradient, Brush.
- Calque sélectionné : ses composants avec leur opération (add / subtract / intersect) et un
  « + » pour en ajouter ; curseurs Feather, Density ; interrupteur Invert ; suppression.
- Menu « … » de chaque calque (modèle d'interaction observé dans Photomator, demandé par
  Michaël le 30/10/2026) : **Add ▸** et **Subtract ▸** avec la liste des types de composants
  (Select Subject, Select Sky, Select Background, Brush, Linear Gradient, Radial Gradient,
  Color Range, Luminance Range), puis Rename, Duplicate, Duplicate and Invert, Invert Mask,
  Delete. Le calque a donc un `name` modifiable (par défaut le type du premier composant).
- **Les curseurs de réglages de l'inspecteur agissent sur le calque sélectionné** (global si
  aucun masque sélectionné), avec un bandeau indiquant « Editing: Sky » pour éviter les
  erreurs. C'est le modèle de Lightroom et de Photomator.
- Sur le canevas : superposition rouge translucide du masque sélectionné (bouton « Show
  Mask », touche O), poignées des dégradés, tracé du pinceau au glissement avec taille au
  défilement, molette ou `[` `]`.
- Tout passe par `EditorModel` et l'historique : ajouter, modifier, supprimer un masque ou un
  trait = une étape annulable.

### Décisions (Michaël, 30/10/2026)

- Modèle DETR **embarqué** dans l'app (85 Mo acceptés).
- Masque « Scène » (herbe, route, mer, bâtiment, neige, montagne…) proposé **rapidement**, dans
  la même passe que le ciel : type `scene(classes:)` dans le modèle dès l'étape 1.

### Édition sur le canevas (demande de Michaël, 30/10/2026)

Les curseurs de paramètres des dégradés sont un pis-aller de l'étape 1. L'édition doit se faire
sur l'image : poignées des dégradés (point de départ et d'arrivée, centre, rayons, rotation),
pipette de luminance et de couleur (cliquer une zone règle la plage), pinceau au glissement,
le tout avec le masque visible en superposition pendant l'édition. Prévu dans l'étape 4 avec le
pinceau, qui partage la même infrastructure (overlay interactif sur `EditorCanvas`).

## 7. Étapes

1. Modèle `Mask` et composants géométriques (dégradés), luminance, couleur ; `MaskRenderer` ;
   fusion par masque dans le pipeline ; géométrie en deux temps ; tests de rendu sur des
   images synthétiques. Inspecteur : liste des calques, ajout, sélection, curseurs par calque,
   superposition sur le canevas.
2. Sujet, arrière-plan, personnes via Vision, cache disque, état de calcul.
3. Ciel : téléchargement du modèle, DETR, affinage Vision, cache.
4. Pinceau : traits sur le canevas, tracé en bitmap, cache.
5. Vignettes et export vérifiés (le cache d'aperçus se reconstruit déjà via le rendu complet).

## 8. Tests prévus

- Modèle : sérialisation, identité, inversion, coordonnées unitaires.
- Rendu : un dégradé linéaire éclaircit un bord et pas l'autre ; un masque de luminance
  n'agit que sur les tons visés ; subtract et intersect ; adoucissement ; le recadrage après
  masque ne déplace pas le masque (comparaison de pixels).
- Vision : non testable hermétiquement (modèles système) → journal et vérification manuelle.
