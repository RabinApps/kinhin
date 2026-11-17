import sys;sys.path.insert(0,".")
from lib import *
def forgechip(n,sel,mat=""):
    ic=T("✓" if sel else "○",13,700,ACC if sel else TX2)
    return f'<Frame flex="row" px={{12}} py={{8}} gap={{8}} items="center" rounded={{8}} bg="{ACC+"1F" if sel else SURF}" stroke="{ACC if sel else BOR}">{ic}{T(n,13,500)}{maturity(mat) if mat else ""}</Frame>'
def wiz(step,title,sub,body,blocker="",cont="Continue",back=True,h=720):
    prog=hrow(*[chip(f"{i}",ACC if i==step else TX2,solid=(i==step)) for i in (1,2,3)],T(f"Step {step} of 3 — {title}",13,600),gap=8,fill=False)
    foot=hrow(sbtn("Skip for now") if step<3 else "",sbtn("Open config.yaml"),T(blocker,11,400,WARN) if blocker else "",sp(),btn("Back") if back else "",btn(cont,"p"),gap=10)
    return f'<Frame name="Setup · step {step}" flex="col" w={{820}} h={{{h}}} p={{28}} gap={{16}} bg="{BG}" rounded={{10}} stroke="{BOR}">{prog}{T(title,22,700)}{T(sub,13,400,TX2)}{body}<Frame w="fill" h={{1}}/>{foot}</Frame>'
page("Setup & Menu");clear("Setup & Menu")
s1=cat(T("Where does your code live?",13,600),hrow(forgechip("GitHub",True),forgechip("GitLab",False),forgechip("Gitea",False),forgechip("Forgejo",False),gap=8)+hrow(forgechip("Buildkite",False,"Untested"),forgechip("Azure DevOps",False,"Experimental"),forgechip("Bitbucket",False,"Untested"),gap=8),
  card("GitHub","Not connected yet.",hrow(field("Server address","github.com (optional)",ph=True,w=260),field("Access token","",secure=True,w=240),btn("Connect","p"),gap=12,items="end")+hrow(combo("Repository or org","Connect first to choose a repository",w=380),gap=8)+status("Not connected yet.","warn")))
render(wiz(1,"Connect your code","Pick every forge kinhin should serve and paste a token. It stays in your Keychain.",s1,"Connect GitHub and choose a repository, project or group (step 1).",back=False),0,0,"w1")
s2=card("macOS jobs (optional)","Run macOS workflows in disposable virtual machines powered by tart. Skip this if you only need Linux jobs.",row("tart","not installed",hrow(btn("Install…"),fill=False))+row("Base image","needs tart first",hrow(btn("Prepare image"),fill=False))+status("Prepare takes 20–60 min and downloads about 60 GB."))+card("Linux jobs (optional)","Pick where Linux jobs run.",hrow(btn("Set up Linux jobs…","p"),status("No Linux runtime is active."),gap=10)+chk(False,"Tart (Linux VM)")+hrow(chk(True,"Apple container"),maturity("Untested"),gap=8)+hrow(chk(False,"Docker"),maturity("Untested"),gap=8)+status("Preparing the runner image — this takes a while…")+hrow(sp(),btn("Cancel")))
render(wiz(2,"Get this Mac ready","Install what you need to run jobs. You can add more later in Runtimes.",s2,"Set up something to run jobs on (step 2): a Linux runtime (Docker or Apple container), or tart for macOS jobs."),900,0,"w2")
s3=card("Review","",code("Serving:\n  • acme @ github.com — GitHub\nRuns on: Apple container (Linux)\nImage: still being prepared (about 60 GB)\nCapacity: apple container 100%\n\nStill needed:\n  • nothing"))+row("Start the fleet automatically whenever kinhin opens",toggle(True))+card("Tune it (optional) ›","Split your capacity and see how toolchains work.",T("Only one runtime is enabled, so there's nothing to split.",12,400,TX2))
render(wiz(3,"Review & Start","Check the summary, then start. Change any of it later in Accounts and Runtimes.",s3,cont="Start fleet"),0,820,"w3")
fail=alert("Start failure","kinhin can't start the fleet yet","Connect a forge and choose where jobs run, then try again. The wizard is shown again.",[btn("Open setup","p"),btn("Cancel")])
render(fail,900,820,"fail")
# menu bar
def mrow(s,c=None,dim=False,k=""): return hrow(T(s,13,400,c),sp(),T(k,12,400,TX2),gap=8)
sep=f'<Frame w="fill" h={{1}} bg="{BOR}"/>'
def menu(name,lines,vms,upd,ctl):
    return f'<Frame name="{name}" flex="col" w={{360}} p={{8}} gap={{4}} rounded={{10}} bg="{SURF}" stroke="{BOR}">{T("kinhin",13,700,TX2)}{"".join(T(l,12,400,TX if i==0 else TX2) for i,l in enumerate(lines))}{sep}{T("VMs",11,600,TX2)}{"".join(T(v,12,400) for v in vms)}{sep}{mrow("Open kinhin")}{mrow("Setup…") if upd=="setup" else ""}{mrow("Settings…",k="⌘,")}{sep}{"".join(mrow(c,k=k) for c,k in ctl)}{sep}{mrow("Update available — kinhin 0.9.3…",ACC) if upd=="u" else ""}{T("kinhin 0.9.2"+(" (up to date)" if upd!="u" else ""),11,400,TX2)}{mrow("Open Logs")}{mrow("Support kinhin…")}{mrow("Quit",k="⌘Q")}</Frame>'
m1=menu("Menu · running",["Running — queue 3 · desired 4 · cap 6 · 8 job slots","auto-resume: when the queue is empty","Host CPU 34% · RAM 21 / 64 GB","queued: acme/api ×2, acme/web ×1","running: acme/api ×1, acme/web ×2","⚠ Couldn't apply your last settings change"],["  vm-a1 — busy — acme/web (build) · CPU 120% · RAM 3.2/8 GB","  vm-b2 — failed — ⚠︎ image not found: kinhin-li…","(click a VM to delete it — confirms first)"],"u",[("Stop Fleet","⌘K"),("Pause Fleet","⌘P")])
m2=menu("Menu · stopped",["Needs setup — open the Setup tab"],["  (no VMs)"],"setup",[("Start Fleet","⌘S")])
m3=menu("Menu · paused",["Paused — queue 0 · desired 0 · cap 6"],["  vm-a2 — warm — ready to claim"],"x",[("Stop Fleet","⌘K"),("Resume Fleet","⌘R")])
render(m1,0,1700,"m1");render(m2,420,1700,"m2");render(m3,840,1700,"m3")
glyphs=vcol(T("Menu bar glyph states",13,600),hrow(chip("○ idle / stopped",TX2),chip("○ 3 — three active VMs",OK),chip("○ paused (pause mark)",WARN),chip("working (spinner) while starting, stopping or updating the queue",ACC),gap=8),T("VoiceOver: “kinhin, not running”, “kinhin, 3 runners”, “…paused”, “…starting”.",11,400,TX2),gap=6)
render(f'<Frame name="Menu bar glyphs" flex="col" w={{760}} p={{16}} gap={{8}} rounded={{10}} bg="{SURF}" stroke="{BOR}">{glyphs}</Frame>',0,2500,"glyphs")
