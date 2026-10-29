# Conception du catalogue (fondations de données du MVP)

Rédigé le 29/10/2026. Répond aux points 1, 2, 4 et 5 de la dette d'architecture du bilan POC
(`PLAN.md`). À valider avant d'écrire du code.

## 1. Problème

- L'identifiant d'une photo de dossier est son chemin : un renommage ou un déplacement casse le
  sidecar, le cache d'aperçus et les futures notes.
- Le scan lit les en-têtes de chaque fichier à chaque lancement (15 à 20 ms par RAW).
- Les notes, drapeaux et mots-clés n'existent pas pour les fichiers.
- Rien n'est conservé entre deux lancements, hors les signets de dossiers.

## 2. Principes

1. **Le sidecar est la vérité portable.** Un fichier `<image>.qaama` à côté de l'image porte
   tout ce que l'utilisateur a décidé : identifiant Qaama, note, drapeau, mots-clés, recette.
   Copier un dossier sur un autre Mac emporte les éditions. Format JSON lisible et versionné.
2. **Le catalogue est un index local**, jamais la seule copie d'une décision de l'utilisateur.
   Il accélère le listage, le tri et les filtres, et retrouve les fichiers déplacés. Il peut
   être supprimé et reconstruit depuis les dossiers et les sidecars.
3. **Photos reste maître chez lui.** Pour la photothèque Apple, PhotoKit fournit déjà identité
   stable, métadonnées, notes et vignettes. Qaama n'indexe pas les photos Apple dans le
   catalogue au MVP ; il rend le listage paresseux (voir §6).
4. **Pas d'AppKit, pas de PhotoKit dans le catalogue** : Foundation, SQLite via GRDB, ImageIO.
5. **Stockage : SQLite via GRDB** (MIT, v7.11, Swift 6 strict, macOS et iOS), derrière une
   abstraction `CatalogStore` pour ne pas lier le reste du code à la bibliothèque. Choisi
   plutôt que SwiftData le 29/10/2026 : SQL complet pour tris et filtres, recherche plein
   texte (FTS5) pour noms et mots-clés, observation des requêtes, migrations explicites,
   performances connues sur des centaines de milliers de lignes, concurrence propre
   (`DatabasePool`, WAL). SwiftData reste limité sur les prédicats, les lots et les
   migrations. Michaël a précisé que « frameworks Apple au maximum » vise l'interface et
   les technologies de plateforme, pas un refus des bibliothèques tierces meilleures.

## 3. Identité d'un fichier

Un `CatalogItem` reçoit un **UUID Qaama** à sa première rencontre, écrit aussi dans le sidecar
dès qu'un sidecar existe. Pour retrouver un fichier d'un scan à l'autre, dans cet ordre :

1. **Sidecar présent** : son UUID gagne (survit à tout, y compris un autre Mac).
2. **Identifiant de fichier système** (`fileResourceIdentifier`, soit volume + inode) : survit au
   renommage et au déplacement dans le même volume, ce qui est le cas courant.
3. **Chemin relatif au dossier racine** : fichier inchangé à la même place.
4. **Empreinte** = taille + date de modification du contenu + SHA-256 des 64 premiers Kio :
   retrouve une copie sur un autre volume. Calculée uniquement pour les fichiers nouveaux ou
   orphelins, jamais pour tout le dossier.

Un fichier absent au scan est marqué **manquant** (conservé 30 jours avec ses métadonnées),
pas supprimé : s'il réapparaît, il est réassocié par les règles ci-dessus.

## 4. Modèle de données (SQLite via GRDB, dans `LibraryKit`)

Tables `folder` et `item` (plus `item_fts` pour la recherche), migrations numérotées.

```
folder
  id: UUID
  bookmark: Data                 signet sécurisé (remplace FolderBookmarkStore)
  displayName: String
  lastScan: Date?
  → items supprimés en cascade

item
  id: UUID                       identifiant Qaama, stable
  folderID: UUID
  relativePath: String           chemin depuis la racine du dossier
  fileName: String
  fileType: String               identifiant UTType
  fileSize: Int64
  contentModified: Date
  fileIdentifier: Data?          fileResourceIdentifier sérialisé
  fingerprint: String?           §3.4, calculée à la demande
  isMissing: Bool
  missingSince: Date?

  -- métadonnées image (phase B du scan, nil tant que non lues)
  pixelWidth, pixelHeight: Int?
  orientation: Int?
  captureDate: Date?
  cameraMake, cameraModel, lens: String?
  iso: Int?  exposureTime, aperture, focalLength: Double?
  isRAW: Bool
  metadataRead: Date?            nil = à lire

  -- décisions de l'utilisateur (miroir du sidecar)
  rating: Int                    0 à 5
  flag: Int                      0 aucun, 1 retenue, -1 rejetée
  keywords: [String]
  hasEdit: Bool
  sidecarModified: Date?         date du sidecar lu, pour détecter un changement externe

  -- liens
  pairedItemID: UUID?            RAW + JPEG de même racine de nom
```

Index : `(folderID, relativePath)` unique, `fileIdentifier`, `captureDate`, `rating`, `flag`.
Table virtuelle FTS5 `item_fts` sur `fileName` et `keywords`.

Emplacement : `Application Support/fr.michaelperrin.qaama/catalog.sqlite` (WAL). Tests sur
une `DatabaseQueue` en mémoire.

## 5. Sidecar v2

```json
{
  "version": 2,
  "id": "6F0E…-UUID Qaama",
  "rating": 3,
  "flag": "pick",
  "keywords": ["lapland", "winter"],
  "recipe": { "version": 1, "exposure": 0.3, "contrast": 0, "saturation": 0.1 }
}
```

- Le sidecar v1 actuel (la recette seule) est lu et migré à la première écriture.
- Écriture atomique ; relecture si sa date change (modification externe ou synchronisation).
- Conflit catalogue / sidecar : la date la plus récente gagne, le sidecar en cas d'égalité.
- Pas de sidecar sans décision de l'utilisateur : une photo jamais touchée n'a pas de fichier
  `.qaama`, le dossier reste propre.

## 6. Scan en deux temps

**Phase A, listage** (rapide, bloquant hors acteur principal) : énumération des fichiers avec
leurs attributs système, association aux `CatalogItem` existants (§3), création des nouveaux,
marquage des manquants. La grille s'affiche dès cette phase, avec les métadonnées déjà en base.

**Phase B, métadonnées** (arrière-plan, par lots de 50) : pour chaque item où `metadataRead`
est nul ou plus ancien que `contentModified`, lecture des en-têtes ImageIO et du sidecar. La
grille se met à jour par lots, sans attendre la fin. Priorité aux items visibles.

**Phase C, surveillance** (après le MVP) : FSEvents sur chaque dossier pour relancer A sur les
sous-dossiers modifiés.

Côté Photos, pas de catalogue : `PhotosLibrarySource` expose une collection paresseuse adossée
au `PHFetchResult` (nombre et accès par index) au lieu d'enumérer 74 000 `PHAsset` au
lancement. Les métadonnées de tri et de filtre viennent de `PHFetchOptions` (prédicats et
tris natifs), ce qui évite de les dupliquer.

## 7. Ce qui change dans le code existant

- `LibraryAsset.id` devient l'UUID Qaama pour les fichiers (`localIdentifier` inchangé pour
  Photos). `PreviewCache` et les vignettes sont donc stables au renommage.
- `LibraryAsset` gagne `flag`, `keywords`, `isRAW`, et les champs caméra utiles au tri.
- `FolderScanner` est scindé : `FolderLister` (phase A, pur, testable sur un dossier
  temporaire) et `ImageMetadataReader` (phase B, dans le futur paquet `ImageIOKit`).
- `FolderBookmarkStore` disparaît au profit de `CatalogFolder.bookmark`.
- `FolderLibrarySource` prend un `CatalogStore` en dépendance et devient le seul endroit qui
  écrit sidecars et catalogue (notes, drapeaux, mots-clés, recette).
- `LibrarySource` gagne `setFlag`, `setKeywords` ; `setRating` cesse d'échouer pour les
  fichiers.
- Un `EditorModel` observable sort de `EditorView` dans la foulée (point 5 de la dette),
  pour que la sauvegarde passe par une seule API.

## 8. Tests prévus

- Identité : renommage, déplacement dans le dossier, copie dans un autre dossier temporaire,
  suppression puis retour, sidecar copié avec le fichier. Chaque cas retrouve le même UUID.
- Sidecar : lecture v1, écriture v2, relecture, conflit de dates.
- Listage : dossier de fixtures généré, fichiers cachés et paquets ignorés, items manquants.
- Métadonnées : lecture par lots, items visibles d'abord, un fichier illisible ne bloque pas
  le lot.
- Catalogue : migrations GRDB appliquées sur une base vide et sur une base v1 remplie.

## 9. Ordre de réalisation (toutes les étapes faites le 29/10/2026)

1. Schéma GRDB + `CatalogStore` (CRUD, requêtes, observation) + tests en mémoire.
2. Sidecar v2 + migration v1 + tests.
3. `FolderLister` et association d'identité + tests de renommage/déplacement.
4. `ImageMetadataReader` par lots + mise à jour progressive de la grille.
5. Branchement dans `FolderLibrarySource`, `LibraryCatalog`, vues ; retrait de
   `FolderBookmarkStore` et `FolderScanner`.
6. Notes, drapeaux, mots-clés dans l'interface (grille et éditeur).
7. Listage paresseux côté Photos.
