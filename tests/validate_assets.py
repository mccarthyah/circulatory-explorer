#!/usr/bin/env python3
"""Check that every catalogued anatomy part exists at every detail level."""
import json
from functools import lru_cache
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
SHOULDER = {
    "FJ3479": ("Left subclavian artery", "artery"),
    "FJ3579": ("Right subclavian artery", "artery"),
    "FJ3486": ("Left subclavian vein", "vein"),
    "FJ3587": ("Right subclavian vein", "vein"),
    "FJ2216": ("Left axillary artery", "artery"),
    "FJ2268": ("Right axillary artery", "artery"),
    "FJ2217": ("Left axillary vein", "vein"),
    "FJ2269": ("Right axillary vein", "vein"),
}
for fid, (name, group) in SHOULDER.items():
    assert by_id[fid]["name"] == name and by_id[fid]["group"] == group
    assert not by_id[fid].get("extended", False), f"{fid} should load by default"

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


comparison = json.loads((DATA / "comparison_z_organs.json").read_text())["parts"]
comparison_glb = read_glb(DATA / "comparison_z_organs.glb")
comparison_ids = {entry["id"] for entry in comparison}
assert len(comparison) == 17 and len(comparison_ids) == 17
assert not comparison_ids & set(by_id)
assert comparison_ids == {n["name"] for n in comparison_glb["nodes"] if "mesh" in n}
for entry in comparison:
    node = next(n for n in comparison_glb["nodes"] if n["name"] == entry["id"])
    prim = comparison_glb["meshes"][node["mesh"]]["primitives"][0]
    assert comparison_glb["accessors"][prim["indices"]]["count"] // 3 == entry["tris"]
    pos = comparison_glb["accessors"][prim["attributes"]["POSITION"]]
    for expected, actual in zip(entry["min"] + entry["max"], pos["min"] + pos["max"]):
        assert abs(expected - actual) < 0.001, entry["id"]
print("PASS: comparison layer contains 17 independently catalogued organs")
hra = json.loads((DATA / "comparison_hra_heart.json").read_text())["parts"]
hra_glb = read_glb(DATA / "comparison_hra_heart.glb")
hra_ids = {entry["id"] for entry in hra}
assert len(hra) == len(hra_ids) == 14 and not hra_ids & (comparison_ids | set(by_id))
assert hra_ids == {n["name"] for n in hra_glb["nodes"] if "mesh" in n}
for entry in hra:
    node = next(n for n in hra_glb["nodes"] if n["name"] == entry["id"])
    prim = hra_glb["meshes"][node["mesh"]]["primitives"][0]
    assert hra_glb["accessors"][prim["indices"]]["count"] // 3 == entry["tris"]
    pos = hra_glb["accessors"][prim["attributes"]["POSITION"]]
    for expected, actual in zip(entry["min"] + entry["max"], pos["min"] + pos["max"]):
        assert abs(expected - actual) < 0.001, entry["id"]
print("PASS: HRA comparison layer contains 14 independently catalogued heart structures")


@lru_cache(maxsize=None)
def glb_binary(path):
    raw = path.read_bytes()
    length = struct.unpack_from("<I", raw, 12)[0]
    return json.loads(raw[20:20 + length]), raw, 20 + length + 8


def mesh_triangles(path, fid):
    glb, raw, binary_offset = glb_binary(path)
    node = next(n for n in glb['nodes'] if n['name'] == fid)
    prim = glb['meshes'][node['mesh']]['primitives'][0]
    def data(accessor_id):
        accessor = glb['accessors'][accessor_id]
        view = glb['bufferViews'][accessor['bufferView']]
        start = binary_offset + view.get('byteOffset', 0) + accessor.get('byteOffset', 0)
        formats = {5126: 'f', 5123: 'H', 5125: 'I'}
        width = {'SCALAR': 1, 'VEC3': 3}[accessor['type']]
        fmt = '<' + formats[accessor['componentType']] * width
        size = struct.calcsize(fmt)
        return list(struct.iter_unpack(fmt, raw[start:start + size * accessor['count']]))
    vertices = data(prim['attributes']['POSITION'])
    indices = [item[0] for item in data(prim['indices'])]
    return sorted((vertices[indices[i]], vertices[indices[i+1]], vertices[indices[i+2]])
                  for i in range(0, len(indices), 3))


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
                    if fid in SHOULDER:
                        assert glb['accessors'][prim['indices']]['count'] // 3 == by_id[fid][count_key], f'{fid} was clipped'
                        # The complete shoulder mesh must retain its source bounds at every LOD.
                        source_name = 'additional_circulatory' if by_id[fid].get('supplemental') else 'circulatory'
                        source = read_glb(DATA / f'{source_name}{suffix}.glb')
                        source_node = next(n for n in source['nodes'] if n['name'] == fid)
                        source_prim = source['meshes'][source_node['mesh']]['primitives'][0]
                        source_pos = source['accessors'][source_prim['attributes']['POSITION']]
                        assert all(abs(a-b) < eps for a,b in zip(lo, source_pos['min']))
                        assert all(abs(a-b) < eps for a,b in zip(hi, source_pos['max']))
                        assert mesh_triangles(path, fid) == mesh_triangles(DATA / f'{source_name}{suffix}.glb', fid), f'{fid} torso geometry differs from source mesh'
                    else:
                        assert lo[1] >= 18-eps and hi[1] <= 56+eps and lo[0] >= -13.5-eps and hi[0] <= 13.5+eps
                        assert not re.search(r'\b(axillary|brachial|humeral|radial|ulnar|palmar|interosseous|subscapular)\b|^(acromial|deltoid) branch', by_id[fid]['name'], re.I)
                if region == 'lower': assert hi[1] <= 18+eps
                if region == 'head': assert lo[1] >= 56-eps
                if region == 'heart': assert by_id[fid]['group'] == 'heart' or by_id[fid]['coronary'] or fid in ('FJ2966','FJ3413')
                if region == 'cardiac':
                    part = by_id[fid]
                    assert fid in SHOULDER or part['group'] == 'heart' or part['coronary'] or part['circuit'] == 'pulmonary' or re.search(r'^(ascending aorta|arch of aorta|inferior vena cava|superior vena cava|(left|right) brachiocephalic vein)$', part['name'], re.I)
                    if fid in SHOULDER:
                        source_name = 'additional_circulatory' if part.get('supplemental') else 'circulatory'
                        assert mesh_triangles(path, fid) == mesh_triangles(DATA / f'{source_name}{suffix}.glb', fid), f'{fid} cardiac geometry differs from source mesh'
        assert seen == set(entries), f'{region}{suffix} catalogue and meshes differ'
        print(f'PASS: {region}{suffix or " high"}: {len(seen)} regional meshes')
assert 'FJ2655' in regions['heart'] and 'FJ2428' in regions['heart']
assert 'FJ2143' in regions['lower'] and 'FJ2143' not in regions['heart']
assert SHOULDER.keys() <= regions['torso'].keys(), 'torso missing major shoulder vessels'
assert SHOULDER.keys() <= regions['cardiac'].keys(), 'cardiac missing major shoulder vessels'
assert 'FJ2271' not in regions['torso']
for fid in ('FJ2655','FJ2428','FJ2966','FJ2924','FJ2925','FJ3645','FJ3441','FJ3413','FJ3411','FJ2725'):
    assert fid in regions['cardiac'], f'cardiac is missing {fid}'
assert 'FJ2143' not in regions['cardiac']
