"""Build the supplemental BodyParts3D 4.0 is_a circulatory meshes.

Usage: python3 pipeline/build_additional.py /path/to/isa_BP3D_4.0_obj_99
The tracked manifest pins each source mesh by SHA-256. Existing base GLBs and
path data are never overwritten; rerunning replaces only the supplemental GLBs
and their catalogue entries. Run build.py first if rebuilding the base dataset.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile

import numpy as np

from bp3d_lib import Frame, GLB, load_obj, vertex_normals
from build import DATA, DETAILS, MATERIALS, classify, simplify

HERE = Path(__file__).resolve().parent
MANIFEST = HERE / "additional_parts.json"
# These fill important gaps in the base model and are visible by default.
CORE = {"FJ2655", "FJ2966", "FJ2428"}


def build(source: Path) -> None:
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    data_path = Path(DATA)
    catalogue_path = data_path / "parts.json"
    data = json.loads(catalogue_path.read_text(encoding="utf-8"))
    base = [p for p in data["parts"] if not p.get("supplemental", False)]
    base_ids = {p["id"] for p in base}
    if len(base_ids) != len(base):
        raise ValueError("Duplicate ids in base catalogue")
    frame = Frame(data["centre_mm"])
    glbs = {}
    for suffix, _, _ in DETAILS:
        for category in ("additional_circulatory", "extended_circulatory"):
            glb = GLB()
            for key, (col, rough, metal, alpha) in MATERIALS.items():
                glb.add_material(key, col, rough, metal, alpha)
            glbs[(category, suffix)] = glb

    added = []
    for rec in manifest["parts"]:
        fid = rec["id"]
        path = source / (fid + ".obj")
        if not path.is_file():
            raise FileNotFoundError(f"Missing source mesh: {path}")
        if hashlib.sha256(path.read_bytes()).hexdigest() != rec["sha256"]:
            raise ValueError(f"Source mesh checksum mismatch: {path}")
        # A newer base export might already contain a part from the manifest.
        if fid in base_ids:
            continue
        cls = classify(rec["name"])
        if cls is None:
            raise ValueError(f"Cannot classify {fid}: {rec['name']}")
        group, material, circuit, coronary = cls
        vertices, faces = load_obj(str(path))
        pos = frame.apply(vertices).astype(np.float32)
        level_tris = {}
        for suffix, ratio, _ in DETAILS:
            if suffix:
                p, f = simplify(pos.astype(np.float64), faces, ratio)
                p = p.astype(np.float32)
            else:
                p, f = pos, faces
            if len(f) == 0:
                raise ValueError(f"Empty mesh for {fid} at {suffix or 'high'}")
            normals = vertex_normals(p.astype(np.float64), f)
            category = "additional_circulatory" if fid in CORE else "extended_circulatory"
            glbs[(category, suffix)].add_part(fid, p, normals, f, material, extras={
                "fma": rec["fma"], "name": rec["name"], "group": group,
            })
            level_tris[suffix] = int(len(f))
        # Slight padding avoids rounding the picking bounds inside the surface.
        lo = pos.min(axis=0) - 0.002
        hi = pos.max(axis=0) + 0.002
        added.append({
            "id": fid, "fma": rec["fma"], "name": rec["name"],
            "group": group, "material": material, "circuit": circuit,
            "coronary": coronary, "supplemental": True, "extended": fid not in CORE,
            "tris": level_tris[""], "tris_lod1": level_tris["_lod1"],
            "tris_lod2": level_tris["_lod2"], "verts": int(len(pos)),
            "centre": [round(float(v), 3) for v in pos.mean(axis=0)],
            "min": [round(float(v), 4) for v in lo],
            "max": [round(float(v), 4) for v in hi],
            # The is_a source has a different hierarchy; don't invent a PART-OF lineage.
            "lineage": [],
        })

    data["parts"] = base + added
    data["supplemental_source"] = (
        "BodyParts3D 4.0 IS-A 99% polygon reduction; see ATTRIBUTION.txt; "
        "manifest pipeline/additional_parts.json"
    )
    with tempfile.TemporaryDirectory(prefix="anatomy-extra-", dir=data_path) as tmp:
        staging = Path(tmp)
        for suffix, _, _ in DETAILS:
            for category in ("additional_circulatory", "extended_circulatory"):
                out = staging / f"{category}{suffix}.glb"
                glbs[(category, suffix)].write(str(out))
        (staging / "parts.json").write_text(json.dumps(data, indent=1) + "\n", encoding="utf-8")
        for suffix, _, _ in DETAILS:
            for category in ("additional_circulatory", "extended_circulatory"):
                filename = f"{category}{suffix}.glb"
                os.replace(staging / filename, data_path / filename)
        os.replace(staging / "parts.json", catalogue_path)
    print(f"Added {len(added)} structures ({sum(not p['extended'] for p in added)} core); "
          f"additional triangles high/balanced/performance: "
          f"{sum(p['tris'] for p in added)}/"
          f"{sum(p['tris_lod1'] for p in added)}/"
          f"{sum(p['tris_lod2'] for p in added)}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="directory containing 4.0 is_a OBJ files")
    build(parser.parse_args().source)
