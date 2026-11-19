# SD card import feasibility test

Command-line prototype written on 19 November 2026 to check whether Qaama, which is sandboxed, can
list an SD card, show its thumbnails, copy and delete its files with ImageCaptureCore. Not part of
the app.

## Build and run

```sh
./build.sh usb                                   # open | sandbox | usb | qaama: the entitlements to sign with
build/usb/CardImportProbe.app/Contents/MacOS/CardImportProbe --thumbnails 40
build/open/CardImportProbe.app/Contents/MacOS/CardImportProbe --direct /Volumes/CARD   # adds ImageIO straight from the volume
build/usb/CardImportProbe.app/Contents/MacOS/CardImportProbe --delete QAMA0001.JPG     # deletes that one file, nothing else
build/open/CardImportProbe.app/Contents/MacOS/CardImportProbe --device EOS_DIGITAL --listing [--chronological]   # only the listing
```

Pass `--device <name>` whenever something else is plugged in: without it the probe opens the first
device announced, which may be a phone.

The probe takes the first camera device announced, waits for its complete catalog, then reads: it
writes nothing to the card unless `--delete` names a file, and then only deletes if exactly one
file has that name. Each sandboxed variant leaves an empty container in `~/Library/Containers`
(`fr.michaelperrin.qaama.experiments.card-import.*`), safe to remove.

## Results

Measured on a 16 GB FAT32 card in the built-in reader, holding 1,154 JPEG, 77 CR2, 2 RAF, 23 MOV
and 9 THM files (5 to 13 MB per JPEG, about 23 MB/s read speed), macOS 27.2.

### Entitlements

| Signed with | Card announced |
| --- | --- |
| No sandbox | yes |
| App Sandbox alone | no, nothing in 20 s |
| Qaama's entitlements today | no |
| App Sandbox + `com.apple.security.device.usb` | yes, and every test below passes |

Nothing else was needed: no permission question stopped the probe.

### What the device gives

- **Catalog**: the first items arrive after 0.4 s, one per callback; the 1,256 files are complete
  after 20 to 25 s. Types are only `public.image` and `public.movie`; `isRaw` is right (79).
  The THM and ZIP files are not listed.
- **Progress**: `contentCatalogPercentCompleted` counts in whole percents and tells the total
  early: 100 files at 8 %, so about 1,250 (1,256 in the end). It runs a few dozen files ahead of
  those handed over, so the figure is far too low in the first second. Opening the session with
  `ICEnumerationChronologicalOrder` neither delivers the files by date on this card nor changes
  the time (13 to 21 s with or without, from one run to the next).
- **No path**: `mountPoint` and `fileSystemPath` are nil, sandboxed or not. In the sandbox, listing
  `/Volumes/<card>` returns nothing. Everything goes through the device.
- **Names**: a test file named `QAAMATST.JPG` in `DCIM/100CANON` was not listed; renamed
  `QAMA0001.JPG` (four characters, four digits, as cameras name files) it was. Not checked further.
- **Thumbnails** (`requestThumbnailData`): 650 ms each, the same for the default size (160 px), for
  400 px, and for 40 requests sent at once (598 ms each: they are served one by one). The time is
  that of reading the whole file: once a file has been read, 1024 to 4096 px come in 50 to 250 ms.
  A screen of 40 thumbnails takes 25 s; the whole card would take over 13 minutes.
- **Embedded thumbnails** (`requestReadData` of the first 128 kB, then ImageIO): 82 ms each cold
  (40 in 3.3 s), 8 ms once cached, 160 × 120 px. Only tried on JPEG files.
- **Large previews**: 1024, 2048 and 4096 px thumbnails are served for JPEG and RAF
  (4096 × 2731 for both), 0.4 to 0.8 s the first time. No need to download for a preview.
- **Download**: a 28.6 MB RAF in 1.27 s into the container's temporary folder, size checked.
- **Delete** (`requestDeleteFiles`): one file in 3 ms, `ICDeleteSuccessful`, the delegate is told
  (`didRemove`), the file is gone from the card and is not in its `.Trashes` folder.

### For comparison: ImageIO straight from the volume (no sandbox)

What the app would get if the user handed it the card as a folder: 1,154 JPEG files listed in
0.36 s, embedded thumbnails in 10 ms each, 400 px thumbnails decoded from the image in 349 ms each.

## Not tested

RAW + JPEG pairs (none on this card), embedded thumbnails of RAW files, a locked card or file,
ejecting, a card pulled out during a copy, what downloading or deleting a video does to its THM
file (`ICDownloadSidecarFiles` exists), a camera plugged in by USB.
