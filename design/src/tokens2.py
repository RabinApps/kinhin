import sys,json;sys.path.insert(0,".")
import lib
C=lib._call
d=json.loads(C(["list_variables","--json"]).stdout)["variables"]
coll=d[0]["collectionId"]; byname={v["name"]:v["id"] for v in d}
vals={"color/bg":"#F2F2F7","color/surface":"#FFFFFF","color/sidebar":"#E9E9EE","color/border":"#C6C6C8","color/text":"#000000","color/text-secondary":"#5C5C61","color/accent":"#007AFF","color/ok":"#34C759","color/warn":"#FF9500","color/error":"#FF3B30","color/runtime-tart":"#34C759","color/runtime-container":"#007AFF","color/runtime-docker":"#30B0C7","color/runtime-host":"#AF52DE","color/star":"#7A5A00"}
for n,v in vals.items():
    if n in byname: C(["set_variable","--args",json.dumps({"id":byname[n],"value":v})])
    else: C(["create_variable","--args",json.dumps({"name":n,"type":"COLOR","collection_id":coll,"value":v})])
for n,v in {"color/accent-text":"#0062E0","color/ok-text":"#1F7A35","color/warn-text":"#B34700","color/error-text":"#C70014"}.items():
    if n not in byname: C(["create_variable","--args",json.dumps({"name":n,"type":"COLOR","collection_id":coll,"value":v})])
for n,v in {"font/text":"SF Pro Text","font/display":"SF Pro Display"}.items():
    if n not in byname: C(["create_variable","--args",json.dumps({"name":n,"type":"STRING","collection_id":coll,"value":v})])
d=json.loads(C(["list_variables","--json"]).stdout)["variables"]
print(len(d),sorted(v["name"] for v in d if v["name"].startswith(("font","color/accent","color/ok","color/error"))))
