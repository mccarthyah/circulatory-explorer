import os,re,json
import os
D=os.path.join(os.environ.get("BP3D_ROOT", os.path.expanduser("~/bp3d_raw")),
               "extracted", "partof_BP3D_4.0_obj_99")
out=[]
for fn in sorted(os.listdir(D)):
    p=os.path.join(D,fn)
    raw=open(p,'r',errors='replace')
    head=''.join(raw.readline() for _ in range(20)); raw.close()
    g=lambda pat:(re.search(pat,head).group(1).strip() if re.search(pat,head) else '')
    rec=dict(file=fn, fid=g(r'File ID : (\S+)') or fn.replace('.obj',''),
             concept=g(r'Concept ID : (\S+)'), name=g(r'English name : (.+)'),
             bounds=g(r'Bounds\(mm\): (.+)'), volume=g(r'Volume\(cm3\): (\S+)'),
             tris=0, verts=0, size=os.path.getsize(p))
    for line in open(p,'r',errors='replace'):
        if line.startswith('v '): rec['verts']+=1
        elif line.startswith('f '): rec['tris']+=1
    out.append(rec)
json.dump(out,open('index.json','w'))
print(len(out), sum(r['tris'] for r in out))
missing=[r for r in out if not r['name']]
print('missing names', len(missing), [m['fid'] for m in missing])
