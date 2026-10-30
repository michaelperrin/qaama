# Bundled Core ML models

## DETRResnet50SemanticSegmentationF16

Semantic segmentation (COCO panoptic classes, including `sky (other)`, `grass`, `road`, `sea`…),
published by Apple on Hugging Face as `apple/coreml-detr-semantic-segmentation`, Apache License 2.0.
Qaama uses it for the Sky and Scene masks; Vision's iterative segmentation refines its edges.
Input: 448 × 448 BGRA image. Output `semanticPredictions`: 448 × 448 class indices; the class
labels are in the model's metadata.
