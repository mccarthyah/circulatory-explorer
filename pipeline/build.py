"""Build the Godot datasets from BodyParts3D (PART-OF tree, 99% polygon reduction).

Outputs (into the Godot project's data/ folder), for three detail levels:

  circulatory.glb        full detail      (~813 k triangles)
  circulatory_lod1.glb   ~45 % of that    (balanced)
  circulatory_lod2.glb   ~18 % of that    (performance)
  context.glb / _lod1 / _lod2            ghost organs, decimated harder
  parts.json             catalogue: name, FMA id, group, AABB, hierarchy, …
  tour.json              a spline that follows the real blood path

All levels share one catalogue and one set of node names, so the app can swap
levels at runtime without touching anything else.

Run:  python3 build.py
"""
from __future__ import annotations

import json
import os
import re

import numpy as np

from bp3d_lib import (GLB, OBJ_DIR, Frame, centerline, load_obj, orient_chain,
                      smooth_path, vertex_normals)

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.abspath(os.path.join(HERE, ".."))          # the Godot project root
DATA = os.path.join(PROJ, "data")
BP3D_ROOT = os.environ.get("BP3D_ROOT", os.path.expanduser("~/bp3d_raw"))

MATERIALS = {
    # key            colour                rough  metal  alpha
    "artery":       ((0.78, 0.13, 0.14), 0.62, 0.04, 1.0),
    "vein":         ((0.13, 0.28, 0.72), 0.62, 0.04, 1.0),
    "heart_muscle": ((0.62, 0.19, 0.24), 0.68, 0.02, 1.0),
    "heart_valve":  ((0.90, 0.81, 0.62), 0.55, 0.02, 1.0),
    "heart_blood":  ((0.55, 0.05, 0.09), 0.45, 0.02, 1.0),
    "context":      ((0.52, 0.60, 0.72), 0.85, 0.00, 0.16),
}

# suffix, vessel triangle ratio, context triangle scale
DETAILS = [("", 1.00, 1.00), ("_lod1", 0.45, 0.40), ("_lod2", 0.18, 0.14)]

# ---------------------------------------------------------------- classification
SKIP = re.compile(
    r"(hepatovenous|^fourth ventricle$|^third ventricle$|^left lateral ventricle$|"
    r"^right lateral ventricle$|cerebral aqueduct|nasal septum|eyeball|neuraxis|"
    r"body cavity content|hepatic biliary)", re.I)

HEART = re.compile(
    r"(heart|myocard|endocard|pericard|papillary muscle|leaflet of|cusp of (aortic|pulmonary) valve|"
    r"fibrous skeleton|cavity of (left|right) (atrium|ventricle)|wall of (left|right) atrium|^wall of ventricle$)", re.I)
CAVITY = re.compile(r"^cavity of (left|right) (atrium|ventricle)$", re.I)
VALVE = re.compile(r"(leaflet of|cusp of)", re.I)
CORONARY = re.compile(
    r"(coronary|interventricular branch|conus artery|diagonal branch|"
    r"anterior ventricular branch|posterior ventricular branch|"
    r"cardiac vein|interventricular vein|posterior vein of left ventricle|marginal vein of)", re.I)
ARTERY = re.compile(r"(arter|aorta)", re.I)
VEIN = re.compile(r"(vein|venous|vena cava)", re.I)
PULMONARY = re.compile(r"pulmonary", re.I)
PULMONARY_BRANCH = re.compile(
    r"((segmental|lobar|lingular|apical part of right|basal branch|anterobasal|laterobasal|"
    r"mediobasal|posterobasal)[^,]*(artery|vein))", re.I)
SYSTEMIC_ORGAN = re.compile(r"(hepatic|portal|renal|splenic|gastric|mesenteric|phrenic|suprarenal)", re.I)


def classify(name: str):
    """-> (group, material, circuit, coronary) or None when not circulatory."""
    n = name.strip()
    if not n or SKIP.search(n):
        return None
    if HEART.search(n):
        if CAVITY.search(n):
            mat = "heart_blood"
        elif VALVE.search(n):
            mat = "heart_valve"
        else:
            mat = "heart_muscle"
        return ("heart", mat, "pulmonary" if "pulmonary" in n.lower() else "systemic",
                bool(CORONARY.search(n)))
    if n.lower() == "coronary sinus":
        return ("vein", "vein", "systemic", True)
    if n.lower() == "pulmonary trunk":
        return ("artery", "artery", "pulmonary", False)
    circuit = "systemic"
    if PULMONARY.search(n) or (PULMONARY_BRANCH.search(n) and not SYSTEMIC_ORGAN.search(n)):
        circuit = "pulmonary"
    if ARTERY.search(n):
        return ("artery", "artery", circuit, bool(CORONARY.search(n)))
    if VEIN.search(n):
        return ("vein", "vein", circuit, bool(CORONARY.search(n)))
    return None


# curated ghost organs (decimated) so the fly-through has some context
CONTEXT_PATTERNS = [
    r"^skin$", r"^diaphragm$", r"^stomach$", r"^pancreas$", r"^gallbladder$",
    r"^(proximal|middle|distal) part of (jejunum|ileum)$", r"^duodenum$",
    r"^(ascending|transverse|descending) colon$", r"^rectum$",
    r"^(left|right) kidney$", r"^(left|right) ureter$", r"^urinary bladder$",
    r"^trachea$", r"^esophagus$", r"^(midbrain|pons|medulla oblongata)$",
    r"^cerebellum$", r"^white matter of (left|right) cerebral hemisphere$",
    r"^(left|right) (femur|humerus|hip bone|scapula|clavicle)$",
    r"^(first|second|third|fourth|fifth) lumbar vertebra$", r"^sacrum$",
    r"^body of sternum$", r"^(left|right) lobe of thymus$", r"^tongue$",
    r"^prostate$", r"^caudate lobe of liver$",
]
CONTEXT_TARGET_TRIS = {"skin": 24000, "default": 4500}


def short_name(name: str) -> str:
    return re.sub(r"\s+", " ", name).strip()


# ------------------------------------------------------------------------ helpers
def hierarchy(path=None):
    path = path or os.path.join(BP3D_ROOT, "partof_inclusion_relation_list.txt")
    parent = {}
    name_of = {}
    with open(path, "r", errors="replace") as fh:
        next(fh)
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 4:
                continue
            pid, pname, cid, cname = parts[:4]
            parent[cid] = pid
            name_of[cid] = pname
            name_of.setdefault(cid, cname)
    return parent, name_of


def ancestors(cid, parent, name_of, limit=6):
    out = []
    cur = cid
    while cur in parent and len(out) < limit:
        cur = parent[cur]
        nm = name_of.get(cur)
        if nm:
            out.append(short_name(nm))
    return list(reversed(out))


def simplify(pos, faces, ratio: float, min_tris: int = 12):
    """Quadric-decimate to `ratio` of the original triangle count."""
    if ratio >= 1.0:
        return pos, faces
    import fast_simplification
    target = max(min_tris, int(len(faces) * ratio))
    if len(faces) <= target:
        return pos, faces
    v, f = pos.astype(np.float32), faces.astype(np.int32)
    for _ in range(6):
        if len(f) <= target * 1.1:
            break
        reduction = min(0.95, 1.0 - target / float(len(f)))
        try:
            nv, nf = fast_simplification.simplify(v, f, reduction, agg=7)
        except Exception as exc:  # pragma: no cover
            print("  decimation failed:", exc)
            break
        if len(nf) < 8 or len(nf) > len(f) * 0.98:
            break
        v, f = nv, nf
    return v.astype(np.float64), f.astype(np.int64)


# --------------------------------------------------------------------------- main
def main():
    os.makedirs(DATA, exist_ok=True)
    index = json.load(open(os.path.join(HERE, "index.json")))
    # Supplemental meshes are built separately from the pinned IS-A source.
    # Exclude their IDs here even if the PART-OF index contains them, avoiding
    # duplicate geometry and keeping the existing tour/base export stable.
    supplemental = json.load(open(os.path.join(HERE, "additional_parts.json")))
    supplemental_ids = {r["id"] for r in supplemental["parts"]}
    parent, name_of = hierarchy()

    # body centre = centre of the whole-body bounding box of every part
    lo = np.array([1e9] * 3)
    hi = -lo.copy()
    for rec in index:
        if not rec["bounds"]:
            continue
        m = re.findall(r"-?\d+\.?\d*", rec["bounds"])
        if len(m) != 6:
            continue
        lo = np.minimum(lo, np.array([float(x) for x in m[:3]]))
        hi = np.maximum(hi, np.array([float(x) for x in m[3:]]))
    center_mm = (lo + hi) / 2.0
    frame = Frame(center_mm)
    print("body bbox mm", lo, hi, "height", round(hi[2] - lo[2], 1))

    # one glTF writer per detail level
    glbs = {}
    cglbs = {}
    for suffix, _vr, _cr in DETAILS:
        g = GLB()
        for key, (col, rough, metal, alpha) in MATERIALS.items():
            g.add_material(key, col, rough, metal, alpha)
        glbs[suffix] = g
        c = GLB()
        col, rough, metal, alpha = MATERIALS["context"]
        c.add_material("context", col, rough, metal, alpha)
        cglbs[suffix] = c

    catalog = []
    seen_files = set()
    counts = {"artery": 0, "vein": 0, "heart": 0}
    tris = {s: 0 for s, _, _ in DETAILS}

    for rec in sorted(index, key=lambda r: r["name"] or "zz"):
        cls = classify(rec.get("name") or "")
        if cls is None:
            continue
        group, mat, circuit, coronary = cls
        fid = rec["fid"]
        if fid in seen_files or fid in supplemental_ids:
            continue
        path = os.path.join(OBJ_DIR, fid + ".obj")
        if not os.path.exists(path):
            continue
        try:
            v_mm, faces = load_obj(path)
        except Exception as exc:
            print("  skip", fid, exc)
            continue
        pos = frame.apply(v_mm).astype(np.float32)
        nrm_full = vertex_normals(pos.astype(np.float64), faces)
        level_tris = {}
        for suffix, vratio, _cr in DETAILS:
            if suffix == "":
                p, f, n = pos, faces, nrm_full
            else:
                p, f = simplify(pos.astype(np.float64), faces, vratio)
                p = p.astype(np.float32)
                n = vertex_normals(p.astype(np.float64), f)
            glbs[suffix].add_part(fid, p, n, f, mat, extras={
                "fma": rec["concept"], "name": short_name(rec["name"]), "group": group})
            level_tris[suffix] = int(len(f))
            tris[suffix] += int(len(f))
        seen_files.add(fid)
        counts[group] += 1
        catalog.append({
            "id": fid,
            "fma": rec["concept"],
            "name": short_name(rec["name"]),
            "group": group,
            "material": mat,
            "circuit": circuit,
            "coronary": coronary,
            "tris": level_tris[""],
            "tris_lod1": level_tris["_lod1"],
            "tris_lod2": level_tris["_lod2"],
            "verts": int(len(pos)),
            "centre": [round(float(x), 3) for x in pos.mean(axis=0)],
            "min": [round(float(x), 3) for x in pos.min(axis=0)],
            "max": [round(float(x), 3) for x in pos.max(axis=0)],
            "lineage": ancestors(rec["concept"], parent, name_of),
        })

    for suffix, _vr, _cr in DETAILS:
        size = glbs[suffix].write(os.path.join(DATA, f"circulatory{suffix}.glb"))
        print(f"circulatory{suffix}.glb  parts={len(catalog)} tris={tris[suffix]} "
              f"size={size/1e6:.1f} MB")

    # ---------------------------------------------------------------- context
    ctx = []
    used_names = set()
    ctris = {s: 0 for s, _, _ in DETAILS}
    for rec in index:
        nm = rec.get("name") or ""
        if not any(re.match(p, nm.strip(), re.I) for p in CONTEXT_PATTERNS):
            continue
        key = nm.strip().lower()
        if key in used_names:
            continue
        path = os.path.join(OBJ_DIR, rec["fid"] + ".obj")
        if not os.path.exists(path):
            continue
        try:
            v_mm, faces = load_obj(path)
        except Exception as exc:
            print("  ctx skip", rec["fid"], exc)
            continue
        base_target = CONTEXT_TARGET_TRIS["skin"] if key == "skin" else CONTEXT_TARGET_TRIS["default"]
        pos_full = frame.apply(v_mm).astype(np.float32)
        level_tris = {}
        for suffix, _vr, cratio in DETAILS:
            target = max(60, int(base_target * cratio))
            p, f = simplify(pos_full.astype(np.float64), faces,
                            target / max(1, len(faces)))
            p = p.astype(np.float32)
            n = vertex_normals(p.astype(np.float64), f)
            cglbs[suffix].add_part(rec["fid"], p, n, f, "context", extras={
                "fma": rec["concept"], "name": short_name(nm), "group": "context"})
            level_tris[suffix] = int(len(f))
            ctris[suffix] += int(len(f))
        used_names.add(key)
        ctx.append({
            "id": rec["fid"], "fma": rec["concept"], "name": short_name(nm),
            "group": "context", "material": "context", "circuit": "systemic",
            "coronary": False,
            "tris": level_tris[""], "tris_lod1": level_tris["_lod1"], "tris_lod2": level_tris["_lod2"],
            "verts": int(len(pos_full)),
            "centre": [round(float(x), 3) for x in pos_full.mean(axis=0)],
            "min": [round(float(x), 3) for x in pos_full.min(axis=0)],
            "max": [round(float(x), 3) for x in pos_full.max(axis=0)],
            "lineage": ancestors(rec["concept"], parent, name_of),
        })

    for suffix, _vr, _cr in DETAILS:
        size = cglbs[suffix].write(os.path.join(DATA, f"context{suffix}.glb"))
        print(f"context{suffix}.glb  parts={len(ctx)} tris={ctris[suffix]} file={size/1e6:.1f} MB")

    catalog.extend(ctx)
    json.dump({"centre_mm": [round(float(x), 2) for x in center_mm],
               "unit": "1 unit = 1 cm",
               "source": "BodyParts3D (DBCLS), PART-OF tree, 99% polygon reduction, CC BY-SA 2.1 JP",
               "detail_levels": {"high": "", "balanced": "_lod1", "performance": "_lod2"},
               "parts": catalog},
              open(os.path.join(DATA, "parts.json"), "w"), indent=1)
    print("parts.json written:", len(catalog), "total tris",
          {k: v for k, v in tris.items()}, "context", ctris)

    build_tour(frame)
    write_attribution()


# --------------------------------------------------------------------------- tour
# (file id, station title, caption) — shown when the camera arrives
TOUR = [
    ("FJ3645", "Superior vena cava",
     "Deoxygenated blood from the head, neck and arms returns through the superior vena cava. "
     "It is a low-pressure vessel: 5-10 mmHg."),
    ("FJ2424", "Right atrium",
     "The right atrium collects the returning blood. The sinoatrial node, the heart's natural "
     "pacemaker, sits in its wall and fires about 60-100 times a minute."),
    ("FJ2423", "Right ventricle",
     "Through the tricuspid valve into the right ventricle. Contraction here pushes blood into "
     "the lungs - the pulmonary circuit, the only place where arteries carry deoxygenated blood."),
    ("FJ2966", "Pulmonary trunk",
     "The pulmonary trunk leaves the right ventricle and splits into the left and right pulmonary "
     "arteries, one for each lung."),
    ("FJ3019", "Right pulmonary artery",
     "Inside the lungs the arteries break down into smaller and smaller branches, ending in "
     "capillaries around the alveoli. Here CO2 leaves the blood and O2 enters."),
    ("FJ3020", "Pulmonary veins",
     "Oxygenated blood comes back through four pulmonary veins - the only veins that carry "
     "oxygen-rich blood - into the left atrium."),
    ("FJ2425", "Left atrium",
     "The left atrium is the receiving chamber for the systemic circuit."),
    ("FJ2422", "Left ventricle",
     "Through the mitral valve into the left ventricle. Its wall is the thickest in the heart "
     "(8-12 mm) because it has to pump blood to the whole body."),
    ("FJ3413", "Ascending aorta",
     "Blood leaves through the aortic valve into the ascending aorta. The coronary arteries "
     "branch off immediately - the heart feeds itself first."),
    ("FJ3411", "Arch of the aorta",
     "The arch turns backwards and gives off the brachiocephalic, left common carotid and left "
     "subclavian arteries, which supply the head and arms."),
    ("FJ1931", "Descending thoracic aorta",
     "The descending aorta runs down the back of the chest, giving off intercostal and "
     "oesophageal branches."),
    ("FJ1932", "Abdominal aorta",
     "Below the diaphragm it becomes the abdominal aorta: coeliac trunk, mesenteric, renal and "
     "gonadal arteries branch off here."),
    ("FJ3565", "Right common iliac artery",
     "At about the level of the navel the aorta bifurcates into the two common iliac arteries."),
    ("FJ3567", "Right external iliac artery",
     "The external iliac artery crosses under the inguinal ligament and becomes the femoral artery."),
    ("FJ2143", "Right femoral artery",
     "The femoral artery is the main supply of the leg - and a favourite site for a pulse check "
     "and for catheter access."),
    ("FJ2170", "Right popliteal artery",
     "Behind the knee the femoral artery becomes the popliteal artery, which splits into the "
     "anterior and posterior tibial arteries."),
    ("FJ2130", "Right anterior tibial artery",
     "Down the front of the shin, becoming the dorsalis pedis artery on the top of the foot."),
    ("FJ2055", "Right dorsalis pedis artery",
     "Roughly 5 litres a minute leave the heart; every one of them eventually squeezes through "
     "capillaries narrower than a red blood cell is wide (about 7 um)."),
    ("FJ3568", "Right external iliac vein",
     "Lower-limb veins are available in the optional extra-vessels layer. The tour rejoins "
     "the venous tree at the external iliac vein, where blood climbs back towards the heart."),
    ("FJ3566", "Right common iliac vein",
     "Venous blood flows upward against gravity, helped by valves and by the calf muscle pump."),
    ("FJ3659", "Inferior vena cava",
     "The inferior vena cava collects everything below the diaphragm - the largest vein in the body."),
    ("FJ3441", "Inferior vena cava",
     "It passes through the diaphragm and empties into the right atrium. The circuit closes: "
     "back where we started in about a minute."),
]


def build_tour(frame: Frame):
    chains = []
    stations = []
    for fid, title, text in TOUR:
        path = os.path.join(OBJ_DIR, fid + ".obj")
        v_mm, _ = load_obj(path)
        pos = frame.apply(v_mm)
        chains.append(centerline(pos, k=6))
        stations.append({"fid": fid, "title": title, "text": text, "chain": len(chains) - 1})

    chains = orient_chain(chains)
    pts = [chains[0][0]]
    station_pts = {}
    for i, ch in enumerate(chains):
        for p in ch:
            if np.linalg.norm(p - pts[-1]) > 0.15:      # 1.5 mm
                pts.append(p)
        station_pts[i] = len(pts) - 1
    pts = np.asarray(pts)
    pts = smooth_path(pts, iters=3, alpha=0.35)

    seg = np.linalg.norm(np.diff(pts, axis=0), axis=1)
    cum = np.concatenate([[0.0], np.cumsum(seg)])
    total = cum[-1]
    out_stations = []
    for st in stations:
        idx = station_pts[st["chain"]]
        out_stations.append({
            "t": round(float(cum[idx] / total), 5),
            "title": st["title"], "text": st["text"], "fid": st["fid"],
            "at": [round(float(x), 2) for x in pts[idx]],
        })

    tour = {
        "points": [[round(float(x), 2) for x in p] for p in pts],
        "length": round(float(total), 2),
        "stations": out_stations,
    }
    json.dump(tour, open(os.path.join(DATA, "tour.json"), "w"), indent=1)
    print(f"tour.json  points={len(pts)} length={total:.1f} cm stations={len(out_stations)}")


def write_attribution():
    txt = """BodyParts3D data attribution
============================

The 3D anatomy in this project is derived from BodyParts3D:

  BodyParts3D, (c) The Database Center for Life Science
  licensed under CC Attribution-Share Alike 2.1 Japan
  https://dbarchive.biosciencedbc.jp/en/bodyparts3d/lic.html

Source files: partof_BP3D_4.0_obj_99.zip (PART-OF tree, 99 % polygon reduction)
and isa_BP3D_4.0_obj_99 (IS-A tree, 99 % polygon reduction). The additional
IS-A meshes were obtained from the pinned GitHub mirror recorded in
pipeline/additional_parts.json; source-file checksums are recorded there.
Database DOI: 10.18908/lsdba.nbdc00837-000

Reference: Mitsuhashi N, Fujieda K, Tamura T, Kawamoto S, Takagi T, Okubo K.
BodyParts3D: 3D structure database for anatomical concepts.
Nucleic Acids Res. 2008 Oct 3. PMID: 18835852

Modifications made by this project: coordinate conversion from BodyParts3D
(mm, X=left, Y=posterior, Z=superior) to Godot's Y-up space, unit scaled to
centimetres, smooth vertex normals recomputed, meshes packed into glTF 2.0,
additional quadric-decimated levels of detail for the vessels and the ghost
organs, and a medial-line spline derived from the vessel meshes for the tour.

If you redistribute the models you must keep this attribution and share alike.
"""
    open(os.path.join(PROJ, "ATTRIBUTION.txt"), "w").write(txt)


if __name__ == "__main__":
    main()
