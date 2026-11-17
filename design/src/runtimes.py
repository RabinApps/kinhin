import sys;sys.path.insert(0,".")
from lib import *
def rhead(name,color,chips,tog,sub):
    return hrow(dotc(color,12),vcol(T(name,15,700),T(sub,11,400,TX2),gap=2,fill=False),sp(),*chips,tog,gap=10)
def rcard(name,color,chips,tog,sub,body):
    return f'<Frame flex="col" w="fill" p={{16}} gap={{14}} rounded={{10}} bg="{SURF}" stroke="{BOR}">{rhead(name,color,chips,tog,sub)}{body}</Frame>'
# --- fleet capacity
cap=card("Fleet capacity","Applies to every runtime. Changes stage until you press Apply.",
  hrow(stepper("Most VMs at once",6),stepper("Fewest kept ready",1),stepper("Jobs per VM",1),stepper("Look for jobs every (s)",15),gap=28)
 +hrow(chk(True,"Resume on its own once the queue is empty"),chk(True,"Fresh VM for every job (recommended)"),gap=28)
 +T("Each VM",12,600,TX2)+hrow(stepper("CPU cores",4),stepper("Memory (GB)",8),gap=20,fill=False)+T("Keep free for your Mac",12,600,TX2)+hrow(stepper("CPU",2),stepper("Memory (GB)",4),stepper("Disk (GB)",20),gap=20,fill=False))
# --- split
def srow(name,color,default,p,inst):
    return hrow(dotc(color,10),T(name,13,500),chip("default",ACC) if default else "",sp(),sbtn("Lock"),slider(p),field("",f"{int(p*100)}%",w=54),T(inst,11,400,TX2),gap=10)
bar=f'<Frame flex="row" w="fill" h={{10}} rounded={{5}} gap={{2}}><Frame w={{350}} h={{10}} rounded={{5}} bg="{TART}"/><Frame w={{210}} h={{10}} rounded={{5}} bg="{CONT}"/><Frame w={{140}} h={{10}} rounded={{5}} bg="{DOCK}"/></Frame>'
split=card("Split between runtimes","Shares always total 100%. Drag or type a number; lock a pool to keep its share.",bar+hrow(T("POOL",11,600,TX2),sp(),T("SHARE",11,600,TX2),T("INSTANCES",11,600,TX2),gap=60)+srow("macOS (Tart)",TART,False,.5,"cap 2")+srow("Linux (Apple container)",CONT,True,.3,"cap 4")+srow("Docker",DOCK,False,.2,"cap 2")+status("Capped at 50% — macOS (Tart) is locked.","warn")+banner("error","A route to Docker would have 0 capacity at this split."),sbtn("Instance counts update once you Apply") )
# --- tart
named=lambda n,warm,idle,ready: hrow(T(n,13,600),status("ready ✓" if ready else "not prepared yet","ok" if ready else "warn"),sp(),sbtn("Rebuild…" if ready else "Prepare"),sbtn("Remove"))+hrow(field("Run jobs with labels","xcode",w=160),combo("Base image","macos-tahoe-xcode:latest",w=300),stepper("VMs kept ready",warm),stepper("Keep idle",idle),gap=16,items="end")
tart=rcard("macOS (Tart)",TART,[chip("ready",OK)],toggle(True),"labels: self-hosted, macos, arm64",
  row("tart","installed ✓","Homebrew · /opt/homebrew/bin/tart")
 +hrow(combo("Base image","ghcr.io/cirruslabs/macos-tahoe-base:latest",w=380),sbtn("Pin…"),sbtn("Rebuild image…"),status("Ready ✓","ok"),gap=10,items="end")
 +status("Rebuilding takes 20–60 min and downloads about 60 GB.")
 +hrow(stepper("Keep idle",1,"macOS allows 2 VMs per Mac across all images",False),stepper("Warm VMs",1,"Booted but unregistered; ≤ most VMs at once"),gap=28,items="start")
 +T("More images",12,600,TX2)+named("xcode",1,1,True)+named("lint-small",0,2,False)+hrow(field("","New image name",ph=True,w=160),combo("","macos-tahoe-xcode:latest",w=300),sbtn("Add image"),gap=8)
 +status("macOS allows 2 VMs per Mac: your idle floors add up to 4 (default 1 + xcode 1 + lint-small 2 = 4).","error")
 +chk(False,"Also serve Linux jobs with tart (Linux VM)")+status("Tart Linux serves jobs with the macos label removed.")
 +hrow(maturity("Untested"),fill=False))
# --- apple container
pool=lambda n,built,det,img: f'<Frame flex="col" w="fill" p={{12}} gap={{4}} rounded={{8}} bg="{BG}">{hrow(T(n,13,600),chip("built" if built else "not built",OK if built else WARN),sp(),sbtn("Edit…"),sbtn("Remove"))}{T(det,11,400,TX2)}{T(img,11,400,TX2)}{"" if built else status("Not built yet, so its jobs wait. Build it: kinhin image prepare --container --pool "+n,"warn")}</Frame>'
cont=rcard("Linux (Apple container)",CONT,[chip("ready",OK),chip("default",ACC),maturity("Untested")],toggle(True,True),"labels: self-hosted, linux, arm64 · kinhin-container",
  row("Container service","installed ✓ · service running")
 +hrow(combo("Base image","kinhin-linux:latest",w=300),sbtn("Build image…"),status("Built ✓","ok"),gap=10,items="end")
 +hrow(stepper("Keep idle",1,"Used by the default pool"),stepper("CPU / memory per instance","4 · 8 GB"),gap=28,items="start")
 +T("Pools",12,600,TX2)+pool("big",True,"4 vCPU · 16 GB · at most 2 at once · min idle 1 · Docker on · takes unmatched jobs","image: kinhin-big:latest")+pool("small",False,"2 vCPU · 4 GB · at most 4 at once · min idle 0 · Docker off","image: kinhin-small:latest")+sbtn("Add Container Pool…")
 +T("The default pool and any pool a route names stay on.",11,400,TX2))
# --- docker
dock=rcard("Docker",DOCK,[chip("needs attention",WARN),maturity("Untested")],toggle(True),"labels: self-hosted, linux, arm64 · kinhin-docker",
  banner("warn","Docker Desktop isn't running.",sbtn("Open Docker"))
 +hrow(combo("Base image","kinhin-ci-linux:latest",w=300),sbtn("Build image…"),gap=10,items="end")
 +hrow(combo("Architecture","arm64 (native)",w=180),stepper("Most at once",3,"docker.max_slots"),stepper("Keep idle",5,"Exceeds most at once (3)",True),gap=28,items="start")
 +status("Rebuild the Docker image after changing architecture.")
 +T("Not installed variant: toggle disabled, ‘Docker isn't installed — optional.’ with Install… (Homebrew or download).",11,400,TX2))
host=rcard("Host (this Mac)",HOST,[chip("unisolated",ERR)],"","Runs jobs directly on your Mac, no isolation. Used only by routes you add.",T("No enable switch — add a route to a repo you trust. Each Host route needs explicit consent.",13,400,TX2))
# --- routes
def route(p,rt,warn=False): return row(p,hrow(chip(rt,TX2),chip("unisolated",ERR) if warn else "",sbtn("Remove"),fill=False,gap=6),"")
routes=card("Routes","Send a repository, or one workflow, to a runtime.",route("acme/api","Apple container")+route("acme/web@Release Build","macOS (Tart)")+route("acme/legacy","Host",True)+hrow(sbtn("Add Route…"),T("No routes — every job uses the default pool.",11,400,TX2),gap=10)
 +hrow(combo("Jobs with no route run on","Linux (Apple container)",w=280),T("The default pool also keeps whatever share the others leave.",11,400,TX2),gap=12,items="end")
 +hrow(field("Fleet base labels (every runner)","self-hosted, kinhin",w=330),field("Container extra labels","big, gpu",w=330),gap=16,items="start")
 +status("Jobs must request a subset of these via runs-on.")
 +hrow(sbtn("Edit YAML…"),T("Every setting without a control lives in config.yaml.",11,400,TX2),gap=10))
bar2=f'<Frame flex="row" w="fill" px={{16}} py={{10}} gap={{12}} items="center" rounded={{10}} bg="{SURF}" stroke="{WARN}">{status("2 unapplied changes — Apply restarts the fleet if needed.","warn")}{sp()}{btn("Revert")}{btn("Apply","p")}</Frame>'
body=head("Runtimes","Where jobs run, how many, and how they're routed.")+cap+split+tart+cont+dock+host+routes+bar2
page("Runtimes");clear("Runtimes")
render(window(1,"Runtimes · full page",body,h=2780),0,0,"runtimes")
# --- empty/load error variants
page("Runtimes")
err=head("Runtimes","Config problem")+banner("error","config.yaml has a problem — runtimes: unknown key ‘docker.max_slot’. Fix it with Edit YAML…",sbtn("Edit YAML…"))+card("","",T("Capacity and routing are read-only until config.yaml loads.",13,400,TX2))
render(window(1,"Runtimes · config unreadable",err,h=400),1100,0,"err")
single=head("Runtimes","Single runtime")+cap+card("Split between runtimes","",T("Only one runtime is enabled, so there's nothing to split. Enable another to share capacity.",13,400,TX2))+tart
render(window(1,"Runtimes · single runtime",single,h=1500),1100,500,"single")
