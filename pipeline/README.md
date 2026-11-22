# Data pipeline: BodyParts3D → glTF

```bash
mkdir -p ~/bp3d_raw && cd ~/bp3d_raw
curl -O https://dbarchive.biosciencedbc.jp/data/bodyparts3d/LATEST/partof_BP3D_4.0_obj_99.zip
unzip partof_BP3D_4.0_obj_99.zip -d extracted
curl -O https://dbarchive.biosciencedbc.jp/data/bodyparts3d/LATEST/partof_inclusion_relation_list.txt

cd <this folder>
python3 -m pip install numpy trimesh fast_simplification
python3 index_parts.py      # -> index.json (OBJ headers: FMA id, name, bounds)
python3 build.py            # -> ../data/{circulatory,context}.glb, parts.json, tour.json
```

Set `BP3D_ROOT` if the raw download lives somewhere else (default `~/bp3d_raw`).

`build.py` holds the interesting bits: the name-based classifier
(`classify()`), the ghost-organ selection (`CONTEXT_PATTERNS`), the tour
stations and their captions (`TOUR`), and the medial-line extraction that turns
vessel meshes into the fly-through spline (`build_tour()`).
