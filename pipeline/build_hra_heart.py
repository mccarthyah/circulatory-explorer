"""Convert the pinned HuBMAP HRA male v1.3 heart mirror to comparison meshes.

Usage: python pipeline/build_hra_heart.py 3d-vh-m-heart.glb
Requires numpy. See ATTRIBUTION.txt for source and approximate alignment.
"""
import hashlib
import json
import struct
import sys
from pathlib import Path
import numpy as np
from bp3d_lib import GLB, vertex_normals

root = Path(__file__).resolve().parent.parent
raw = Path(sys.argv[1]).read_bytes()
assert hashlib.sha256(raw).hexdigest() == '689df039c8bc264ea06a44cd926762976f0666c0ff2dc532d046409b185e6b0c'
length = struct.unpack_from('<I', raw, 12)[0]
gltf = json.loads(raw[20:20 + length])
binary = memoryview(raw)[28 + length:]
assert not gltf.get('extensionsRequired')

def accessor(i):
    a = gltf['accessors'][i]
    view = gltf['bufferViews'][a['bufferView']]
    typ = {5123:'<u2', 5125:'<u4', 5126:'<f4'}[a['componentType']]
    width = {'SCALAR':1, 'VEC3':3}[a['type']]
    return np.ndarray((a['count'], width), dtype=typ, buffer=binary,
                      offset=view.get('byteOffset', 0) + a.get('byteOffset', 0),
                      strides=(view.get('byteStride', np.dtype(typ).itemsize * width), np.dtype(typ).itemsize)).copy()

writer = GLB()
writer.add_material('hra_heart', [0.2, 0.7, 0.65])
entries = []
for node in gltf['nodes']:
    if 'mesh' not in node:
        continue
    assert not any(x in node for x in ('matrix', 'translation', 'scale', 'rotation'))
    primitive, = gltf['meshes'][node['mesh']]['primitives']
    pos = accessor(primitive['attributes']['POSITION']).astype(float)
    faces = accessor(primitive['indices']).reshape(-1,3)
    # HRA uses patient-left, superior, anterior in metres; convert to cm and
    # align the whole-heart bounds centre to BodyParts3D heart bounds centre.
    pos = (pos * [-100, 100, -100] + [-0.335, -3.09, 1.50]).astype(np.float32)
    name = node['name'].removeprefix('VH_M_').replace('_', ' ')
    id_ = 'hra_' + node['name'].removeprefix('VH_M_').lower()
    writer.add_part(id_, pos, vertex_normals(pos, faces), faces, 'hra_heart')
    entries.append(dict(id=id_, name=name.capitalize() + ' (HRA male heart)', fma='HRA v1.3',
                        group='comparison', material='hra_heart', tris=len(faces), verts=len(pos),
                        min=pos.min(axis=0).round(4).tolist(), max=pos.max(axis=0).round(4).tolist(),
                        centre=((pos.min(axis=0) + pos.max(axis=0))/2).round(4).tolist(),
                        lineage=['Approximate registered comparison']))
assert len(entries) == 14
writer.write(str(root / 'data/comparison_hra_heart.glb'))
(root / 'data/comparison_hra_heart.json').write_text(json.dumps({'parts': entries}, indent=2)+'\n')
print('Built', len(entries), 'separate heart structures')
