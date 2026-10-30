# Conception de l'export

Rédigé le 30/10/2026 à partir des demandes de Michaël et de l'observation de Photomator (boîte
noire). L'export rend la recette à pleine résolution, redimensionne, encode et écrit un fichier ;
rien n'est modifié dans la bibliothèque.

## 1. Ce qu'on veut

- **Photo seule** depuis l'éditeur (recette en cours, même non enregistrée), puis **lot** depuis
  la sélection de la grille (recette enregistrée de chaque photo).
- **Format** : JPEG (curseur de qualité), PNG, HEIC et AVIF (qualité aussi). WebP n'est pas
  écrit par ImageIO sur macOS : à ajouter plus tard avec libwebp (licence BSD) si le besoin se
  confirme.
- **Dimensions** : 100 % par défaut, sinon en pixels la largeur, la hauteur, ou le grand côté
  (l'image tient dans un carré de ce côté). L'agrandissement est permis mais signalé.
- **Métadonnées** : EXIF, TIFF, GPS et IPTC de l'original sont recopiés quand la source est un
  fichier, l'orientation remise à 1 puisque les pixels sont rendus orientés. En version finale,
  un choix « conserver les métadonnées » ou non (au minimum tout ou rien ; éventuellement
  retirer seulement la position GPS), mémorisé dans les préréglages d'export.
- **Aperçu** à gauche de la fenêtre : rendu réduit de la première photo, avec le même pipeline
  que le fichier final (bordure et filigrane compris plus tard), et les dimensions de sortie.
- **Nommage** (lot) : noms d'origine conservés, seule l'extension change ; plus tard, nommage
  séquentiel avec préfixe et numéro, et autres schémas. Le schéma de nommage fera partie des
  préréglages d'export.
- Plus tard : **bordure** de couleur unie (épaisseur en %, rayon, couleur ; les autres styles
  de Photomator sont jugés gadget), **filigrane** texte ou image (position, taille, opacité,
  ombre, mosaïque), **préréglages d'export** (format + bordure + filigrane) choisis en haut de
  la fenêtre avec « Enregistrer le préréglage », nommage compris.

## 2. Architecture

```
RenderEngine
  ExportSettings     format, qualité, taille ; calcul des dimensions de sortie ; Codable
  ExportInput        image décodée + recette + masques résolus + URL pour les métadonnées
  ExportRenderer     rend la recette, redimensionne (Lanczos), encode via CGImageDestination
EditorKit
  ExportModel        @Observable : éléments à exporter, réglages (mémorisés dans UserDefaults),
                     aperçu, encodage, écriture par lot avec progression et erreurs par photo
Qaama/Export
  ExportView         feuille : aperçu à gauche, formulaire à droite, Annuler / Exporter
  ExportDocument     FileDocument générique (données + type) pour `.fileExporter`
```

- L'éditeur construit un `ExportItem` à partir de son image déjà décodée et de sa recette
  courante ; la grille en construit un par photo sélectionnée, chargé à la demande par
  `editingInput`.
- Photo seule : panneau d'enregistrement système. Lot : choix d'un dossier, fichiers nommés
  d'après l'original, suffixe numérique en cas de collision, progression et annulation.
- Les réglages d'export ne font pas partie de la recette : ils décrivent le fichier, pas l'édition.

## 3. Étapes

1. Photo seule : réglages, aperçu, encodage multi-format, métadonnées. Tests : dimensions de
   sortie, relecture des fichiers encodés (type, taille), orientation remise à 1.
2. Lot depuis la grille : dossier, noms d'origine, progression, menu contextuel et menu Fichier.
3. Bordure de couleur unie.
4. Filigrane texte et image.
5. Choix de conserver ou non les métadonnées, schémas de nommage (séquentiel avec préfixe…),
   puis préréglages d'export.
