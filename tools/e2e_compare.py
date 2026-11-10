import json,sys,os
S=os.environ.get("MT_RIG") or os.path.join(os.environ.get("XDG_RUNTIME_DIR","/tmp"),"mistria-together-rig")
def st(p): return json.load(open(f"{S}/{p}/FieldsOfMistria/mod_data/mistria_together/ipc/dev_state.json"))
a,b=st("p1"),st("p2")
na,nb=a["sync"]["near"],b["sync"]["near"]
tag=sys.argv[1] if len(sys.argv)>1 else ""
print(f"{tag}: p1 {len(na)} items, p2 {len(nb)} items ->", "EQUAL" if na==nb else "DIFFERENT")
if na!=nb:
    print("  only p1:", sorted(set(na)-set(nb))[:8]); print("  only p2:", sorted(set(nb)-set(na))[:8])
for p,d in (("p1",a),("p2",b)):
    f=[l for l in d["log"] if "FAILED" in l]
    if f: print(" ",p,f[-2:])
    print(" ",p,{k:v for k,v in d["sync"].items() if k!="near"}, "loc",d.get("loc"),"clk",d.get("clk"),"cal",d.get("cal"))
