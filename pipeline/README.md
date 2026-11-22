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

## Supplemental IS-A anatomy

After rebuilding the PART-OF base, build the 408 supplemental heart and vascular
structures from the separately sourced **BodyParts3D 4.0 IS-A** 99%-reduced
OBJ files. The exact mirror commit and SHA-256 of each OBJ are pinned in
`additional_parts.json`; a mismatch or missing file stops the build. For example:

```bash
curl -fL https://codeload.github.com/jixiangying/anatomy/tar.gz/be67a977abe25a36f59793fda86a506618fd4d27 -o anatomy.tar.gz
tar xzf anatomy.tar.gz
python3 pipeline/build_additional.py anatomy-be67a977abe25a36f59793fda86a506618fd4d27/isa_BP3D_4.0_obj_99
python3 tests/validate_assets.py
```

Run those commands from the project root, after `build.py`. The base build
excludes supplemental IDs, so rebuilding doesn't duplicate them. The second
step updates `parts.json` and writes `additional_circulatory[_lod1,_lod2].glb`
(the three default-visible structures) and `extended_circulatory[_lod1,_lod2].glb`
(the 405 optional vessels), without changing the base, context or tour assets.
The supplemental build uses the base catalogue's rounded centre; this can
introduce sub-millimetre alignment differences from the original frame.

IS-A and PART-OF are different source hierarchies; no PART-OF lineage is claimed
for supplemental parts, and surfaces may overlap or duplicate larger composite
structures. Classification is name-based, not an exhaustive clinical ontology.
The original source meshes and derived assets are under CC BY-SA 2.1 Japan; see
`ATTRIBUTION.txt`.

## Regional view assets

After the base and supplemental builds, run `python3 pipeline/build_regions.py`
from the project root. It partitions the shipped Performance GLBs into separate
base and optional-extra GLBs for torso, lower body, head and heart, and writes
`data/regions.json` with per-view bounds and triangle counts. `tests/validate_assets.py`
checks these files. Regional builds currently only provide Performance detail,
matching the app's lowest-only lock; rebuild additional detail levels and adapt
the loader before lifting that lock for regional views.

Coordinates are body-centred centimetres. Waist down is clipped at Y=18;
head and neck at Y=56; torso is clipped between those heights and to X=±13.5,
with named arm and shoulder vessels excluded. Cross-boundary triangles are
clipped, not capped, and structures can occur in multiple regions. The cuts and
name exclusions are approximate and can trim peripheral torso structures. The
heart view contains heart parts, coronary vessels, pulmonary trunk and ascending
aorta. Regional views omit context and the full-body tour data at runtime.
