"""BodyParts3D -> Godot export helpers.

Loads the per-organ Wavefront OBJ meshes shipped by BodyParts3D, converts them to
Godot's coordinate system (Y up, -Z forward, 1 unit = 1 cm) and writes them out as
glTF 2.0 binary (.glb) with one node per anatomical part.
"""
from __future__ import annotations

import json
import os
import re
import struct

import numpy as np

# Where the unzipped BodyParts3D download lives. Override with BP3D_ROOT.
BP3D_ROOT = os.environ.get("BP3D_ROOT", os.path.expanduser("~/bp3d_raw"))
OBJ_DIR = os.path.join(BP3D_ROOT, "extracted", "partof_BP3D_4.0_obj_99")

# BodyParts3D axes (see coordinate_system.png):
#   +X = left,  +Y = posterior,  +Z = superior, unit = mm
# Godot axes: +X = right, +Y = up, -Z = forward  (right handed)
# Mapping (determinant +1, so no mirroring):
#   X_godot = -X_bp ,  Y_godot = Z_bp ,  Z_godot = Y_bp
SCALE = 0.1  # mm -> "1 unit = 1 cm"


# --------------------------------------------------------------------------- OBJ
def load_obj(path: str):
    """Return (verts Nx3 float64 in mm, faces Mx3 int32) from a BodyParts3D OBJ."""
    verts = []
    faces = []
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            if line.startswith("v "):
                _, x, y, z = line.split()[:4]
                verts.append((float(x), float(y), float(z)))
            elif line.startswith("f "):
                toks = line.split()[1:]
                idx = [int(t.split("/")[0]) - 1 for t in toks if t]
                if len(idx) >= 3:
                    for k in range(1, len(idx) - 1):  # fan triangulation
                        faces.append((idx[0], idx[k], idx[k + 1]))
    v = np.asarray(verts, dtype=np.float64)
    f = np.asarray(faces, dtype=np.int64)
    if len(v) == 0 or len(f) == 0:
        raise ValueError(f"empty mesh: {path}")
    f = f[(f >= 0).all(axis=1) & (f < len(v)).all(axis=1)]
    return v, f


class Frame:
    """mm (BodyParts3D) -> cm (Godot) conversion around a body-centred origin."""

    def __init__(self, center_mm, scale=SCALE):
        self.c = np.asarray(center_mm, dtype=np.float64)
        self.s = scale

    def apply(self, v_mm: np.ndarray) -> np.ndarray:
        d = (v_mm - self.c) * self.s
        return np.stack([-d[:, 0], d[:, 2], d[:, 1]], axis=1)


def vertex_normals(pos: np.ndarray, faces: np.ndarray) -> np.ndarray:
    """Area weighted smooth normals."""
    n = np.zeros_like(pos)
    a, b, c = pos[faces[:, 0]], pos[faces[:, 1]], pos[faces[:, 2]]
    fn = np.cross(b - a, c - a)
    for k in range(3):
        np.add.at(n, faces[:, k], fn)
    ln = np.linalg.norm(n, axis=1, keepdims=True)
    ln[ln == 0] = 1.0
    return (n / ln).astype(np.float32)


# --------------------------------------------------------------------- GLB writer
class GLB:
    """Minimal glTF 2.0 binary writer: one node + one mesh per part."""

    def __init__(self):
        self.bin = bytearray()
        self.buffer_views = []
        self.accessors = []
        self.meshes = []
        self.nodes = []
        self.materials = []
        self.material_index = {}

    # -- low level -----------------------------------------------------------
    def _view(self, data: bytes, target: int | None = None) -> int:
        while len(self.bin) % 4:
            self.bin += b"\x00"
        off = len(self.bin)
        self.bin += data
        bv = {"buffer": 0, "byteOffset": off, "byteLength": len(data)}
        if target:
            bv["target"] = target
        self.buffer_views.append(bv)
        return len(self.buffer_views) - 1

    def _accessor(self, view, comp, count, typ, mn=None, mx=None):
        acc = {"bufferView": view, "componentType": comp, "count": count, "type": typ}
        if mn is not None:
            acc["min"] = [float(x) for x in mn]
            acc["max"] = [float(x) for x in mx]
        self.accessors.append(acc)
        return len(self.accessors) - 1

    def add_material(self, key: str, color, roughness=0.75, metallic=0.0, alpha=1.0):
        mat = {
            "name": key,
            "pbrMetallicRoughness": {
                "baseColorFactor": [color[0], color[1], color[2], alpha],
                "metallicFactor": metallic,
                "roughnessFactor": roughness,
            },
            "doubleSided": True,
        }
        if alpha < 1.0:
            mat["alphaMode"] = "BLEND"
        self.materials.append(mat)
        self.material_index[key] = len(self.materials) - 1
        return self.material_index[key]

    # -- high level ----------------------------------------------------------
    def add_part(self, name: str, pos: np.ndarray, normals: np.ndarray, faces: np.ndarray,
                 material_key: str, extras: dict | None = None):
        pos = np.ascontiguousarray(pos, dtype=np.float32)
        normals = np.ascontiguousarray(normals, dtype=np.float32)
        faces = np.ascontiguousarray(faces, dtype=np.uint32)

        v_pos = self._view(pos.tobytes(), 34962)
        a_pos = self._accessor(v_pos, 5126, len(pos), "VEC3",
                              pos.min(axis=0), pos.max(axis=0))
        v_nrm = self._view(normals.tobytes(), 34962)
        a_nrm = self._accessor(v_nrm, 5126, len(normals), "VEC3")

        if len(pos) < 65536:
            idx = faces.astype(np.uint16)
            comp = 5123
        else:
            idx = faces
            comp = 5125
        v_idx = self._view(idx.tobytes(), 34963)
        a_idx = self._accessor(v_idx, comp, int(faces.size), "SCALAR")

        prim = {
            "attributes": {"POSITION": a_pos, "NORMAL": a_nrm},
            "indices": a_idx,
            "mode": 4,
            "material": self.material_index[material_key],
        }
        self.meshes.append({"name": name, "primitives": [prim]})
        node = {"name": name, "mesh": len(self.meshes) - 1}
        if extras:
            node["extras"] = extras
        self.nodes.append(node)
        return len(self.nodes) - 1

    def write(self, path: str):
        while len(self.bin) % 4:
            self.bin += b"\x00"
        gltf = {
            "asset": {"version": "2.0", "generator": "BodyParts3D -> Godot exporter"},
            "scene": 0,
            "scenes": [{"name": "BodyParts3D", "nodes": list(range(len(self.nodes)))}],
            "nodes": self.nodes,
            "meshes": self.meshes,
            "materials": self.materials,
            "accessors": self.accessors,
            "bufferViews": self.buffer_views,
            "buffers": [{"byteLength": len(self.bin)}],
        }
        js = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
        js += b" " * ((4 - len(js) % 4) % 4)
        binchunk = bytes(self.bin)
        total = 12 + 8 + len(js) + 8 + len(binchunk)
        with open(path, "wb") as fh:
            fh.write(b"glTF")
            fh.write(struct.pack("<II", 2, total))
            fh.write(struct.pack("<II", len(js), 0x4E4F534A))  # JSON
            fh.write(js)
            fh.write(struct.pack("<II", len(binchunk), 0x004E4942))  # BIN
            fh.write(binchunk)
        return total


# -------------------------------------------------------------------- centerlines
def centerline(pos: np.ndarray, k: int = 6) -> np.ndarray:
    """Rough medial line of a tubular part: slice along the principal axis and
    take the centroid of each slice. Returns k points ordered along that axis."""
    if len(pos) < k * 3:
        return pos.mean(axis=0, keepdims=True)
    c = pos.mean(axis=0)
    p = pos - c
    # principal direction = largest eigenvector of the covariance matrix
    w, v = np.linalg.eigh(p.T @ p)
    axis = v[:, int(np.argmax(w))]
    proj = p @ axis
    lo, hi = np.percentile(proj, 1.0), np.percentile(proj, 99.0)
    if hi - lo < 1e-6:
        return c[None, :]
    edges = np.linspace(lo, hi, k + 1)
    pts = []
    for i in range(k):
        m = (proj >= edges[i]) & (proj <= edges[i + 1])
        if m.sum() >= 3:
            pts.append(pos[m].mean(axis=0))
    if len(pts) < 2:
        return np.stack([c - axis * 1e-3, c + axis * 1e-3])
    return np.asarray(pts)


def orient_chain(chains):
    """Flip individual chains so consecutive chains join up smoothly."""
    out = []
    prev = None
    for ch in chains:
        ch = np.asarray(ch, dtype=np.float64)
        if prev is not None and len(ch) > 1:
            d_start = np.linalg.norm(ch[0] - prev)
            d_end = np.linalg.norm(ch[-1] - prev)
            if d_end < d_start:
                ch = ch[::-1]
        out.append(ch)
        prev = ch[-1]
    return out


def smooth_path(pts: np.ndarray, iters: int = 2, alpha: float = 0.35) -> np.ndarray:
    pts = pts.copy()
    for _ in range(iters):
        if len(pts) < 3:
            break
        mid = pts[1:-1] + alpha * ((pts[:-2] + pts[2:]) / 2.0 - pts[1:-1])
        pts[1:-1] = mid
    return pts
