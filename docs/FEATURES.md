# Qaama features

What the app does today, by area. Kept current with every change (see AGENTS.md); written so it
can feed a website one day. Dates are when the feature landed.

## Library

### Sources
- Apple Photos library: the whole library, the Favorites smart album, and every user album in
  its folder hierarchy, kept in sync with Photos (2026-10-29, albums 2026-10-30).
- Folders on disk, added with the system picker and remembered across launches; subfolders
  appear as a tree in the sidebar (2026-10-29, subfolders 2026-10-30).
- Live folder watching: changes made in the Finder or by an import show up within seconds
  (2026-10-30).
- Map, at the top of the sidebar: the photos of the Photos library and of every folder on one
  map, whichever library holds them. A double click on a group lists its photos in a grid,
  woven by date whatever library they come from, where they can be rated, tagged, re-dated and
  edited; each change goes to the library the photo belongs to, and is undoable. Search and the
  filters both kinds of library know (rating, RAW, JPEG twins) narrow the map (2026-11-13).

### Browsing
- Thumbnail grid that stays fast on very large libraries (74,000 photos listed in well under a
  second, rows built only when shown) (2026-10-29).
- Sorting by capture date, modification date, rating or file name, ascending or descending
  (2026-10-30).
- Filters: minimum rating, flag, edited only, RAW only, favorites only (2026-10-30).
- Browsing by month, in the Apple Photos library, its albums and folders alike, whenever photos
  are sorted by capture date (2026-11-10):
  - Month headers in the grid: each month starts under its name and its number of photos.
    Photos without a date come under "No Date".
  - The window's subtitle tells the dates of the photos on screen ("Oct 10 – Nov 2, 2021"), and
    the toolbar the month at the top of the grid, both following the scroll.
  - Month picker, from that toolbar button or View › Go to Month… (⇧⌘T): the years with photos
    in a column and the twelve months of the chosen year, those without photos dimmed and the
    month on screen highlighted; a click on a year or a month scrolls the grid there, and the
    picker stays open to try the month next to it. The number of photos of the month under the
    pointer shows below. It follows the filters, the search and the album shown.
- Search on file names and keywords, in folders (2026-10-30) and in the Apple Photos library and
  its albums (2026-11-06): any part of a name ("1234" finds DSCF1234.RAF), several words at
  once, whatever the case and accents; combines with every filter and follows keywords as they
  are edited.
- RAW only in the Apple Photos library and in its albums too, complete from the first second
  and combinable with the favorites and rating filters; stepping through photos in the editor
  follows it (2026-11-05).
- RAW + JPEG pairs shot together show as one photo with a RAW+JPG badge; the JPEG twin can be
  shown on demand (2026-10-30). In Photos this also covers pairs imported as two separate
  photos (2026-11-05).
- Local index of the Photos library for what Photos itself can't filter on, built in the
  background without slowing the grid, resumed where it stopped, and kept current with every
  change made in Photos, even while Qaama was closed; the grid says so while the index is
  still being built (2026-11-05).
- Badges on thumbnails: rating, picked or rejected flag, edited, RAW (2026-10-29/30).
- Thumbnail size: a slider in the toolbar, View › Zoom In (⌘+) and Zoom Out (⌘−), or a pinch on
  the trackpad over the grid, from 80 to 400 points; the photo under the pointer stays under it
  while pinching, the one at the center of the view stays put with the slider or the menu, and
  thumbnails are fetched at the size they are shown, so zooming in keeps them sharp. Remembered
  across launches (2026-11-07, pinch 2026-11-08).
- Thumbnail shape, with a toolbar button and in the View menu: Square Thumbnails (the photo
  cropped to a square) or Whole Photos (the whole photo inside the square, with its own
  proportions; the place is reserved at the photo's shape before it loads); the thumbnails
  animate from one shape to the other. Remembered across launches (2026-11-07, button and
  animation 2026-11-08).
- Thumbnails of edited photos show the real edit, from a cached preview (2026-10-29).
- Multiple selection in the grid: click, ⌘-click, ⇧-click, ⌘A, Escape; double-click opens the
  editor; the context menu acts on the whole selection (2026-10-30).
- Image › Rating and Image › Flag: rate (No Rating to 5 Stars, keys 0–5) and pick, reject or
  unflag (P, X, U) the photos selected in the grid or the photo open in the editor; the menu
  checks the current value. Undoable (2026-11-06).
- Rating, flag and keywords in the Info panel next to the grid, to read and to change without
  opening a photo. With several photos
  selected (up to 50), the panel shows what they share (rating, flag, keywords, camera, lens,
  exposure, size, the span of their dates) and says "Mixed" where they differ; a rating or a
  flag set there goes to every photo, a keyword added or removed is added to or removed from
  every photo, and the keywords only some have are left alone. Undoable (2026-11-06).
- Info panel next to the grid: selecting a photo shows its histogram, camera, lens, exposure,
  size, capture date and file name in the right column, without opening it; the same panel as
  the editor's Info tab, shown or hidden with the same toolbar button and View › Hide Inspector
  (⌥⌘I), and it stays in place when a photo is opened. For Photos originals kept in iCloud it
  shows what Photos knows (name, size, date) and offers a Download Original button to get the
  camera details: selecting a photo never downloads anything by itself (2026-11-06).
- Map of where a geotagged photo was taken, under the Info panel, next to the grid and in the
  editor's Info tab: drag to move, pinch, scroll or use the zoom buttons, and a button brings
  the map back onto the photo. The name of the place ("Étretat, France") shows under the map,
  from Apple's geocoding service (2026-11-13). In Photos it uses the location Photos stores, so it shows even
  when the original is in iCloud (2026-11-06).
- Map of a library: the toolbar's Grid / Map switch (View › as Grid, as Map) replaces the
  thumbnails with a map of where the photos were taken, in the Photos library or one of its
  albums, and in a folder or one of its subfolders. Neighboring photos are grouped under one
  thumbnail (the most recent photo) with their number; zooming in splits the groups, zooming
  out merges them. The map follows the search and the filters, and the window's subtitle says
  how many of the listed photos have a location. A click selects the photos of a group (the
  Info panel and the Image menu then act on them), a double click lists them in the grid, with
  a Back button to the map where it was left. View › Zoom In and Zoom Out (⌘+, ⌘-) zoom
  the map as they zoom the grid. A toolbar button and View › Satellite switch the
  map to satellite imagery, with the names of places and the roads over it (2026-11-13). In Photos, locations come from Photos' database,
  so photos whose original is in iCloud are on the map too; in folders, from the files'
  headers, read in the background (2026-11-13).
- Show in Finder for photos of a folder: File › Show in Finder (⇧⌘R) for the grid's selection or
  the photo open in the editor, the thumbnails' context menu (the whole selection, selected in
  its Finder window), and the ellipsis button next to the file name in the Info panel, next to
  the grid and in the editor's Info tab (2026-11-12).

### Organizing
- Star ratings 0–5, stored natively in Photos and in a sidecar file for folders (2026-10-29/30).
- Pick / reject flags for folder photos, with P, X and U shortcuts (2026-10-30).
- Keywords, native in Photos and in the sidecar for folders (2026-10-30).
- Adjust Date & Time: correct when photos were taken, for one photo or a whole selection, from
  the Image menu (for the grid's selection or the photo open in the editor), the thumbnails'
  context menu or by clicking the date in the Info panel. Either give a date, or
  shift each photo from its own date by years, months, days, hours and minutes, later or
  earlier (a camera clock that was wrong or reset, another time zone). The dialog shows the
  before and after of each selected photo, one at a time, next to its thumbnail; entering the
  real date of one photo there derives the shift for all of them. Originals are never
  rewritten: the correction is stored in Photos' database or in the sidecar for folders, the
  library sorts by it, and exports carry it in their EXIF. The JPEG twin of a RAW follows.
  Undoable (2026-11-06).

- Albums of the Apple Photos library, managed without leaving Qaama (2026-11-06):
  - New albums and album folders, at the top level (File › New Album…, New Album Folder…, or
    the context menu of the sidebar's Albums row) or inside a folder (its context menu); a new
    album opens right away.
  - Delete Album… in an album's context menu, after confirmation; the photos stay in the library.
  - Add photos to an album by dragging them from the grid onto the album in the sidebar, or with
    Add to Album in the thumbnails' context menu and in the Image menu, which lists the albums
    in their folders and starts with New Album… to make one from the selection.
  - Add to Album › Search… (⌥⌘A in the Image menu) finds an album by typing part of its name, or
    of the name of a folder it is in: every folder is searched at once, without case or accents,
    and several words narrow the results ("2024 japan"). The best match comes first; Return adds
    the photos to it, the arrow keys or a click choose another (2026-11-12). The search sheet
    can be resized to show long names in full, and opens again at the size it was given
    (2026-11-13).
  - Add to “<album>” (⌃⌘A) sends photos to the album last used, remembered between sessions.
  - Remove from Album, in an album, for the selected photos; they stay in the library.
  - The Image menu items act on the grid's selection or on the photo open in the editor.
  - Every one of these is undoable, deleting an album included: it comes back with its name,
    its folder and its photos.

### Data
- Non-destructive: originals are never modified. Edits live in Photos adjustment data or in a
  `.qaama` sidecar next to the file, in readable JSON (2026-10-29).
- Folder photos keep their identity through renames and moves; a sidecar left behind by a
  rename is reattached automatically (2026-10-29).
- Local SQLite catalog, rebuildable at any time (2026-10-29).

## Editor

### Workflow
- Opens the original (RAW through Apple's RAW engine) with the saved edit; Save stores the
  edit back; Export writes a full-size JPEG (2026-10-29).
- Undo and redo per gesture, through the Edit menu and its shortcuts (2026-10-30).
- Hold Compare to see the original (2026-10-30).
- Presets: save the current adjustments under a name, apply or delete them from a menu; stored as
  readable JSON files (2026-10-30).
- Copy and paste adjustments between photos (Image › Adjustments menu, ⇧⌘C, ⇧⌘V, and the
  thumbnails' context menu without opening the editor, to one photo or the whole selection);
  the crop stays with each photo; undoable (2026-10-30).
- Zoom with a pinch, pan by dragging, double-click to fit (2026-10-29).
- Zoom slider in the toolbar, from Fit (the whole photo, never smaller) up to 16 times that, with
  a detent at 100% (one pixel of the photo per pixel of the screen) and the zoom shown as a
  percentage of the photo's real size; zooming back out to Fit recenters the photo; View › Zoom In
  (⌘+), Zoom Out (⌘−), Zoom to Fit (⌘0) and Actual Size (⌘1) (2026-11-09).
- Round Back button at the top left of the toolbar returns to the photo grid (2026-11-05).
- Inspector in three icon tabs in the toolbar: Info (histogram and file metadata), Crop & Straighten (the crop
  tool: opening the tab frames the image, leaving it or pressing Done applies the crop; C toggles
  it from anywhere) and Adjustments; the tab is remembered from one photo to the next
  (2026-11-05).
- Show or hide the inspector to give the whole window to the photo: toolbar button, or View ›
  Hide Inspector (⌥⌘I); remembered between sessions (2026-11-05).
- Step to the previous or next photo of the library with the left and right arrow keys, in the
  grid's order and within its filters; unsaved edits prompt to save, discard or stay. The photo
  shows first, the inspector follows once you stop on a photo (2026-11-05).
- Fast RAW browsing: a RAW first appears as a quick draft decode by the same RAW engine (same
  colors), and gets its full resolution once you stay on it; the photos before and after the one
  on screen are read and decoded ahead, so stepping to them is immediate (2026-11-05).

### Adjustments
- A switch on every group (white balance, light, curves, color, color mixer, detail, black and
  white, effects, vignette): off, the group no longer applies but keeps its values, so a photo
  can be compared with and without it; undoable, saved with the edit, per mask layer (2026-11-11).
- Compact sliders: the color ones show on their track what each end does (cooler to warmer,
  green to magenta, gray to vivid, the hues a color range can turn to, darker to lighter); a
  value that was changed stands out; double-click a slider or its name to reset it (2026-11-11).
- White balance: temperature, tint (2026-10-30).
- Light: exposure, highlights, shadows, black point, contrast (2026-10-29/30).
- Color: vibrance, saturation (2026-10-29/30).
- Tone curves: RGB and per-channel, monotone interpolation (no overshoot), points added by
  clicking, removed by double-clicking, applied in display values (2026-10-30).
- Detail: sharpness (softening on the negative side), luminance noise reduction (2026-10-30).
- Color mixer: hue, saturation and luminance per color range (red, orange, yellow, green,
  aqua, blue, purple, magenta) with smooth blends between ranges (2026-10-30). Pick the range
  with its swatch; a small histogram above the swatches shows which hues the photo holds, each
  range's hues above its swatch, even when the photo is shown in black and white; a dot in a
  swatch marks a range already adjusted (2026-11-12).
- Black and white with a channel mixer (red, green, blue contributions) (2026-10-30).
- Effects: film-like grain (2026-10-30).
- Vignette with its own switch, which keeps the settings when off: amount (darker or brighter
  edges, down to black corners), midpoint (how far from the center it starts), feather, roundness
  (from a rounded rectangle that follows the frame to the fitted oval to a circle) and highlights
  (bright areas resist the darkening). It follows the crop: the shape is fitted to the final
  frame (2026-11-11).
- Dehaze: removes atmospheric haze estimated from the photo itself (dark channel prior), or adds
  some with negative values; works inside masks like every adjustment (2026-10-30).

### Crop and straighten
- Crop frame with corner and edge handles, thirds grid, free or locked aspect ratio (original,
  square, 3:2, 4:3, 16:9, 5:4) (2026-10-30).
- Straighten from -45° to +45° with automatic trimming of empty corners; rotate by quarter
  turns; flip horizontally (2026-10-30).

### Retouch
- Retouch tool (R, or the bandage tab of the inspector): paint over an object, a wire or a spot
  and it is filled in from its surroundings when the mouse goes up, on device and without a
  machine learning model; brush size from the inspector or the [ and ] keys; pinch to zoom and
  Option-drag to move around while painting; each stroke is one undo step, Remove All brings
  everything back; retouches are stored as strokes in the edit, stay on what they removed when
  the photo is cropped, turned or straightened, and are carried into saves, exports and
  thumbnails (2026-11-10).

### Masks
- Masked adjustment layers: linear gradient, radial gradient, luminance range and color range
  masks, combined by adding, subtracting or intersecting components; feather, density, invert;
  rename, duplicate (optionally inverted), delete; the sliders edit the selected layer; red
  overlay on the canvas (O) (2026-10-30).
- Subject, background and people masks computed on device by Vision, in the background, scaled
  from a 1024 px analysis (2026-10-30).
- Mask editing on the canvas: draggable handles for linear and radial gradients, brush painting
  with size, hardness and eraser ([ ] E keys), live red overlay (2026-10-30).
- Sky and scene masks (grass, trees, mountains, sea, river, water, sand, snow, rocks, ground,
  road, pavement, buildings, houses, walls, floor) from a bundled segmentation model (Apple's
  DETR, Apache 2.0), with edges refined on device by Vision (2026-10-30).

### Information
- Histogram of the current edit with clipping indicators (2026-10-30).
- Camera, lens, exposure settings, size and capture date from the file's EXIF (2026-10-30).

## Export

### Single photo
- Export the open photo with its current edit, saved or not, from the editor (Export…, ⇧⌘E)
  (2026-10-30).
- Formats: JPEG and HEIC and AVIF with a quality slider, PNG lossless (2026-10-30).
- Size: original, or a pixel width, height or long edge (the photo fits in a square); the output
  dimensions are shown, enlargements flagged (2026-10-30).
- Preview of the exported photo in the export window (2026-10-30).
- EXIF, TIFF, GPS and IPTC metadata of the original file carried over, orientation reset
  (2026-10-30).
- Settings remembered between exports (2026-10-30).
- File › Export… (⇧⌘E) exports the open photo, or the grid selection (2026-10-30).

### Frame and watermark
- Solid color frame: thickness as a share of the photo, even border or a target aspect ratio
  (1:1, 4:5, 3:2, 16:9…), rounded photo corners, any color; shown in the preview (2026-10-30).
- Watermark: text (font, color) or a picture imported into the app, size as a share of the
  photo's width, opacity, drop shadow, nine positions or tiled over the whole photo; shown in the
  preview (2026-10-30).

### Batch
- Export the selected photos from the grid (context menu or File › Export…) into a chosen folder,
  with their saved edits, the same format and size settings, a progress bar and Stop; files keep
  their original names with the new extension, a numeric suffix avoids overwriting; failures are
  listed at the end (2026-10-30).
- Photos are exported in the order the grid shows them, so numbered file names follow the grid
  (2026-11-10).

### Files
- Naming: original names, or a sequence with a prefix, a start number and a digit count
  (2026-10-30).
- Existing files: keep both and number the new one, or overwrite (2026-10-30).
- Metadata: keep all, remove the location, or remove all (2026-10-30).

### Presets
- Export presets saving format, size, frame, watermark and file options together; chosen from a
  menu in the export window, which shows which preset the current settings match (2026-10-30).

## Platform
- Native macOS app (macOS 27), SwiftUI, Core Image on Metal, sandboxed (2026-10-29).
- English interface, ready for localization (2026-10-29).
