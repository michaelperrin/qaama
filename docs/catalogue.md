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
   stable, métadonnées, notes et vignettes. Le listage reste paresseux (voir §6) et le catalogue
   ne garde des photos Apple que ce que PhotoKit ne sait pas interroger (voir §10), jamais une
   décision de l'utilisateur.
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

Tables `folder` et `item`, migrations numérotées.

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
  latitude, longitude: Double?   position GPS de l'en-tête (13/11/2026, migration v7), pour la carte
  isRAW: Bool
  metadataRead: Date?            nil = à lire

  -- décisions de l'utilisateur (miroir du sidecar)
  rating: Int                    0 à 5
  flag: Int                      0 aucun, 1 retenue, -1 rejetée
  keywords: [String]
  hasEdit: Bool
  captureDateOverride: Date?     date de prise de vue corrigée (6/11/2026) ; captureDate reste
                                 celle de l'en-tête, le tri par date prend la correction d'abord
  sidecarModified: Date?         date du sidecar lu, pour détecter un changement externe

  -- liens
  pairedItemID: UUID?            RAW + JPEG de même racine de nom

  -- recherche (6/11/2026)
  foldedName: String             fileName sans casse ni accents
  foldedKeywords: String         mots-clés sans casse ni accents, un par ligne
```

Index : `(folderID, relativePath)` unique, `fileIdentifier`, `captureDate`, `rating`, `flag`.

Recherche : la table FTS5 `item_fts` du départ a été retirée le 6/11/2026. Le plein texte ne
trouve que des débuts de mots (« 1234 » ne trouvait pas `DSCF1234.RAF`) ; les noms de fichiers
se cherchent par n'importe quelle partie. Dossiers et Photos partagent donc la même règle
(`SearchText`) : textes « pliés » à l'écriture, `LIKE` à la lecture, chaque mot tapé devant se
trouver dans le nom ou dans un mot-clé (voir §10 pour les mesures).

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
  "captureDate": "2026-10-29T13:03:12Z",
  "recipe": { "version": 1, "exposure": 0.3, "contrast": 0, "saturation": 0.1 }
}
```

- `captureDate` (6/11/2026) : la date de prise de vue corrigée par l'utilisateur, à la seconde,
  en instant UTC. Absente tant que rien n'est corrigé. L'image n'est jamais réécrite : la
  correction est appliquée à l'EXIF des exports. Remettre la date de l'en-tête retire la clé.

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

Côté Photos, le listage ne passe pas par le catalogue : `PhotosLibrarySource` expose une
collection paresseuse adossée au `PHFetchResult` (nombre et accès par index) au lieu d'enumérer
74 000 `PHAsset` au lancement. Les métadonnées de tri et de filtre viennent de `PHFetchOptions`
(prédicats et tris natifs), ce qui évite de les dupliquer. Ce que PhotoKit ne sait pas
interroger vient de l'index du §10, sous forme de listes d'identifiants ajoutées au prédicat.

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

## 10. Index de la photothèque Photos (5/11/2026)

Pour filtrer sur ce que PhotoKit ne sait pas interroger. Mesures détaillées dans `PLAN.md`
(phase 2, Bibliothèque).

**Ce qui n'a pas besoin d'index : le RAW.** Photos tient un album intelligent RAW
(`PHAssetCollectionSubtype.smartAlbumRAW`), exact sur la photothèque de Michaël, paires RAW + JPEG
comprises. Ses identifiants se lisent en quelques dizaines de millisecondes à chaque lancement et
à chaque changement : le filtre RAW Only et le badge RAW sont complets tout de suite.

**Ce qui en a besoin : le nom de fichier d'origine et les mots-clés.** Le nom sert à reconnaître
les paires RAW + JPEG importées en deux assets (même nom à l'extension près, même seconde de prise
de vue) ; nom et mots-clés servent à la recherche (6/11/2026), et le nom servira au tri.

```
photosAsset
  id: String                     identifiant local PhotoKit
  fileName: String?              nom d'origine, extension comprise
  nameStem: String               nom sans extension, en minuscules ("" si inconnu), pour les paires
  foldedName: String             nom sans casse ni accents, pour la recherche
  captureSecond: Int?            date de prise de vue, en secondes entières
  isRAW: Bool                    copie de l'album intelligent RAW, pour la jointure des paires
  latitude, longitude: Double?   position (`PHAsset.location`), nulle sans position ; pour la carte

photosAssetKeyword               une ligne par photo et mot-clé, supprimée avec la photo
  assetID: String
  keyword: String
  folded: String                 mot-clé sans casse ni accents, pour la recherche

photosIndexState                 une seule ligne
  changeToken: Data?             PHPersistentChangeToken archivé ; nul tant qu'aucune passe n'a fini
```

Index : `(nameStem, captureSecond)` et `isRAW`. Même fichier SQLite que le reste du catalogue,
derrière `PhotosIndexStore` : tout y est dérivé de PhotoKit, donc reconstructible, et supprimer
le catalogue ne coûte qu'une demi-minute de réindexation en arrière-plan.

**Position (13/11/2026, migration v6).** Lue dans la même passe que le nom, depuis la base de
Photos (donc aussi pour les originaux dans iCloud), 0°/0° écarté : deux colonnes de `photosAsset`
plutôt qu'une table à part, puisque même lecture et même péremption. La migration vide l'index,
qui se reconstruit. `PhotosIndexStore.locatedAssets()` rend toutes les photos placées en un seul
parcours de la table ; le regroupement pour la carte se fait en mémoire (`PhotoMapIndex`), sans
requête par région.

**Pour la suite : une table par source de données, pas une table qui s'élargit.** `photosAsset`
garde ce qui est lu ensemble dans la même passe et périmé ensemble. Ce qui a plusieurs valeurs
par photo (mots-clés) ou vient d'une autre lecture, avec sa propre couverture et sa propre
péremption (EXIF lu sur l'original), aura sa table, liée par l'identifiant de l'asset et
supprimée en cascade : l'absence de ligne voudra dire « pas encore lu ».

**Construction** (`PhotosIndexer`, par lots de 1 000, priorité `utility`) : les noms viennent de
`PHAssetExtendedMetadata` chargé en bloc avec les assets (`prefetchAssetExtendedMetadata`,
macOS 27), jamais des fichiers d'origine, qui sont pour la plupart dans iCloud. Deux chemins :

- **avec un jeton** : `fetchPersistentChanges(since:)` donne les assets ajoutés, modifiés et
  supprimés depuis la dernière passe, y compris pendant que Qaama était fermé ; seuls ceux-là
  sont relus. L'observateur de changements persistants (macOS 27) déclenche la même passe en
  direct, une seconde après le dernier changement.
- **sans jeton** (premier lancement, ou passe interrompue) : la liste des identifiants de la
  photothèque est comparée à l'index, les absents sont lus, les disparus retirés. Le jeton, pris
  avant le listage, n'est enregistré qu'en fin de passe : c'est ce qui fait la reprise.

Un jeton que Photos ne reconnaît plus (historique trop ancien) vide l'index, qui se reconstruit.

**Recherche** (`PhotosIndexStore.search`) : chaque mot tapé doit se trouver, comme sous-chaîne
et sans casse ni accents, dans le nom ou dans un mot-clé. Les textes sont « pliés » à
l'indexation (`SearchFolding`), la requête est un simple `LIKE` : 6 à 19 ms sur 74 000 photos.
Les identifiants trouvés rejoignent le prédicat ; comme PhotoKit ralentit avec la longueur de la
liste (200 ms pour 52 000), ce listage-là se fait hors du fil principal (`PhotosListing`).

**Filtrage** (`PhotosFetchPredicate`) : `localIdentifier IN` la liste des RAW pour RAW Only,
`NOT (localIdentifier IN …)` la liste des jumeaux JPEG pour les masquer. Le résultat reste un
`PHFetchResult` : listage paresseux, tri natif, cumul avec favoris et note, albums, suivi des
changements et `index(of:)` pour la navigation dans l'éditeur.

**PhotoKit reste derrière un protocole** (`PhotosIndexLibrary`, implémenté par
`PhotoKitIndexLibrary`) : l'indexeur, le store et `PhotosIndex` se testent avec une fausse
photothèque en mémoire.
