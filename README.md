# Circulatory System Explorer

A Godot 4 app for flying through a real 3D model of the human circulatory system.
Every vessel, valve and chamber comes from **BodyParts3D** (DBCLS, Japan) — no
sculpted stand-ins, no downloaded game assets. There are three ways to move:

| Free flight | Guided tour | Interior voyage |
|---|---|---|
| ![free flight](docs/screenshots/01-free-flight.jpg) | ![guided tour](docs/screenshots/06-guided-tour-leg.jpg) | ![interior](docs/screenshots/07-interior-voyage.jpg) |
| 6-DOF camera, hover/click any structure to inspect it | a cinematic pass along the real blood path, with captions | the same path from inside the lumen, blood cells streaming past |

![heart close-up](docs/screenshots/03-heart-closeup.jpg)
![inspecting](docs/screenshots/04-inspect.jpg)

## Detail levels (this is the frame-rate dial)

The full BodyParts3D meshes are heavy (813 k triangles for the vessels alone),
so the app ships **three decimated mesh sets** and starts on the light one:

| Detail | Vessels | + ghost body | What else changes | Loaded at startup |
|---|---|---|---|---|
| **Performance** *(default)* | 145,588 tris · 3.4 MB | 31,866 tris | no glow / SSAO / SSIL, no mottling, flat-shaded walls, 75 % render scale, hover-picking at 6 Hz; opaque guided-tour surfaces, 110 blood cells, no labels, no ghost body | yes |
| **Balanced** | 365,040 tris · 7.6 MB | 82,872 tris | glow bloom, FXAA, mottling, labels, ghost body, 90 % render scale | on demand |
| **High** | 812,802 tris · 16.3 MB | 159,510 tris | full detail, 4× MSAA | on demand |

Pick it under **GRAPHICS → Detail** in the left panel (or `F9` cycles it); the
choice is remembered in `user://settings.cfg`, and the triangle count of the
current set is printed in the header bar. Switching detail replaces the meshes
without leaving the scene; the time required depends on the machine.

![performance detail](docs/screenshots/09-detail-performance.jpg)
![high detail](docs/screenshots/10-detail-high.jpg)
*Same viewpoint: Performance (145 k tris, no glow/mottle/ghost) and High
(813 k tris, MSAA, mottling, ghost body).*

The interior voyage quietly raises the vessel detail to at least **Balanced**
even when you are on Performance — at 145 k triangles the lumen of a thin artery
loses its radius and the camera pops through the wall. Everything else on the
Performance preset still applies, and the header shows
`balanced (interior) detail` when this happens.

On Performance, the guided tour uses opaque rather than translucent vessels to
reduce overdraw; Balanced and High retain the translucent tour. Changing quality
in the tour updates its opacity.

Other things kept cheap by default: the ghost body starts **off**, depth fog is
only enabled inside the vessels (it is what makes a lumen read as a tunnel),
and pick-probing is throttled to 6 Hz.

## Running it

1. Install **Godot 4.7.2** (the project declares 4.7 features; the
   standard build is fine, no C# needed).
2. Open `project.godot` in the project manager, or from a terminal:
   `godot --path .` (the app also starts without the editor's import cache —
   the glTF files are parsed at runtime in that case).
3. Press **F5**.

The first launch loads the mesh set for the current detail level (3.4 MB of
glTF on the default Performance preset) and builds 687 meshes; you will see
"Loading anatomy…" for a moment.

## Low-end GPUs and virtual machines

Start with **Performance**, keep the body outline and labels off, and use a
smaller window if needed. Under **GRAPHICS → 3D resolution**, try 50% or 65%
for a lower GPU pixel workload; this affects 3D rendering, not the interface.
The setting is remembered independently of detail; choose **Preset default**
to return to the preset scale. The interior voyage still uses Balanced vessel meshes
to preserve the lumen. For a VM, enable its 3D acceleration and install the
guest graphics drivers; some VM configurations provide only software rendering
or do not support the required graphics API.

If Forward Plus fails or is slow, try the Compatibility (OpenGL) renderer:

```bash
godot --path . --rendering-method gl_compatibility
```

This is an alternative to test on your hardware, not a guaranteed speedup or
fallback for unsupported virtual GPUs. Appearance and supported effects may
differ. See `tests/README.md` for repeatable benchmarks and headless tests.

## Controls

| Input | Action |
|---|---|
| `W` `A` `S` `D` | fly forward / strafe (the camera moves toward the crosshair) |
| `Q` / `E` (or `Ctrl` / `Space`) | down / up |
| `Shift` | boost ×3.5 · `Alt` slows down ×0.3 |
| mouse | look — click the window to capture the pointer, `Esc` releases it |
| mouse wheel | change cruise speed (1–400 cm/s) |
| hover | highlights the structure under the crosshair and shows its card |
| right-click | fly to the highlighted structure |
| `1` `2` `3` | free flight / guided tour / interior voyage |
| `Space` | pause · `←` `→` jump between tour stations |
| `B` | toggle the translucent body outline |
| `L` | toggle labels |
| `F9` | cycle detail: Performance → Balanced → High |
| `Tab` | hide the whole interface |
| `R` | reset the camera |

Left panel: search all 636 circulatory parts by name or FMA id, set the opacity
of arteries, veins, the heart and the body context independently, and pick the
detail level.
Clicking a search result flies the camera to that structure.

## What is in the scene

- **636 circulatory parts**: 417 arteries, 197 veins and 22 heart parts
  (atrial walls, valve leaflets and cusps, papillary muscles, chamber casts,
  coronary vessels) — 812,802 triangles at High, 365,040 at Balanced,
  145,588 at Performance.
- **51 ghost context meshes** (skin, gut, kidneys, trachea, brainstem, bones…)
  — 159,510 / 82,872 / 31,866 triangles for the same three levels, drawn at
  5–35 % opacity so you can tell where you are. Toggle with `B`.
- Colour is semantic: arteries red, veins blue, myocardium/atrial wall warm red,
  valve leaflets ivory, chamber casts dark crimson (the whole set is
  oxygen-based colouring, so the pulmonary artery is drawn as an artery).

## How the model was made

`pipeline/` contains the whole data path, reproducible in about 10 seconds:

```
BodyParts3D partof_BP3D_4.0_obj_99.zip   (1258 OBJ meshes, FMA part-of tree)
        │
        ├─ classify parts by anatomical name  → artery / vein / heart / other
        ├─ convert coordinates  (mm, X=left, Y=posterior, Z=superior)
        │                       → Godot (cm, Y up, −Z forward), no mirroring
        ├─ recompute area-weighted smooth vertex normals
        ├─ pack one glTF node per part          → data/circulatory.glb      (16 MB, high)
        ├─ quadric-decimate ×2 (0.45 / 0.18 of the triangles)
        │                                       → data/circulatory_lod1/2.glb (7.6 / 3.4 MB)
        ├─ quadric-decimate the ghost organs    → data/context.glb          (3 MB, high)
        │  … and the same two LOD steps        → data/context_lod1/2.glb   (1.6 / 0.7 MB)
        ├─ join FMA ids + part-of lineage       → data/parts.json
        └─ trace medial lines of 22 key vessels → data/tour.json
```

The tour spline deserves a note: it is not hand-drawn. For each of the 22
stations the pipeline slices the vessel mesh along its principal axis and takes
the centroid of each slice, producing a medial line that runs *inside* the
vessel. The chains are oriented so they join up, concatenated, lightly smoothed
and resampled with a Catmull-Rom spline at runtime. That is why the camera
stays in the lumen all the way from the superior vena cava to the dorsalis
pedis artery and back up the inferior vena cava.

To rebuild:

```bash
cd pipeline
python3 -m pip install numpy trimesh fast_simplification
python3 index_parts.py        # scans the OBJ headers into index.json
python3 build.py              # writes ../data/*
```

`BP3D_ROOT` points at the unzipped download (default `~/bp3d_raw`).

## Implementation notes

- **Runtime glTF loading.** `AnatomyModel` first tries the editor-imported
  PackedScene and falls back to `GLTFDocument` parsing, so the project runs
  equally well from the editor, from a fresh checkout and from an export that
  ships the raw `.glb`.
- **Cutaway sphere.** Flying *through* anatomy normally means staring at the
  inside of a wall. `shaders/vessel_*.gdshader` discard fragments within
  `hole_radius` of the camera: 6.5 cm in the guided tour, 11.5 cm around the
  heart stations (you fly inside a cleared bubble), 1.6 cm in the interior
  voyage (just enough to avoid clipping the near plane). The same shader takes a
  `mottle` weight, so the Performance preset can drop the value-noise tissue
  texture entirely.
- **Interior surfaces are darkened** in the shader when `FRONT_FACING` is false,
  so a lumen reads as a tunnel instead of a light box.
- **Picking** is AABB-prefiltered, then exact Möller–Trumbore against the mesh
  triangles (cached), choosing the nearest hit. Ghost organs and fully
  transparent buckets never block a pick; stationary views reuse the last result.
- **Blood cells** are a `MultiMesh` of ellipsoids that follow the same spline
  (420 / 240 / 110 instances for High / Balanced / Performance), and only the
  visible instances are animated. Their scale is proportional to their distance
  from the lens so they neither fill the screen nor disappear.
- **Money for the frame budget.** The expensive post-processing (glow bloom,
  SSAO, SSIL, adjustment) is switched off as a block by the preset; fog is a
  per-mode decision rather than always-on; and the whole model can be rebuilt at
  a different detail without reloading the scene.
- **Parallel-transported up vector** for the tour camera, so the 40 cm drop down
  the femoral artery never flips the view.

## Known limits of the source data (not bugs)

- The BodyParts3D part-of tree has **no ventricular myocardium** and no lung,
  liver or spleen meshes; the heart is made of atrial walls, valve leaflets,
  chamber casts and coronary vessels. The chamber casts are why the ventricles
  still read as solid shapes.
- Limb **veins** are not segmented (the femoral/popliteal/saphenous veins are
  absent), so the tour rejoins the venous tree at the external iliac vein. The
  caption at that station says so.
- The meshes are the *99 % polygon-reduced* release; up close, walls are
  visibly faceted.
- Some structures exist twice (a mirrored `…M` file for the left side). Both are
  kept so the model stays symmetric; they appear twice in the search list.

## Attribution

The anatomy is from BodyParts3D, © The Database Center for Life Science,
licensed under **CC Attribution-Share Alike 2.1 Japan**.
See `ATTRIBUTION.txt`; the licence requires attribution and share-alike if you
redistribute the models. Reference: Mitsuhashi N. *et al.*, *BodyParts3D: 3D
structure database for anatomical concepts*, Nucleic Acids Res. 2008.

The code in this repository is yours to use freely.
