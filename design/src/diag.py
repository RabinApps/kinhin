import sys;sys.path.insert(0,".")
from lib import *
def tabs(sel): return seg(["Health","Logs","Benchmarks","Containers","Tools"],sel)
def drow(title,detail,ok=True,warn=""):
    return f'<Frame flex="row" w="fill" px={{10}} py={{8}} gap={{10}} items="start" rounded={{6}} bg="{BG}">{dotc(OK if ok else ERR,10)}{vcol(T(title,13,600),T(detail,12,400,TX2,fill=True),T("⚠ "+warn,11,500,WARN,fill=True) if warn else "",gap=2,fill=True)}</Frame>'
def hitem(outcome,oc,when,detail,btns=(),adv=""):
    return f'<Frame flex="col" w="fill" p={{10}} gap={{4}} rounded={{6}} bg="{BG}">{hrow(chip(outcome,oc),T(when,11,400,TX2),sp(),*btns)}{T(detail,12,400)}{T(adv,11,400,TX2) if adv else ""}</Frame>'
health=card("Health","Checked 12:08 · probes run when you open Diagnostics",
  drow("Host","10 cores · 32 GB RAM · 210 GB free · Apple silicon")
 +drow("Command Line Tools","installed · 16.1")
 +drow("Tart (macOS VMs)","healthy · 0.31.0")
 +drow("Base image (macOS VMs)","tag ‘latest’ is mutable",True,"Pin a digest so rebuilds are reproducible.")
 +drow("Apple container (Linux)","image not built yet (kinhin image prepare --container)",False,"container is ad-hoc signed and its data is on an external volume (/Volumes/Fast/container). Install Apple's signed package instead, or re-grant after every upgrade.")
 +drow("Docker (Linux)","not installed — optional, runs Linux jobs (install it from Runtimes)")
 +drow("Image disk usage","kinhin-macos-15 62 GB · kinhin-linux 1.8 GB · 4 derived 11 GB")
 +drow("Unused images","2 images can be removed (3.2 GB): kinhin kinhin-old-1, kinhin-old-2")
 +drow("Capacity","6 VMs · 8 job slots — limited by memory",True)
 +drow("Disk pressure","Only 8 GB free — spawns are held",False)
 +drow("Isolation & transport","Softnet on · no warnings")
 +drow("Toolchain cache","3.4 GB cached")
 +drow("Storage · tart_home","/Volumes/Fast/tart · on /Volumes/Fast ✓")
 +drow("Storage · container_app_root","/Volumes/Slow/container — the volume does not have ownership enabled\nFix: run `sudo diskutil enableOwnership /Volumes/Slow`",False)
 +drow("Docker Hub cache","running at 127.0.0.1:5000 ✓ · 1.2 GB cached in ~/Library/Application Support/Kinhin/registry · TTL 168h")
 +drow("Docker Hub cache","running at 127.0.0.1:5000 ✓ · UNHEALTHY: 3 broken entries (pulls of them fail with unexpected EOF; the next Docker runner deletes them so they are fetched again): blobs/ab12, blobs/cd34, blobs/ef56 (+1 more)",False)
 +drow("Project images","Baking acme/api (go@1.22.5), using base meanwhile"),sbtn("Re-check"))
healing=card("Healing","Safe fixes run automatically; the rest wait for your approval.",
  status("Advisor: Claude Haiku")
 +T("Waiting for your approval",11,600,TX2)+hitem("Needs approval",WARN,"2 min ago","Free 3.2 GB by removing 2 unused images.",(btn("Approve","p"),btn("Dismiss")),"Advisor's reasoning: disk pressure blocks new VMs; these images are unused for 30+ days.")
 +T("Needs you",11,600,TX2)+hitem("Needs you",ERR,"12 min ago","Docker Desktop is not running — start it.",(btn("Dismiss"),))
 +T("Fixing now",11,600,TX2)+hitem("Running",ACC,"just now","Restarting the container service.")
 +T("Recent",11,600,TX2)+hitem("Fixed",OK,"yesterday","Rebuilt a stale derived image for acme/web.")+hitem("Fix failed",ERR,"2 days ago","Could not restart tart: permission denied.")
 +T("Nothing to fix so far.",11,400,TX2)
 +status("Off — kinhin does not fix problems on its own (healing.enabled is false).","warn"))
diag=head("Diagnostics","Health, logs, benchmarks and tools in one place.")+tabs("Health")+health+healing
page("Diagnostics");clear("Diagnostics")
render(window(4,"Diagnostics · Health",diag,h=2750),0,0,"health")
# logs
def logline(t,lvl,m,c): return hrow(T(t,11,400,TX2),T(lvl,11,700,c),T(m,12,400,c if c!=TX2 else TX),gap=10)
logs=head("Diagnostics","")+tabs("Logs")+card("Logs","",hrow(field("","Search logs (message, component, level)",ph=True,w=240),seg(["All","Info+","Warnings+","Errors"],"All"),chk(True,"Follow"),sp(),T("1,204 lines",11,400,TX2))
 +f'<Frame flex="col" w="fill" p={{12}} gap={{4}} rounded={{6}} bg="{BG}">{logline("12:04:11","INFO","runner vm-a1 started",TX2)}{logline("12:05:30","INFO","job acme/web build picked up",TX2)}{logline("12:07:02","WARN","forge poll slow (2.4s)",WARN)}{logline("12:07:44","ERROR","image not found: kinhin-linux",ERR)}{T("No log lines yet. · No lines match.",11,400,TX2)}</Frame>',hrow(sbtn("Open logs folder"),fill=False))
render(window(4,"Diagnostics · Logs",logs,h=700),1100,0,"logs")
# benchmarks
bench=head("Diagnostics","")+tabs("Benchmarks")+card("Run a benchmark","Last run 2 hours ago: macOS boot 41 s, Linux boot 4 s.",
  hrow(chk(True,"Boot"),chk(True,"Workload steps"),chk(False,"Toolchains"),gap=24)+hrow(seg(["Quick","Thorough"],"Quick"),sp(),btn("Run…","p"),btn("Cancel"))
 +status("A thorough toolchains run takes 15–30 minutes or more. Running pauses the fleet if VMs are live.","warn"))+card("Running","",hrow(T("",13,700,ACC),T("Step 2 of 4 — macOS boot",13),sp(),T("1:12",13,500)))+card("Boot comparison","Median of 3 runs",row("macOS (Tart) · clone","8.2 s")+row("macOS (Tart) · boot to ready","41 s")+row("Apple container · start","4.1 s")+row("Docker · start","2.7 s"))+card("History","10 most recent",row("Today 10:04 · Quick","Boot 41 s")+row("Yesterday 18:22 · Thorough","Toolchains 24 min"))
render(window(4,"Diagnostics · Benchmarks",bench,h=1100),0,2900,"bench")
# containers
cont=head("Diagnostics","")+tabs("Containers")+card("Containers","Tool",hrow(seg(["Apple container","Docker"],"Apple container"),sp(),sbtn("Refresh")),"")+card("Containers","",
  row("kinhin-runner-b1","CPU 80% · RAM 2/4 GB","kinhin-linux · pool big · running")+row("postgres-dev",hrow(sbtn("Stop"),sbtn("Restart"),sbtn("Delete…"),fill=False,gap=6),"postgres:16 · up 3 days"))+card("Volumes","",row("pgdata",sbtn("Delete…"))+T("No volumes.",11,400,TX2))
render(window(4,"Diagnostics · Containers",cont,h=800),1100,2900,"cont")
# tools tab
tools=head("Diagnostics","")+tabs("Tools")+card("Test a workflow","Run a workflow file locally before pushing",hrow(btn("Choose Workflow File…"),sp(),sbtn("Open"),gap=8))+card("Make a video","Launch videos built in a container",hrow(btn("Make a Video…"),sp(),status("Builds download the video image on first run.")))
render(window(4,"Diagnostics · Tools",tools,h=520),0,4150,"tools")
