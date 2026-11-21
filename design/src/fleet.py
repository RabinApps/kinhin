import sys;sys.path.insert(0,".")
from lib import *
PH={"busy":("▶",OK),"warm":("◆",WARN),"ready":("✓",OK),"booting":("…",ACC),"cloning":("…",ACC),"registering":("…",ACC),"deleting":("×",TX2),"failed":("⚠",ERR)}
def inst(name,ph,detail,pipeline=False,err=False):
    g,c=PH[ph]
    d=T(detail,11,400,ERR if err else TX2)
    right=(sbtn("Pipeline") if pipeline else "")+sbtn("Delete")
    return f'<Frame flex="row" w="fill" px={{10}} py={{7}} gap={{10}} items="center" rounded={{6}} bg="{BG}">{T(g,13,700,c)}{T(name,13,500)}{T(ph,11,600,c)}{d}{sp()}{right}</Frame>'
def lane(name,color,cnt,rows,extra=""):
    return card(name,cnt,vcol(*rows,gap=6),dotc(color,10)+extra)
def modebadge(s): return f'<Frame flex="row" px={{8}} py={{3}} rounded={{6}} bg="{SIDE}" stroke="{BOR}">{T(s,11,500,TX2)}</Frame>'
def header(state,sc,mode,btns,sub=""):
    return head("Fleet",sub,hrow(chip(state,sc),modebadge(mode),sp(),*btns,fill=False,gap=8))
STATUSLINES=vcol(T("Queue 3 · Desired 4 · Cap 6 · 8 job slots",13,500),status("Queue age 42s · checking every 15s"),status("Host CPU 34% · RAM 21 / 64 GB"),status("↳ queued: acme/api ×2, acme/web ×1"),status("▶ running: acme/api ×1, acme/web ×2"),gap=3)
def qrow(pos,title,detail): return f'<Frame flex="row" w="fill" gap={{8}} items="center">{T("#"+str(pos),11,400,TX2)}{T(title,13,400)}{sp()}{T(detail,11,400,TX2)}</Frame>'
QUEUE=vcol(qrow(1,"build — acme/api","github · acme"),qrow(2,"test — acme/web","github · acme"),qrow(3,"lint — acme/api","github · acme"),T("… and 2 more",11,400,TX2),gap=4)
def queued(daemon=False):
    if daemon:
        body=vcol(T("3 queued · acme/api ×2, acme/web ×1",13,500),QUEUE,status("Requeue and Skip need forge access, which the daemon does not give the app. Use kinhin requeue or kinhin skip, or switch to the in-process engine.","warn"),gap=4)
    else:
        body=vcol(T("3 queued · acme/api ×2, acme/web ×1",13,500),QUEUE,row("GitHub · acme",hrow(sbtn("Requeue"),sbtn("Skip"),fill=False),"3 queued"),row("GitLab · group/x",hrow(sbtn("Requeue"),sbtn("Skip"),fill=False),"0 queued"),gap=6)
    return card("Queued work","Oldest first (first in, first out). Counts per forge; actions apply to every queued job on that forge",body)
def jobs():
    return card("Current jobs","",vcol(row("build — acme/web","runner-a1 · busy"),row("test — acme/api","vm-b1 · runner 1 · busy"),row("lint — acme/api","vm-b1 · runner 2 · busy"),row("Running a job","kinhin-3 · busy"),gap=6))
def running(daemon):
    c=header("Running",OK,"background daemon" if daemon else "in-process engine",[btn("Pause"),btn("Stop")])
    c+=banner("warn","Disk is almost full — new VMs are held until space frees up.",sbtn("Dismiss"))
    c+=banner("error","Couldn't apply your last settings change: config.yaml: max_runners must be ≥ min_runners.")
    if daemon: c+=banner("warn","Stale daemon LaunchAgent: its binary is missing — run `kinhin daemon uninstall`.")
    c+=card("","",STATUSLINES)
    c+=status("Baking image for acme/api (go@1.22.5), using base meanwhile.")
    c+=lane("macOS (Tart)",TART,"3 instances · cap 2",[inst("vm-a1","busy","acme/web · build · CPU 120% · RAM 3.2/8 GB",True),inst("vm-a2","warm","ready to claim"),inst("vm-a3","booting","cloning image…")])
    c+=lane("Linux (Apple container)",CONT,"2 instances · cap 4",[inst("vm-b1","busy","pool big · acme/api · 2 jobs: test, lint · CPU 80% · RAM 2/4 GB",True),inst("vm-b2","failed","⚠︎ image not found: kinhin-linux",err=True)])
    c+=lane("Docker",DOCK,"idle",[],"")
    c+=jobs()+queued(daemon)
    return c
page("Fleet");clear("Fleet")
render(window(0,"Fleet · Running (in-process)",running(False),h=1500),0,0,"run")
render(window(0,"Fleet · Running (daemon)",running(True),h=1560),1100,0,"daemon")
paused=header("Paused",WARN,"in-process engine",[btn("Stop"),btn("Resume","p")])+status("Auto-resume is on — the engine resumes on its own once the queue is empty.")+card("","",vcol(T("Queue 0 · Desired 0 · Cap 6 · 8 job slots",13,500),gap=3))+lane("macOS (Tart)",TART,"1 instance · cap 2",[inst("vm-a2","warm","ready to claim")])+card("Current jobs","",T("No jobs running.",13,400,TX2))
render(window(0,"Fleet · Paused",paused,h=620),0,1650,"paused")
stopped=header("Stopped",TX2,"in-process engine",[btn("Start","p")])+card("","",T("Fleet is stopped. Start it to pick up queued jobs.",13,400,TX2))+card("Runtimes","",T("No runtimes — the fleet is idle.",13,400,TX2))
render(window(0,"Fleet · Stopped",stopped,h=420),1100,1650,"stopped")
unreach=header("Not responding",ERR,"background daemon",[btn("Stop"),btn("Start","p")])+banner("error","Fleet not responding — the daemon socket did not answer within 5s.")+card("Runtimes","",T("Fleet not responding — check the daemon in Settings → Daemon.",13,400,TX2),"")
render(window(0,"Fleet · Not responding",unreach,h=420),0,2300,"unreach")
setup=header("Needs setup",WARN,"—",[btn("Set up…","p")])+card("","",T("Needs setup — finish the first-run wizard to connect a forge and choose where jobs run.",13,400,TX2))
render(window(0,"Fleet · Needs setup",setup,h=420),1100,2300,"setup")
# starting / stopping in-flight
inflight=header("Stopping…",WARN,"in-process engine",[btn("Stopping…"),btn("Pause")])+card("","",T("Stopping the fleet… (controls disabled)",13,400,TX2))
render(window(0,"Fleet · In-flight",inflight,h=360),0,2850,"inflight")
