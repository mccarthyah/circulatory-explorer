"""Partition tracked GLBs into independently loadable, spatially clipped regions.

Run from the repository root after rebuilding the base and supplemental assets:
    python3 pipeline/build_regions.py
Requires numpy. No raw BodyParts3D download is needed.
"""
import json
import re
from pathlib import Path
import struct
import numpy as np
from bp3d_lib import GLB

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / 'data'
REGIONS = ('torso', 'lower', 'head', 'heart', 'cardiac')
DETAILS = (('', 'tris'), ('_lod1', 'tris_lod1'), ('_lod2', 'tris_lod2'))
# Coordinate units are cm, in the body-centred frame. Clip cut faces are open,
# and clipping x on the torso is an intentionally approximate shoulder boundary.
PLANES = {'torso': [(1, 18., 1), (1, 56., -1), (0, -13.5, 1), (0, 13.5, -1)],
          'lower': [(1, 18., -1)], 'head': [(1, 56., 1)], 'heart': [], 'cardiac': []}


def read_glb(path):
    raw = path.read_bytes()
    n = struct.unpack_from('<I', raw, 12)[0]
    obj = json.loads(raw[20:20+n])
    off = 20 + n
    size, typ = struct.unpack_from('<I4s', raw, off)
    assert typ == b'BIN\0'
    return obj, memoryview(raw)[off+8:off+8+size]


def array(g, blob, index):
    a = g['accessors'][index]; v = g['bufferViews'][a['bufferView']]
    dtype = {5126: '<f4', 5123: '<u2', 5125: '<u4'}[a['componentType']]
    width = {'SCALAR': 1, 'VEC3': 3}[a['type']]
    assert 'byteStride' not in v and not a.get('sparse')
    out = np.frombuffer(blob, dtype=dtype, count=a['count'] * width,
                        offset=v.get('byteOffset', 0) + a.get('byteOffset', 0))
    return out.reshape(-1, width) if width > 1 else out


def clip(pos, norm, faces, planes):
    # Keep inside triangles indexed; clip only boundary-crossing triangles.
    pos = pos.astype(np.float32); norm = norm.astype(np.float32)
    faces = faces.astype(np.int64).reshape(-1, 3)
    for axis, threshold, sign in planes:
        distances = (pos[:, axis] - threshold) * sign
        inside = distances[faces] >= 0
        keep = faces[inside.all(axis=1)]
        crossings = faces[inside.any(axis=1) & ~inside.all(axis=1)]
        newpos, newnorm, newfaces = [], [], []
        for tri in crossings:
            polygon = [(pos[i], norm[i], float(distances[i])) for i in tri]
            clipped = []
            for i in range(len(polygon)):
                a, b = polygon[i-1], polygon[i]
                if (a[2] >= 0) != (b[2] >= 0):
                    t = a[2] / (a[2] - b[2])
                    n = a[1] + t * (b[1] - a[1])
                    length = np.linalg.norm(n)
                    clipped.append((a[0] + t*(b[0]-a[0]), n / length if length else n, 0.))
                if b[2] >= 0:
                    clipped.append(b)
            start = len(pos) + len(newpos)
            for p, n, _ in clipped:
                newpos.append(p); newnorm.append(n)
            for i in range(1, len(clipped)-1):
                newfaces.append((start, start+i, start+i+1))
        if newpos:
            pos = np.concatenate((pos, np.asarray(newpos, dtype=np.float32)))
            norm = np.concatenate((norm, np.asarray(newnorm, dtype=np.float32)))
            faces = np.concatenate((keep, np.asarray(newfaces, dtype=np.int64)))
        else:
            faces = keep
        if len(faces) == 0:
            return None
    used, inverse = np.unique(faces.reshape(-1), return_inverse=True)
    return pos[used], norm[used], inverse.reshape(-1, 3)


def main():
    catalogue = json.loads((DATA / 'parts.json').read_text())
    parts = {p['id']: p for p in catalogue['parts'] if p['group'] != 'context'}
    result = {r: {} for r in REGIONS}
    # Collect all LODs first so every published entry is present at every LOD.
    meshes = {r: {suffix: {} for suffix, _ in DETAILS} for r in REGIONS}
    for suffix, _ in DETAILS:
        for source in ('circulatory', 'additional_circulatory', 'extended_circulatory'):
            g, blob = read_glb(DATA / f'{source}{suffix}.glb')
            for node in g['nodes']:
                fid = node['name']; p = parts[fid]
                prim = g['meshes'][node['mesh']]['primitives'][0]
                pos = array(g, blob, prim['attributes']['POSITION'])
                norm = array(g, blob, prim['attributes']['NORMAL'])
                faces = array(g, blob, prim['indices'])
                for region in REGIONS:
                    if region == 'torso' and re.search(r'\b(axillary|brachial|humeral|radial|ulnar|palmar|interosseous|subscapular)\b|^(acromial|deltoid) branch', p['name'], re.I):
                        continue
                    if region == 'heart' and not (p['group'] == 'heart' or p.get('coronary') or fid in ('FJ2966', 'FJ3413')):
                        continue
                    if region == 'cardiac' and not (p['group'] == 'heart' or p.get('coronary')
                            or p.get('circuit') == 'pulmonary'
                            or re.search(r'^(ascending aorta|arch of aorta|inferior vena cava|superior vena cava|(left|right) brachiocephalic vein)$', p['name'], re.I)):
                        continue
                    clipped = clip(pos, norm, faces, PLANES[region])
                    if clipped is not None:
                        meshes[region][suffix][fid] = clipped
    for region in REGIONS:
        ids = set.intersection(*(set(meshes[region][suffix]) for suffix, _ in DETAILS))
        for suffix, count_key in DETAILS:
            for extra in (False, True):
                out = GLB()
                for key in ('artery', 'vein', 'heart_muscle', 'heart_valve', 'heart_blood'):
                    out.add_material(key, (0.5, 0.5, 0.5))
                for fid in sorted(ids):
                    p = parts[fid]
                    if bool(p.get('extended', False)) != extra:
                        continue
                    pos, norm, faces = meshes[region][suffix][fid]
                    out.add_part(fid, pos, norm, faces, p['material'])
                    rec = result[region].setdefault(fid, {})
                    rec[count_key] = len(faces)
                    lo = [round(float(x) - 0.002, 4) for x in pos.min(axis=0)]
                    hi = [round(float(x) + 0.002, 4) for x in pos.max(axis=0)]
                    rec['min'] = [min(a, b) for a, b in zip(rec.get('min', lo), lo)]
                    rec['max'] = [max(a, b) for a, b in zip(rec.get('max', hi), hi)]
                out.write(str(DATA / f'region_{region}{"_extended" if extra else ""}{suffix}.glb'))
        print(region, len(ids), 'base', sum(not parts[x].get('extended',False) for x in ids),
              'extra', sum(bool(parts[x].get('extended',False)) for x in ids))
    (DATA / 'regions.json').write_text(json.dumps(result, separators=(',', ':')) + '\n')

if __name__ == '__main__':
    main()
