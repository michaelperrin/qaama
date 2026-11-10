# Healing brush feasibility test

Command-line prototype written on 9 November 2026 to check whether a healing brush (paint over an
object, it disappears) can be built without a machine learning model. Not part of the app.

Two methods, run side by side on the same painted region:

1. **Source heal.** One area of the same shape is copied in from elsewhere: the translation whose
   surroundings look most like the hole's, searched coarse to fine. A smooth correction (a
   membrane, as in Poisson cloning) is added so color and light meet the hole's edge.
2. **Patch fill.** The hole is rebuilt from 7 × 7 patches of its surroundings, from a blurry
   version up to full size (Wexler, Shechtman and Irani, 2007): every patch touching the hole
   looks for the most similar patch outside it, then every hole pixel becomes the weighted average
   of what the patches covering it propose; the last pass keeps the best proposal only, so
   texture and grain stay sharp.

## Patents

The patch search is exhaustive at the coarsest scale, then local: around the match inherited from
the scale above, plus the matches of the four neighbors shifted by one (coherence, Ashikhmin
2001). It deliberately has no randomized search: PatchMatch (Barnes et al., 2009) is covered by
Adobe's US 8,285,055, filed in February 2009, so nominally in force until about 2029. Exemplar-based
inpainting (Criminisi et al., Microsoft, US 6,987,520) was filed in 2003 and should have expired
around 2023. Neither status has been checked with the patent office: do that before shipping.

## Build and run

```sh
swiftc -O -o heal main.swift
./heal samples <dir>                      # six synthetic scenes: <name>.png, -mask.png, -truth.png
./heal fill <image> <out dir> --mask <png> [--truth <png>] [--reach 4] [--texture 0]
./heal fill <image> <out dir> --dab 0.52,0.40,0.03 --stroke 0.1,0.2,0.6,0.25,0.01
```

`--dab x,y,r` and `--stroke x1,y1,x2,y2,r` paint the region as the app's brush would: positions
as fractions of the width and height from the top left, radius as a fraction of the long edge.
`--reach` is how far around the hole material is taken from, in hole thicknesses. `--texture`
is the weight of texture features in the patch comparison (0, the default, compares colors only).
Writes `<name>-mask.png` (the painted region in red), `<name>-source.png`, `<name>-patch.png` and
`<name>-sheet.png` (the area around the hole: original, mask, source heal, patch fill, truth when
given).

## Measured on an Apple Silicon Mac, 9 November 2026

Synthetic scenes, 1200 × 900, with sensor-like grain. Times include every scale; the work happens
in the hole's surroundings only (its bounds plus four times its thickness, 48 to 600 px).

| Scene | Hole | Source heal | Patch fill |
|---|---|---|---|
| Bird on a cloudy sky | 113 × 57 | 21 ms, clean | 22 ms, clean, a faint lighter patch |
| Wire across the sky | 1200 × 143 (16 px thick) | no room for the shape | 42 ms, clean |
| Ball on grass | 149 × 157 | 131 ms, clean, slightly darker spot | 62 ms, clean, faint outline |
| Sign on a brick wall with a light gradient | 177 × 127 | 142 ms, bricks aligned | 44 ms, bricks aligned |
| Boat across the horizon | 139 × 149 | 38 ms, **blurry ghost** | 77 ms, horizon rebuilt straight |
| Towel on rippled sand | 341 × 261 | no room for the shape | 104 ms, ripples continued |

The same scenes enlarged to 4800 × 3600 (17 Mpx), for the timing only: patch fill takes 380 ms
for a wire across the whole image, 390 ms for a 600 px ball and 1.1 s for a 1364 × 1044 towel;
source heal takes 6 s on the ball (its membrane solver is naive) and still has no room for the
other two.

## Real photos, 10 November 2026

Three photos from the maintainer (1280 px wide, not in the repository), regions painted by hand
with `--dab` and `--stroke`. Source heal only ran on the boat; the other regions have no twin.

| Photo | Region | Patch fill |
|---|---|---|
| Blue boat on calm water, with its reflection | 223 × 70 | 71 ms. Clean: water and ripples continue, a faint pale streak. Source heal copies seaweed in. |
| Utility poles and seven cables against a blue sky, pole foot in front of a fence and trees | 598 × 598, 24 px thick | 135 ms. Sky clean apart from faint streaks along the cables. At the pole's foot the fence and trees are plausible, but the barbed wire is interrupted and a fragment of fence post lands in the sky. |
| Snail on green gravel seen in perspective | 584 × 330 | 109 ms. The snail is gone but the fill shows: gravel of the wrong size (taken from nearer the camera, where the stones look bigger) and a darker area with a visible edge. |

Lessons:

- The mask must cover the whole object. Each miss (the snail's neck, a cable a few pixels off)
  was copied back into the fill as if it were background. The brush should grow its region by a
  few pixels, and painting again over a leftover must be cheap.
- Perspective is the first real limit: a texture whose scale changes across the frame has no
  patch of the right size at the right place. Shrinking the search area (`--reach`) did not help
  on the snail. Patches would need to be compared at several scales, or a model used.
- Thin regions (cables, poles) are the best case, even with a detailed background behind.
- Where a pole stood in front of a bare tree or a roof, the fill is a band of plain sky, not
  branches (the maintainer's first remark). Compared on colors, misaligned branches are further
  from each other than from sky. Texture features in the comparison (mean absolute gradient
  around each pixel, after Newson et al., 2017; `--texture 50` and `200`) were tried against
  this and did not help: the band stays at 50, and at 200 pieces of grass and a whole tree land
  in the sky. Continuing a one-of-a-kind structure is beyond patches; that is a model's job.

## Findings

- **Patch fill is the method to build on.** It handled all six scenes, including the ones a
  single source can't: a region crossing two materials, a long stroke, a hole too large to have
  a twin elsewhere. It is fast enough to run when the stroke is released.
- Source heal is only safe for small spots on a uniform surface, which patch fill does as well.
  What is worth keeping from it is the membrane, as a finishing step: patch fill leaves a faint
  outline where the grass or the sky drifts in brightness, and a thin correction along the edge
  would remove it.
- These scenes are favorable: their textures are the same everywhere. Real photos have
  perspective, lighting gradients and one-of-a-kind structures (a face, a window, a horizon with
  a coastline); expect repeated fragments and bent lines there, more so as the hole grows. That
  is where a model (LaMa, Apache 2.0) would take over. The real photos above confirm it.
- Not explored: soft brush edges, several strokes interacting, a hole at the image's border with
  nothing known on one side, working in linear light rather than display values.
