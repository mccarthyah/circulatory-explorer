"""Build the optional organ comparison layer from the cited derivative.

Input: organs.glb from mauupa0/vessels-3d at the commit in ATTRIBUTION.txt,
first decoded with gltf-transform copy (EXT_meshopt_compression removed), and
the matching anatomy.json. Requires numpy. The source remains quantized.
Example: python pipeline/build_comparison.py decoded.glb anatomy.json
"""
import json
import struct
import sys
from pathlib import Path

import numpy as np
from bp3d_lib import GLB, vertex_normals

root = Path(__file__).resolve().parent.parent
raw = Path(sys.argv[1]).read_bytes()
assert raw[:4] == b'glTF'
json_len = struct.unpack_from('<I', raw, 12)[0]
gltf = json.loads(raw[20:20 + json_len])
assert 'EXT_meshopt_compression' not in gltf.get('extensionsRequired', [])
assert len(gltf['nodes']) == 1 and len(gltf['meshes']) == 1
binary = memoryview(raw)[28 + json_len:]

def accessor(index):
    a = gltf['accessors'][index]
    view = gltf['bufferViews'][a['bufferView']]
    dtype = {5120: '<i1', 5122: '<i2', 5123: '<u2', 5125: '<u4', 5126: '<f4'}[a['componentType']]
    width = {'SCALAR': 1, 'VEC3': 3}[a['type']]
    stride = view.get('byteStride', np.dtype(dtype).itemsize * width)
    return np.ndarray((a['count'], width), dtype=dtype, buffer=binary,
                      offset=view.get('byteOffset', 0) + a.get('byteOffset', 0),
                      strides=(stride, np.dtype(dtype).itemsize)).copy()

primitive = gltf['meshes'][0]['primitives'][0]
indices = accessor(primitive['indices']).reshape(-1, 3)
part_id = accessor(primitive['attributes']['_PART']).reshape(-1)
positions = accessor(primitive['attributes']['POSITION']).astype(float)
a = gltf['accessors'][primitive['attributes']['POSITION']]
assert a['normalized'] and a['componentType'] == 5122
node = gltf['nodes'][0]
positions = positions / 32767.0 * np.asarray(node['scale']) + np.asarray(node['translation'])
# Source axes: patient-left, superior, anterior, metres. Convert to project cm.
# Approximate translation from the centres of six corresponding organs, no
# deformation: kidney, stomach, pancreas, gallbladder, trachea (see README).
positions *= [-100, 100, -100]
positions += [0.065, -84.85, 0.35]
source = json.loads(Path(sys.argv[2]).read_text())
organs = [p for p in source['parts'] if p['layer'] == 'organs']
assert len(organs) == 17
writer = GLB()
writer.add_material('z_organs', [0.65, 0.53, 0.74])
catalogue = []
for organ in organs:
    tris = indices[np.all(part_id[indices] == organ['index'], axis=1)]
    assert len(tris) > 0
    vertices, remapped = np.unique(tris.reshape(-1), return_inverse=True)
    faces = remapped.reshape(-1, 3)
    pos = positions[vertices].astype(np.float32)
    id_ = 'z_' + organ['id'].replace('-', '_')
    writer.add_part(id_, pos, vertex_normals(pos, faces), faces, 'z_organs')
    catalogue.append(dict(id=id_, name=organ['name'] + ' (Z-Anatomy comparison)', fma='Z-Anatomy / BodyParts3D',
                          group='comparison', material='z_organs', tris=len(faces), verts=len(pos),
                          min=pos.min(axis=0).round(4).tolist(), max=pos.max(axis=0).round(4).tolist(),
                          centre=((pos.min(axis=0) + pos.max(axis=0))/2).round(4).tolist(),
                          lineage=['Approximate registered comparison']))
writer.write(str(root / 'data/comparison_z_organs.glb'))
(root / 'data/comparison_z_organs.json').write_text(json.dumps({'parts': catalogue}, indent=2) + '\n')
print('Built', len(catalogue), 'separate organs')
