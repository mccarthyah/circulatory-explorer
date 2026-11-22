# Data pipeline: BodyParts3D → glTF

```bash
mkdir -p ~/bp3d_raw && cd ~/bp3d_raw
curl -O https://dbarchive.biosciencedbc.jp/data/bodyparts3d/LATEST/partof_BP3D_4.0_obj_99.zip
unzip partof_BP3D_4.0_obj_99.zip -d extracted
curl -O https://dbarchive.biosciencedbc.jp/data/bodyparts3d/LATEST/partof_inclusion_relation_list.txt

cd <this folder>
python3 -m pip install numpy trimesh fast_simplification
python3 index_parts.py      # -> index.json (OBJ headers: FMA id, name, bounds)
python3 build.py            # -> ../data/{circulatory,context}[_lod1,_lod2].glb,
                            #    parts.json, tour.json, ATTRIBUTION.txt
```

Set `BP3D_ROOT` if the raw download lives somewhere else (default `~/bp3d_raw`).

Three detail levels come out of the same run: the full-resolution meshes plus two
quadric-decimation passes (`fast_simplification.simplify`, aggressiveness 7, a
floor of 12 triangles per part) that keep 45 % and 18 % of the vessel triangles
and 40 % / 14 % of the ghost-organ ones — 812,802 → 365,040 → 145,588 triangles
for the vessels. `parts.json` records `tris`, `tris_lod1` and `tris_lod2` for
every part so the app can show the cost of the level you are on.

`build.py` holds the interesting bits: the name-based classifier
(`classify()`), the ghost-organ selection (`CONTEXT_PATTERNS`), the tour
stations and their captions (`TOUR`), and the medial-line extraction that turns
vessel meshes into the fly-through spline (`build_tour()`).
