#!/usr/bin/env python3
"""Check that every catalogued anatomy part exists at every detail level."""
import json
import re
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
manifest = json.loads((ROOT / "pipeline" / "additional_parts.json").read_text())
parts = json.loads((DATA / "parts.json").read_text())["parts"]
by_id = {p["id"]: p for p in parts}
assert len(by_id) == len(parts), "duplicate catalogue ID"
manifest_ids = {p["id"] for p in manifest["parts"]}
assert len(manifest_ids) == len(manifest["parts"]), "duplicate supplemental ID"
assert manifest_ids == {p["id"] for p in parts if p.get("supplemental")}, "supplemental manifest differs from catalogue"
for fid, name, group in [("FJ2655", "Coronary sinus", "vein"),
                         ("FJ2966", "Pulmonary trunk", "artery"),
                         ("FJ2428", "Wall of ventricle", "heart")]:
    assert by_id[fid]["name"] == name and by_id[fid]["group"] == group
    assert not by_id[fid].get("extended", False), f"{fid} should load by default"


def read_glb(path):
    raw = path.read_bytes()
    magic, version, length = struct.unpack_from("<4sII", raw)
    assert magic == b"glTF" and version == 2 and length == len(raw), path
    chunk_len, chunk_type = struct.unpack_from("<I4s", raw, 12)
    assert chunk_type == b"JSON", path
    return json.loads(raw[20:20 + chunk_len])


for suffix, count_key in [("", "tris"), ("_lod1", "tris_lod1"), ("_lod2", "tris_lod2")]:
    ids = set()
    for category in ("circulatory", "context", "additional_circulatory", "extended_circulatory"):
        path = DATA / f"{category}{suffix}.glb"
        glb = read_glb(path)
        for node in glb["nodes"]:
            if "mesh" not in node:
                continue
            fid = node["name"]
            assert fid in by_id and fid not in ids, f"unknown or duplicate {fid} in {path}"
            ids.add(fid)
            if category == "extended_circulatory":
                assert by_id[fid].get("extended", False), fid
            if category == "additional_circulatory":
                assert by_id[fid].get("supplemental") and not by_id[fid].get("extended", False), fid
            primitives = glb["meshes"][node["mesh"]]["primitives"]
            tris = sum(glb["accessors"][p["indices"]]["count"] // 3 for p in primitives)
            assert tris == by_id[fid][count_key], f"triangle count mismatch for {fid} in {path}"
    assert ids == set(by_id), f"missing IDs in {suffix or 'high'}: {set(by_id) - ids}"
    print(f"PASS: {suffix or 'high'}: {len(ids)} catalogued meshes")

# Regional files are independent at every detail; validate membership, cuts,
# bounds and per-level triangle counts against each shipped GLB.
regions = json.loads((DATA / 'regions.json').read_text())
assert set(regions) == {'torso', 'lower', 'head', 'heart', 'cardiac'}
for region, entries in regions.items():
    for suffix, count_key in [('', 'tris'), ('_lod1', 'tris_lod1'), ('_lod2', 'tris_lod2')]:
        seen = set()
        for extra in (False, True):
            path = DATA / f'region_{region}{"_extended" if extra else ""}{suffix}.glb'
            glb = read_glb(path)
            for node in glb['nodes']:
                fid = node['name']
                assert fid in entries and fid not in seen
                assert bool(by_id[fid].get('extended', False)) == extra
                assert by_id[fid]['group'] != 'context'
                seen.add(fid)
                prim = glb['meshes'][node['mesh']]['primitives'][0]
                assert glb['accessors'][prim['indices']]['count'] // 3 == entries[fid][count_key]
                pos = glb['accessors'][prim['attributes']['POSITION']]
                lo, hi = pos['min'], pos['max']
                eps = 0.0001
                assert all(a >= b - eps for a,b in zip(lo, entries[fid]['min']))
                assert all(a <= b + eps for a,b in zip(hi, entries[fid]['max']))
                if region == 'torso':
                    assert lo[1] >= 18-eps and hi[1] <= 56+eps and lo[0] >= -13.5-eps and hi[0] <= 13.5+eps
                    assert not re.search(r'\b(axillary|brachial|humeral|radial|ulnar|palmar|interosseous|subscapular)\b|^(acromial|deltoid) branch', by_id[fid]['name'], re.I)
                if region == 'lower': assert hi[1] <= 18+eps
                if region == 'head': assert lo[1] >= 56-eps
                if region == 'heart': assert by_id[fid]['group'] == 'heart' or by_id[fid]['coronary'] or fid in ('FJ2966','FJ3413')
                if region == 'cardiac':
                    part = by_id[fid]
                    assert part['group'] == 'heart' or part['coronary'] or part['circuit'] == 'pulmonary' or re.search(r'^(ascending aorta|arch of aorta|inferior vena cava|superior vena cava|(left|right) brachiocephalic vein)$', part['name'], re.I)
        assert seen == set(entries), f'{region}{suffix} catalogue and meshes differ'
        print(f'PASS: {region}{suffix or " high"}: {len(seen)} regional meshes')
assert 'FJ2655' in regions['heart'] and 'FJ2428' in regions['heart']
assert 'FJ2143' in regions['lower'] and 'FJ2143' not in regions['heart']
assert 'FJ2271' not in regions['torso']
for fid in ('FJ2655','FJ2428','FJ2966','FJ2924','FJ2925','FJ3645','FJ3441','FJ3413','FJ3411','FJ2725'):
    assert fid in regions['cardiac'], f'cardiac is missing {fid}'
assert 'FJ2143' not in regions['cardiac']
