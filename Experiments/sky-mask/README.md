# Sky mask feasibility test

Command-line prototype written on 29 October 2026 to check whether a "sky" smart mask can be
built from public, legally usable components. Not part of the app.

Two approaches, run side by side on each image:

1. **Apple's DETR semantic segmentation Core ML model** (`apple/coreml-detr-semantic-segmentation`
   on Hugging Face, Apache 2.0, 85 MB). COCO panoptic classes, including `sky (other)`.
   Automatic, but the mask is computed at 448 × 448 and upscaled, so edges are coarse.
2. **Vision `GenerateIterativeSegmentationRequest`** (macOS 27). Seeded with a point, a rectangle or
   a scribble; fine edges; assets downloaded by the system on first use. Not sky-specific.

The promising combination: DETR finds the sky, its mask becomes the scribble seed of the Vision
request, which refines the edges.

## Build and run

```sh
curl -L -o /tmp/detr/Manifest.json https://huggingface.co/apple/coreml-detr-semantic-segmentation/resolve/main/DETRResnet50SemanticSegmentationF16.mlpackage/Manifest.json
# …plus Data/com.apple.CoreML/model.mlmodel and Data/com.apple.CoreML/weights/weight.bin, same layout
xcrun coremlcompiler compile /tmp/detr/DETRResnet50SemanticSegmentationF16.mlpackage .
swiftc -O -o skymask main.swift -framework CoreML -framework Vision -framework CoreImage
./skymask DETRResnet50SemanticSegmentationF16.mlmodelc <out dir> <image>…
```

Writes `<name>-detr-mask.png`, `<name>-detr-overlay.png` and `<name>-click-overlay.png`.

## Measured on an Apple Silicon Mac, 29 October 2026

| Step | First call | Then |
|---|---|---|
| DETR model load | 3.5 s | — |
| DETR inference (any size, resized to 448²) | 2.3 s | 70–110 ms |
| Vision click segmentation, 2 Mpx | 3.9 s (asset download) | ~80 ms |
| Vision click segmentation, 26 Mpx | — | 130–200 ms |
