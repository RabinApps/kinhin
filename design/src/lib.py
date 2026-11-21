import json,subprocess,os
DARK=os.environ.get("KDARK")=="1"
if DARK: P=dict(BG="#000000",SURF="#1C1C1E",SIDE="#2C2C2E",BOR="#38383A",TX="#FFFFFF",TX2="#AEAEB2",ACC="#0A84FF",ACCT="#4DA3FF",OK="#30D158",OKT="#30D158",WARN="#FF9F0A",WARNT="#FF9F0A",ERR="#FF453A",ERRT="#FF6961")
else: P=dict(BG="#F2F2F7",SURF="#FFFFFF",SIDE="#E9E9EE",BOR="#C6C6C8",TX="#000000",TX2="#5C5C61",ACC="#007AFF",ACCT="#0062E0",OK="#34C759",OKT="#1F7A35",WARN="#FF9500",WARNT="#B34700",ERR="#FF3B30",ERRT="#C70014")
BG,SURF,SIDE,BOR,TX,TX2,ACC,ACCT,OK,OKT,WARN,WARNT,ERR,ERRT=[P[k] for k in "BG SURF SIDE BOR TX TX2 ACC ACCT OK OKT WARN WARNT ERR ERRT".split()]
TART="#34C759";CONT="#007AFF";DOCK="#30B0C7";HOST="#AF52DE"
TM={ACC:ACCT,OK:OKT,WARN:WARNT,ERR:ERRT}
SC={"ok":OKT,"warn":WARNT,"error":ERRT,"info":TX2}
FILL={"ok":OK,"warn":WARN,"error":ERR,"info":TX2}
def T(s,size=13,w=400,c=None,fill=False):
    size=max(size,12)
    s=str(s).replace("<","‹").replace(">","›").replace("{","(").replace("}",")")
    wf=' w="fill"' if fill else ''
    lh={12:16,13:16,15:20,17:24,22:28}.get(size,16)
    col=TM.get(c,c) if c else TX
    fam="SF Pro Display" if size>=22 else "SF Pro Text"
    return f'<Text size={{{size}}} weight={{{w}}} lineHeight={{{lh}}} fontFamily="{fam}" color="{col}"{wf}>{s}</Text>'
def sp(): return '<Frame w="fill" h={2}/>'
def hrow(*a,gap=8,fill=True,items="center",justify=None): 
    j=f' justify="{justify}"' if justify else ''
    wf='w="fill" ' if fill else ''
    return f'<Frame flex="row" {wf}gap={{{gap}}} items="{items}"{j}>{"".join(a)}</Frame>'
def vcol(*a,gap=8,fill=True):
    wf='w="fill" ' if fill else ''
    return f'<Frame flex="col" {wf}gap={{{gap}}}>{"".join(a)}</Frame>'
def chip(s,c=None,solid=False):
    c=c or TX2
    return f'<Frame flex="row" px={{8}} py={{3}} rounded={{10}} bg="{TM.get(c,c) if solid else c+"26"}">{T(s,11,600,"#FFFFFF" if solid else c)}</Frame>'
def status(s,k="info"): return T(s,11,400,SC[k],fill=len(s)>60)
def btn(s,kind="d"):
    bg={"p":ACCT,"d":SURF,"x":SURF}[kind]; c={"p":"#FFFFFF","d":TX,"x":ERR}[kind]
    return f'<Frame flex="row" px={{12}} py={{5}} rounded={{6}} bg="{bg}" stroke="{BOR if kind!="p" else ACCT}">{T(s,13,500,c)}</Frame>'
def sbtn(s): return f'<Frame flex="row" px={{8}} py={{3}} rounded={{6}} bg="{SURF}" stroke="{BOR}">{T(s,11,500)}</Frame>'
def toggle(on,dis=False):
    c=ACC if on else BOR
    return f'<Frame flex="row" w={{34}} h={{20}} p={{2}} rounded={{10}} bg="{c}" opacity={{{0.4 if dis else 1}}} justify="{"end" if on else "start"}"><Frame w={{16}} h={{16}} rounded={{8}} bg="#FFFFFF"/></Frame>'
def field(label,val,dis=False,ph=False,w=240,err=False,secure=False):
    v=("••••••••••••" if secure else val)
    col=TX2 if (ph or dis) else TX
    box=f'<Frame flex="row" w={{{w}}} px={{8}} py={{5}} rounded={{6}} bg="{BG if dis else SURF}" stroke="{ERR if err else BOR}">{T(v,13,400,col)}</Frame>'
    return vcol(T(label,11,500,TX2),box,gap=4,fill=False) if label else box
def combo(label,val,w=240): return field(label,val+"  ⌄",w=w)
def seg(opts,sel):
    return '<Frame flex="row" p={2} rounded={8} bg="%s" gap={2}>%s</Frame>'%(SIDE,"".join(f'<Frame flex="row" px={{12}} py={{4}} rounded={{6}} bg="{SURF if o==sel else SIDE}">{T(o,12,600 if o==sel else 400)}</Frame>' for o in opts))
def row(l,r="",sub="",dim=False):
    if r and not r.startswith("<"): r=T(r,13,400,TX2)
    left=vcol(T(l,13,500),T(sub,11,400,TX2) if sub else "",gap=2,fill=False)
    return f'<Frame flex="row" w="fill" px={{10}} py={{8}} items="center" gap={{8}} rounded={{6}} bg="{BG}">{left}{sp()}{r}</Frame>'
def dotc(c,s=8): return f'<Frame w={{{s}}} h={{{s}}} rounded={{{s//2}}} bg="{c}"/>'
def card(title,sub="",body="",right="",collapsed=False):
    h=hrow(vcol(T(title,13,600),T(sub,11,400,TX2) if sub else "",gap=2,fill=False),sp(),right,justify="between") if title else ""
    return f'<Frame flex="col" w="fill" p={{16}} gap={{12}} rounded={{10}} bg="{SURF}" stroke="{BOR}">{h}{body}</Frame>'
def banner(k,text,action=""):
    c=FILL[k]
    return f'<Frame flex="row" w="fill" px={{12}} py={{8}} gap={{10}} items="center" rounded={{8}} bg="{c}1F" stroke="{c}">{T("⚠",13,700,c)}{T(text,13,500,TX,fill=True)}{action}</Frame>'
def code(s): return f'<Frame flex="col" w="fill" p={{10}} rounded={{6}} bg="{BG}" stroke="{BOR}" gap={{2}}>{"".join(T(l,11,400,TX2) for l in s.split(chr(10)))}</Frame>'
def head(t,s="",right=""): return hrow(vcol(T(t,22,700),T(s,13,400,TX2) if s else "",gap=4,fill=False),sp(),right,justify="between")
def stepper(label,val,hint="",err=False,dis=False,w=None):
    box=f'<Frame flex="row" items="center" gap={{10}} px={{8}} py={{4}} rounded={{6}} bg="{SURF}" stroke="{ERR if err else BOR}" opacity={{{0.45 if dis else 1}}}>{T("–",13,600,TX2)}{T(str(val),13,600)}{T("+",13,600,TX2)}</Frame>'
    h=T(hint,11,400,ERR if err else TX2) if hint else ''
    return vcol(T(label,11,500,TX2),box,h,gap=4,fill=False)
NAV=[("Fleet","•"),("Runtimes","•"),("Accounts","•"),("Toolchains","•"),("Diagnostics","•"),("Settings","•")]
LIGHTS='<Frame name="Traffic lights" position="absolute" x={14} y={14} flex="row" gap={8}><Frame name="Window dot red" w={12} h={12} rounded={6} bg="#FF5F57"/><Frame name="Window dot yellow" w={12} h={12} rounded={6} bg="#FEBC2E"/><Frame name="Window dot green" w={12} h={12} rounded={6} bg="#28C840"/></Frame>'
def sidebar(active,update=False,h=680):
    rows="".join(f'<Frame name="Nav: {n}" flex="row" w="fill" px={{12}} py={{8}} gap={{8}} rounded={{6}} bg="{ACC+"26" if i==active else SIDE}">{T(g,13,400,ACC if i==active else TX2)}{T(n,13,600 if i==active else 400,ACC if i==active else TX)}</Frame>' for i,(n,g) in enumerate(NAV))
    foot=(chip("Update available",ACC) if update else "")+f'<Frame name="Nav: Support" flex="row" w="fill" px={{12}} py={{8}} gap={{8}} rounded={{6}}>{T("★",13,400,"#7A5A00")}{T("Support kinhin",13)}</Frame>'
    top=f'<Frame name="Nav list" flex="col" w="fill" gap={{4}}>{T("kinhin",17,700)}{rows}</Frame>'
    return f'<Frame name="Sidebar" position="absolute" x={{0}} y={{0}} flex="col" justify="between" w={{200}} h={{{h}}} pl={{12}} pr={{12}} pb={{12}} pt={{44}} bg="{SIDE}">{LIGHTS}{top}<Frame name="Sidebar footer" flex="col" w="fill" gap={{8}}>{foot}</Frame></Frame>'
def window(active,name,content,h=680,w=1000,gated=False,update=False):
    sb="" if gated else sidebar(active,update,h)
    pl=24 if gated else 224
    return f'<Frame name="{name}" flex="col" w={{{w}}} h={{{h}}} bg="{BG}" rounded={{12}} stroke="{BOR}" pl={{{pl}}} pt={{24}} pr={{24}} pb={{24}} gap={{16}}>{sb}{LIGHTS if gated else ""}{content}</Frame>'
def sheet(name,title,body,w=480,footer=None,h=None):
    ft=footer if footer is not None else hrow(sp(),btn("Done","p"),gap=8)
    hh=f' h={{{h}}}' if h else ''
    return f'<Frame name="{name}" flex="col" w={{{w}}}{hh} p={{20}} gap={{14}} rounded={{12}} bg="{SURF}" stroke="{BOR}">{T(title,17,700,fill=True)}{body}{ft}</Frame>'
def alert(name,title,msg,btns,w=320):
    return f'<Frame name="{name}" flex="col" w={{{w}}} p={{20}} gap={{10}} rounded={{12}} bg="{SURF}" stroke="{BOR}">{T(title,13,700,fill=True)}{T(msg,12,400,TX2,fill=True)}{vcol(*btns,gap=6)}</Frame>'
import time
_cur={"id":None}
def _act():
    if os.environ.get("KFILE"): return
    subprocess.run(['osascript','-e','tell application "OpenPencil" to activate'],capture_output=True)
def _call(args,tries=4):
    for t in range(tries):
        _act()
        f=os.environ.get("KFILE")
        cmd=["openpencil","tool","call",args[0]]+([os.path.abspath(f),"--write"] if f else [])+args[1:]
        r=subprocess.run(cmd,capture_output=True,text=True)
        if "RPC timeout" in (r.stdout+r.stderr) or "MCP discovery" in (r.stdout+r.stderr):
            time.sleep(4); continue
        return r
    return r
def _pages():
    for _ in range(12):
        r=_call(["list_pages","--json"])
        try: return json.loads(r.stdout)["pages"]
        except Exception: time.sleep(5)
    raise RuntimeError("OpenPencil is not answering: open design/kinhin-app.fig and bring the app to the front")
def _pid(name):
    for p in _pages():
        if p["name"]==name: return p["id"]
def page(name):
    pid=_pid(name)
    if not pid:
        _call(["create_page","--args",json.dumps({"name":name})])
        pid=_pid(name)
    _cur["id"]=pid
import re
_S={3:4,5:4,6:8,7:8,9:8,10:8,11:12,13:12,14:16,15:16,18:16,22:24}
_R={3:4,5:6,7:8,9:8,10:12,11:12,13:12}
def _blend(c,a,base="FFFFFF"):
    return "#"+"".join("%02X"%round(int(c[i:i+2],16)*a+int(base[i:i+2],16)*(1-a)) for i in (0,2,4))
def _nm(s): return re.sub(r"[^\w ·—:\-./()…’']","",s).strip()[:36] or "Icon"
def _name(jsx):
    out=[];pos=0
    for m in re.finditer(r"<(Frame|Text)\b([^<>]*?)(/?)>",jsx):
        out.append(jsx[pos:m.start()]);pos=m.end()
        tag,attrs,selfc=m.group(1),m.group(2),m.group(3)
        if re.search(r"\bname=",attrs): out.append(m.group(0));continue
        if tag=="Text":
            e=jsx.find("</Text>",m.end()); nm=_nm(jsx[m.end():e])
        else:
            role="Row" if 'flex="row"' in attrs else ("Stack" if 'flex="col"' in attrs else "Shape")
            if selfc:
                nm="Spacer" if ('w="fill"' in attrs or "h={2}" in attrs) else ("Dot" if "bg=" in attrs else "Shape")
            else:
                close=jsx.find("</Frame>",m.end()); t=jsx.find("<Text",m.end())
                lab=""
                if t!=-1 and (close==-1 or t<close):
                    g=jsx.find(">",t)+1; lab=_nm(jsx[g:jsx.find("</Text>",g)])
                nm=f"{role}: {lab}" if lab else role
        out.append(f'<{tag} name="{nm}"{attrs}{selfc}>')
    out.append(jsx[pos:]); return "".join(out)
def prep(jsx):
    jsx=re.sub(r"\b(gap|px|py|p|pl|pr|pt|pb)=\{(\d+)\}",lambda m:f"{m.group(1)}={{{_S.get(int(m.group(2)),int(m.group(2)))}}}",jsx)
    jsx=re.sub(r"\brounded=\{(\d+)\}",lambda m:f"rounded={{{_R.get(int(m.group(1)),int(m.group(1)))}}}",jsx)
    jsx=re.sub(r'"#([0-9A-Fa-f]{6})([0-9A-Fa-f]{2})"',lambda m:f'"{_blend(m.group(1),int(m.group(2),16)/255)}"',jsx)
    return _name(jsx)
def render(jsx,x,y,label=""):
    jsx=prep(jsx)
    a={"jsx":jsx,"x":x,"y":y}
    if os.environ.get("KFILE"): a["parent_id"]=_cur["id"]
    r=_call(["render","--page-id",_cur["id"],"--args",json.dumps(a)])
    print(label,"ok" if '"id"' in r.stdout else (r.stderr+r.stdout)[-300:])
def clear(name):
    pid=_pid(name)
    r=_call(["get_page_tree","--page-id",pid,"--json"])
    for c in json.loads(r.stdout).get("children",[]):
        _call(["delete_node","--page-id",pid,"--args",json.dumps({"id":c["id"]})])
def dedupe(name):
    pid=_pid(name)
    r=_call(["get_page_tree","--page-id",pid,"--json"])
    seen={}
    for c in json.loads(r.stdout).get("children",[]): seen.setdefault(c["name"],[]).append(c["id"])
    for n,ids in seen.items():
        for d in ids[:-1]: _call(["delete_node","--page-id",pid,"--args",json.dumps({"id":d})]); print("dedupe",n)
CHECK='<Text name="check" size={12} weight={700} lineHeight={16} fontFamily="SF Pro Text" color="#FFFFFF" w={16} align="center">✓</Text>'
def chk(on,label):
    box=f'<Frame flex="row" w={{16}} h={{16}} items="center" justify="center" rounded={{4}} bg="{ACCT if on else SURF}" stroke="{ACCT if on else BOR}">{CHECK if on else ""}</Frame>'
    return hrow(box,T(label,13),fill=False,gap=8)
def slider(p,w=180):
    return f'<Frame flex="row" w={{{w}}} h={{4}} rounded={{2}} bg="{BOR}"><Frame w={{{int(w*p)}}} h={{4}} rounded={{2}} bg="{ACC}"/></Frame>'
def maturity(s): return chip(s,WARN)
def sub(title,*a): return vcol(T(title,11,600,TX2),*a,gap=8)

def cat(*a): return ''.join(a)
