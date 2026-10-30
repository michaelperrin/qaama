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

### Browsing
- Thumbnail grid that stays fast on very large libraries (74,000 photos listed in well under a
  second, rows built only when shown) (2026-10-29).
- Sorting by capture date, modification date, rating or file name, ascending or descending
  (2026-10-30).
- Filters: minimum rating, flag, edited only, RAW only, favorites only; search on file names and
  keywords for folders (2026-10-30).
- RAW + JPEG pairs shot together show as one photo with a RAW+JPG badge; the JPEG twin can be
  shown on demand (2026-10-30).
- Badges on thumbnails: rating, picked or rejected flag, edited, RAW (2026-10-29/30).
- Thumbnails of edited photos show the real edit, from a cached preview (2026-10-29).
- Multiple selection in the grid: click, ⌘-click, ⇧-click, ⌘A, Escape; double-click opens the
  editor; the context menu acts on the whole selection (2026-10-30).

### Organizing
- Star ratings 0–5, stored natively in Photos and in a sidecar file for folders (2026-10-29/30).
- Pick / reject flags for folder photos, with P, X and U shortcuts (2026-10-30).
- Keywords, native in Photos and in the sidecar for folders (2026-10-30).

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

### Adjustments
- White balance: temperature, tint (2026-10-30).
- Light: exposure, highlights, shadows, black point, contrast (2026-10-29/30).
- Color: vibrance, saturation (2026-10-29/30).
- Tone curves: RGB and per-channel, monotone interpolation (no overshoot), points added by
  clicking, removed by double-clicking, applied in display values (2026-10-30).
- Detail: sharpness (softening on the negative side), luminance noise reduction (2026-10-30).
- Color mixer: hue, saturation and luminance per color range (red, orange, yellow, green,
  aqua, blue, purple, magenta) with smooth blends between ranges (2026-10-30).
- Black and white with a channel mixer (red, green, blue contributions) (2026-10-30).
- Effects: vignette, darkening or brightening the corners; film-like grain (2026-10-30).
- Dehaze: removes atmospheric haze estimated from the photo itself (dark channel prior), or adds
  some with negative values; works inside masks like every adjustment (2026-10-30).

### Crop and straighten
- Crop frame with corner and edge handles, thirds grid, free or locked aspect ratio (original,
  square, 3:2, 4:3, 16:9, 5:4) (2026-10-30).
- Straighten from -45° to +45° with automatic trimming of empty corners; rotate by quarter
  turns; flip horizontally (2026-10-30).

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

### Batch
- Export the selected photos from the grid (context menu or File › Export…) into a chosen folder,
  with their saved edits, the same format and size settings, a progress bar and Stop; files keep
  their original names with the new extension, a numeric suffix avoids overwriting; failures are
  listed at the end (2026-10-30).

## Platform
- Native macOS app (macOS 27), SwiftUI, Core Image on Metal, sandboxed (2026-10-29).
- English interface, ready for localization (2026-10-29).
