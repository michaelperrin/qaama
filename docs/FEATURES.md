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
- Devices, at the top of the sidebar while one is plugged in: an SD card in a reader, a camera
  or an iPhone shows there, and its photos in the same grid as a library, by month, newest
  first. While the device is read, the grid already shows as many empty thumbnails as it holds
  photos, with a progress bar, and they fill with the photos as they are found; the photos then
  take their places by date. A small thumbnail read from each file's header shows at once, then
  the sharp one. A RAW and the JPEG shot with it show as one photo; videos are counted, not
  shown (2026-11-19).
- A double click, or the space bar, shows a photo of the device as large as the window, with its
  name, its date and its place among the others; the arrow keys go from photo to photo, the
  next one being read in advance, and Escape goes back to the grid (2026-11-19).
- Import: the selected photos of a device, or all of them, go to the Apple Photos library,
  with an album found by typing part of its name or made on the spot, in a folder of albums
  or not, or are copied into one of the folders of the
  sidebar, filed by date in one of five ways (2026/2026-11-19, 2026/11/19, 2026/11, 2026, 2026-11-19) or
  as they are. Each copy is checked against
  the size the device announced before it takes its place; photos already there are left alone;
  a RAW comes with its JPEG. A bar shows how far the import is, which goes on while the window
  shows something else and can be stopped. Undo moves what was imported to the Trash, or deletes
  it from Photos, which asks first. The device
  can be ejected when done, or from its context menu in the sidebar (2026-11-19).
- New photos only: the photos of a device that were imported before show dimmed, with a check
  mark, and the title says how many are new. With nothing selected, Import brings the new ones
  only; selected photos are imported whatever they are. Undoing an import makes its photos new
  again (2026-11-19).
- The import sheet lists the day folders the photos will go to, with how many photos each
  (2026-11-19).
- Last Imports, a section of the sidebar once photos were imported: the last ten imports, each
  under its date and time, or a name given from its context menu, kept across launches. An entry
  shows the photos that import brought, alone, in the library they went to, to rate them, file
  them in albums or edit them (2026-11-19).
- Hide Already Imported, an eye button of a device's toolbar and a command of the View menu:
  only the photos left to import show, and the title says so (2026-11-19).
- Videos of a device are listed among its photos, under a Video badge, and can be selected,
  imported and deleted like them. An import of the new photos can bring the new videos too,
  filed like the photos in a folder (second copy included) or as videos in the Photos library,
  and never twice. Once imported, Qaama doesn't list them (2026-11-20).
- Keywords at import: a field of the import sheet gives keywords to every photo imported, as
  tokens, picked among the keywords already in use while typing, or new ones (2026-11-20).
- Import presets: the settings of the import sheet (destination and album, filing, keywords,
  videos, second copy, ejecting) saved under a name and brought back from a menu next to the
  sheet's title, kept across launches. A preset changed after it was chosen shows as edited
  and can be updated in one item (2026-11-20).
- Select All, next to Import in a device's toolbar: what is selected is what is imported
  (2026-11-20).
- Second copy: an import can copy every file to another folder as well, on another disk for
  instance, filed by day, as a backup. A second copy that fails is told, and its photo is then
  never deleted from the device (2026-11-19).
- An import can delete from the device what it copied, once it is over: only the photos that
  made it, for good; asked each time (2026-11-19).
- Photos can be deleted from a card or a camera, from the context menu or Image › Delete, after
  a confirmation: for good, a card has no Trash. A RAW goes with its JPEG; a locked card offers
  no deletion (2026-11-19).

### Browsing
- Thumbnail grid that stays fast on very large libraries (74,000 photos listed in well under a
  second, rows built only when shown) (2026-10-29).
- Sorting by capture date, modification date, rating or file name, ascending or descending
  (2026-10-30).
- Filters: rating, flag, edited only, RAW only, favorites only (2026-10-30).
- Filter panel, from the toolbar's Filter button (2026-11-19):
  - One row per filter with a checkbox: Favorites, Edits, RAW, Rating, Flag, Date, Location.
    A checked row shows what it asks; unchecking it keeps the value for the next time.
  - Edits: the edited photos or the ones not edited yet (2026-11-19). In folders an edit is
    Qaama's; in the Apple Photos library and its albums it is any app's, as the badge on
    thumbnails tells.
  - Rating compared either way: at least, at most or exactly a number of stars, or unrated photos.
  - Date: the photos taken between two days, both included, or in the last days, weeks, months
    or years counted back from today ("In the Last 30 Days"), which moves on with the days
    (relative dates 2026-11-19).
  - Location: the photos taken within a radius of a place, from 50 m to 1,000 km (or feet and miles, where
    roads are measured in them). The place is searched by name or clicked on the panel's map,
    which draws the disc; the radius is set with a slider or typed.
  - A switch turns every filter off without losing them, and an arrow unchecks them all. The
    panel of each library comes back as it was left; the toolbar button is filled while filters
    apply.
  - Works in folders, in the Apple Photos library and its albums (flag aside, which Photos
    doesn't know), and narrows the map of every library.
- Saved filters (2026-11-19): Save as Preset…, at the bottom of the Filter panel, keeps the
  filters that apply under a name. Each preset is an entry of the sidebar's Saved Filters
  section: a click shows the library it was saved in (the Photos library, an album, a folder or
  one of its subfolders) filtered that way, under the preset's name, and leaves that library's
  own entry as it was. A right click renames or deletes the preset. Saving, renaming and
  deleting are each undoable, and the presets are remembered across launches.
  - In a preset, once its filters are changed, the panel's button becomes Update Preset, which
    replaces what the preset filters by (undoable); the arrow next to it holds Save as New
    Preset….
  - A preset saved with dates "in the last…" always shows the latest photos: a smart album of
    the last month, of this year's five-star photos, and so on.
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
- The grid keeps its photos in place when its width changes: hiding or showing the sidebar or the
  inspector, or resizing the window, makes other rows of the same photos, with the first one
  where it was. While the sidebar or the inspector slides, the grid stays still, so the animation
  stays smooth in a large library: a column that leaves uncovers photos already in place, one
  that comes covers them, and the rows are made anew once (2026-11-17).
- Thumbnail shape, with a toolbar button and in the View menu: Square Thumbnails (the photo
  cropped to a square) or Whole Photos (the whole photo inside the square, with its own
  proportions; the place is reserved at the photo's shape before it loads); the thumbnails
  animate from one shape to the other. Remembered across launches (2026-11-07, button and
  animation 2026-11-08).
- Thumbnails of edited photos show the real edit, from a cached preview (2026-10-29).
- Multiple selection in the grid: click, ⌘-click, ⇧-click, ⌘A, Escape; double-click opens the
  editor; the context menu acts on the whole selection (2026-10-30).
- Keyboard selection in the grid: once a photo is clicked, the arrow keys move the selection
  through rows and months (up and down keep the column, into the month above or below), ⇧ with
  them extends or shrinks it, and the grid scrolls to keep the photo in view; back from the
  editor, the arrows go on from the photo just edited (2026-11-18).
- Rectangle selection in every grid, a device's included: a drag that starts beside the photos
  selects every thumbnail it touches (⇧ adds to the selection, ⌘ toggles), scrolling when it
  goes past the top or the bottom; a click beside the photos selects none. In the grids of a
  device and of a folder, where photos aren't dragged to albums, it can start on a photo too
  (2026-11-20).
- Rating and flag from the context menus of the grid's thumbnails (acting on the selection when
  the photo is part of it) and of the photo open in the editor: a row of five stars filled up to
  the rating, as the Finder shows its tags, then Remove Rating; below a separator, Pick and Reject,
  checked at the current flag, then Remove Flag. Choosing the current rating or flag again clears
  it. Remove Rating and Remove Flag are offered only when a photo has one, Pick and Reject only for
  folder photos (Photos has no flags). Undoable (2026-11-19).
- Image › Rating and Image › Flag: rate (items drawn as stars, ★☆☆☆☆ to ★★★★★, keys 1–5, Remove
  Rating with 0) and pick,
  reject or unflag (P, X, U) the photos selected in the grid or the photo open in the editor; the
  menu checks the current value. Undoable (2026-11-06, Remove Rating 2026-11-19).
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
- Assign Location: set or correct where photos were taken, from the Location section of the
  Info panel, next to the grid (one photo or a selection) and in the editor's Info tab. The
  pin button (or Assign… for photos without a location) turns editing on, shown pressed in
  until clicked again, and opens a search field: places are found by name
  through Apple's search service, nearest to the photo first, and picked with a click or with
  the arrow keys and Return; a click on the map puts the pin there, and the pin can be dragged
  elsewhere. Every change is one undoable step. Originals are never rewritten: the location is
  stored in Photos' database or in the sidecar for folders, the library's map follows, and
  exports carry it in their GPS metadata. The JPEG twin of a RAW follows (2026-11-18).
- Remove Location, and for folder photos Revert to Original Location (back to what the file
  says), from the menu next to the Location section's pin button, from Image › Location (with
  Assign Location…, which opens the Info panel ready to search) and from the thumbnails'
  context menu, for one photo or a whole selection, each one undoable step (2026-11-18).
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
  - Remove from Album, in an album, for the selected photos; they stay in the library. Also for
    the photo open in the editor, from the Image menu or a secondary click on it: the editor
    moves on to the next photo, after asking about unsaved edits. The Delete key does it, as in
    Photos (2026-11-17).
  - The Image menu items act on the grid's selection or on the photo open in the editor.
  - The albums a photo is in, listed in the Info panel next to the grid and in the editor's Info
    tab, each with the folders it is in; with several photos selected, the albums they are all
    in. A click on one shows that album (from the editor, after asking about unsaved edits). The
    list follows photos added to or removed from an album (2026-11-17).
  - Back from an album opened that way: the toolbar's Back button and View › Back (⌘[) return to
    where the album was opened from, as it was left: the grid scrolled to the same photos, the
    same selection, the same photo open in the editor. Albums opened one from the other are
    retraced one by one (2026-11-17).
  - Every one of these is undoable, deleting an album included: it comes back with its name,
    its folder and its photos.

- A secondary click on a photo outside the selection selects it, as in Photos and the Finder:
  the context menu, the selection ring and the Info panel are about the same photo. On a
  selected photo, the selection stays and the menu acts on all of it (2026-11-17).
- Delete photos (2026-11-17): Image › Delete Photo, or Delete 3 Photos for a selection, in the
  thumbnails' context menu and in the one of the photo open in the editor, which then shows the
  next photo. The Delete key does it; in an album, where that key takes photos out of the album,
  deleting is ⌘⌫.
  - In a folder, the file goes to the Trash with its sidecar, after confirmation, and Undo puts
    both back: the photo returns with its rating, flag, keywords and edit.
  - In the Apple Photos library, Photos asks for confirmation itself and keeps the photo in
    Recently Deleted for 30 days; it is restored from Photos, not with Undo.
  - A RAW + JPEG pair shown as one photo is deleted as one.
  - Also from the map of every library, each photo being deleted in the library that holds it.
- Duplicate photos (2026-11-17): Image › Duplicate Photo (⌘D), in the thumbnails' context menu
  and in the one of the photo open in the editor. The copy keeps the rating, flag, keywords,
  corrected date and saved edit, which stays editable and revertible on the copy. Undoable.
  - In a folder, the copy is a file next to the original, named as the Finder names one
    ("IMG_1 copy.jpg"), with a sidecar of its own; the two halves of a RAW + JPEG pair are copied
    together and stay a pair.
  - In the Apple Photos library, the copy is a new photo made from the original files (downloaded
    from iCloud if needed), with the date, place, favorite, rating and keywords, added to the
    album being shown. Undo deletes it, which Photos asks to confirm.

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
- The Edit menu names what Undo and Redo take back: the setting moved (Undo Exposure, Undo
  Vignette Amount, Undo Red Hue), the switch flipped (Undo Turn Off Light) or the action
  (Undo Rotate Right, Undo Add Sky Mask, Undo Brush Stroke, Undo Apply Preset) (2026-11-18).
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
- Round Back button at the top left of the toolbar returns to the photo grid (2026-11-05), which
  is found where it was left; when the editor stepped to another photo, the grid shows that one.
  View › Back (⌘[) does the same, and leaves a group opened from the map (2026-11-17).
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
- A switch on every group (white balance, light, curves, color, color mixer, detail, denoise,
  black and white, effects, vignette): off, the group no longer applies but keeps its values, so
  a photo can be compared with and without it; undoable, saved with the edit, per mask layer
  (2026-11-11).
- Compact sliders: the color ones show on their track what each end does (cooler to warmer,
  green to magenta, gray to vivid, the hues a color range can turn to, darker to lighter); a
  value that was changed stands out; double-click a slider or its name to reset it (2026-11-11).
- White balance: temperature, tint (2026-10-30).
- Light: exposure, highlights, shadows, black point, contrast (2026-10-29/30).
- Color: vibrance, saturation (2026-10-29/30).
- Tone curves: RGB and per-channel, monotone interpolation (no overshoot), points added by
  clicking, removed by double-clicking, applied in display values (2026-10-30).
- Detail: sharpness (softening on the negative side) (2026-10-30).
- Denoise: luminance and color noise reduction, applied to the original before every other
  adjustment. A RAW is denoised by Apple's RAW engine, which knows the camera and the
  sensitivity of the shot, and its sliders start where that engine sets them for the photo;
  other photos (JPEG, HEIC) are smoothed in their colors, in their grain, or both. Copied,
  pasted and saved in presets with the other adjustments (2026-11-19).
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
- LUT: looks from `.cube` files (3D LUTs, the format of DaVinci Resolve and Adobe), with their
  own switch and an intensity slider. Open the menu and move over the names, with the pointer or
  the arrow keys: the photo shows each look at full size before one is chosen. Imported files
  are copied into the app's library and stay available for every photo; they can be deleted
  from the same place, or added by hand to the folder the library shows in the Finder. Works
  inside masks, comes after black and white (a LUT can tone it) and before grain and vignette;
  a photo whose LUT was deleted says so and shows without it (2026-11-16).
- Dehaze: removes atmospheric haze estimated from the photo itself (dark channel prior), or adds
  some with negative values; works inside masks like every adjustment (2026-10-30).

### Crop and straighten
- Crop frame with corner and edge handles, thirds grid, free or locked aspect ratio (original,
  square, 3:2, 4:3, 16:9, 5:4) (2026-10-30).
- Aspect ratios of your own: New Ratio… in the Aspect menu takes a width and a height (7:5,
  2.39:1, 2:3 for an upright frame) and, if you like, a name ("A4"), locks the crop to it and
  keeps it in the menu for every photo; Remove Ratio takes one out of the menu without changing any photo (2026-11-22).
- Straighten from -45° to +45° with automatic trimming of empty corners; rotate by quarter
  turns; flip horizontally (2026-10-30).
- Image › Rotate Left (⌘L), Rotate Right (⌘R), Flip Horizontal and Flip Vertical: on the photo
  open in the editor, or on every selected photo of the grid without opening them. The photo
  turns or mirrors as it is seen, its crop frame, its straightening and a locked aspect ratio
  with it; adjustments are kept; undoable. The crop tool has a Flip Vertical button too
  (2026-11-22).
- Rotate Left button in the toolbar, in the editor and above the grid, where it turns every
  selected photo (2026-11-22).

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

## Settings
- A Settings window (Qaama › Settings…), with a first option: show a card or a camera in the
  window as soon as it is plugged in, on by default; a phone is never opened by itself
  (2026-11-20).
- Appearance: System, Light or Dark for the whole app, menus, panels, alerts and maps included,
  whatever macOS uses (2026-11-20).

## Platform
- Native macOS app (macOS 27), SwiftUI, Core Image on Metal, sandboxed (2026-10-29).
- English interface, ready for localization (2026-10-29).
- A neutral gray accent instead of the system's blue, so the interface stays quiet next to the
  photos; an accent color chosen in System Settings still wins (2026-11-16).
- The sidebar and the inspector are the system's floating panels on either side of the content;
  their toolbar toggles show whether each is there (2026-11-16).
