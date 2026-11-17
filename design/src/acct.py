import sys;sys.path.insert(0,".")
from lib import *
def forgechip(n,sel,mat=""):
    ic=T("✓" if sel else "○",13,700,ACC if sel else TX2)
    return f'<Frame flex="row" px={{12}} py={{8}} gap={{8}} items="center" rounded={{8}} bg="{ACC+"1F" if sel else SURF}" stroke="{ACC if sel else BOR}">{ic}{T(n,13,500)}{maturity(mat) if mat else ""}</Frame>'
chips=vcol(T("Where does your code live?",13,600),T("Select every forge kinhin should serve; each gets its own card below.",11,400,TX2),hrow(forgechip("GitHub",True),forgechip("GitLab",True),gap=8),hrow(forgechip("Gitea",True),forgechip("Forgejo",False),gap=8),hrow(forgechip("Buildkite",False,"Untested"),forgechip("Azure DevOps",False,"Experimental"),gap=8),hrow(forgechip("Bitbucket",False,"Untested"),gap=8),gap=8)
perm=lambda n,lines: f'<Frame flex="col" w="fill" p={{10}} gap={{4}} rounded={{6}} bg="{BG}">{T("Token permissions needed ⌄",12,600)}{T(n,11,600,TX2)}{"".join(T("• "+l,11,400,TX2) for l in lines)}{sbtn("Create token…")}</Frame>'
def forge(name,st,stk,instance,inst_dis,scope,scope_dis,btn_t,extra=""):
    return card(name,"",
      status(st,stk)
     +hrow(field("Server address",instance,dis=inst_dis,w=300),field("Access token","",secure=True,w=240),btn(btn_t,"p"),gap=12,items="end")
     +hrow(combo("Repository or org",scope,w=340),status("Pick from the repos your token can see, or type an org name.") ,gap=12,items="end")
     +extra,sbtn("Remove"))
gh=forge("GitHub","Connected ✓ — 24 repositories visible. Pick one below.","ok","github.com (optional)",True,"acme",False,"Replace",
   status("Token stored in your Keychain ✓ — paste a new one only to replace it.")+perm("Fine-grained token",["Repository: Actions (read), Administration (read & write)","Organization: Self-hosted runners (read & write)"]))
gt=forge("Gitea","That token didn't work — 401 unauthorized. It needs: repo, read:org.","error","https://gitea.example.com",False,"Connect first to choose a repository",True,"Connect",
   perm("Access token",["repository: read/write","organization: read","Create at https://gitea.example.com/user/settings/applications"]))
more=card("More accounts…","Serve additional accounts (another org, a second server, a GitLab group) with their own tokens.",
  row("GitHub · client-b @ github.example.com",hrow(sbtn("Remove"),fill=False),"No token yet — paste one to connect.")
 +hrow(field("","Paste a GitHub access token",ph=True,secure=False,w=300),btn("Connect","p"),gap=8)
 +T("Add an account",13,600)+hrow(combo("Forge","GitLab",w=160),field("Name","work",w=140),field("Group or project","acme/platform",w=240),gap=12,items="end")+hrow(field("Server (required for Gitea, Forgejo, Azure DevOps)","https://gitlab.com (optional)",w=420),gap=12,items="end")+perm("Group access token",["api","read_repository"])+hrow(btn("Add account"),status("Added ‘work’ — paste its token below.","ok"),gap=10))
accounts=head("Accounts","Where kinhin picks up jobs. Tokens live in your Keychain, never in a file.")+chips+gh+gt+more
page("Accounts");clear("Accounts")
render(window(2,"Accounts · full page",accounts,h=1560),0,0,"acct")
accerr=head("Accounts","")+banner("error","config.yaml has a problem — accounts: duplicate name ‘github’. Fix it in Runtimes → Edit YAML.",sbtn("Open config"))+card("More accounts…","The add form is hidden until config.yaml loads.","")
render(window(2,"Accounts · config error",accerr,h=380),1100,0,"acct-err")
confirm=alert("Remove confirmation","Stop serving GitHub?","This removes its account and token.",[btn("Remove account and token","x"),btn("Cancel")])
render(confirm,1100,500,"confirm")
# ---- toolchains
def tcard(title,src,txt,tools,brew,stacks,base,derived):
    chips=lambda l,vals: hrow(T(l,11,600,TX2),*[chip(v,TX2) for v in vals],gap=6,fill=False)
    body=T(txt,12,400,TX2)+(chips("Tools",tools) if tools else "")+(chips("Homebrew",brew) if brew else "")+(chips("Stacks",stacks) if stacks else "")+T(base,11,400,TX2)+"".join(T(d,11,400,TX2) for d in derived)
    return f'<Frame flex="col" w="fill" p={{12}} gap={{6}} rounded={{8}} bg="{BG}">{hrow(T(title,13,600),sp(),T(src,11,500,TX2))}{body}</Frame>'
guide=card("How toolchains work","Nothing is chosen in this app — repos describe what they need.",
  T("Every repo needs its own toolchains. kinhin reads them from the repo or from config.yaml and bakes a derived image.",12,400,TX2)
 +hrow(vcol(T(".kinhin/config.yml (in the repo)",11,600),code("toolchains:\n  tools: [node@22, go@1.23]"),sbtn("Copy"),gap=4),vcol(T("config.yaml: repo_file: true",11,600),code("repo_file: true"),sbtn("Copy"),gap=4),vcol(T("config.yaml: toolchains.specs",11,600),code("toolchains:\n  specs: ..."),sbtn("Copy"),gap=4),gap=12,items="start")
 +hrow(T("Repos with neither get the plain base image.",11,400,TX2),status("Read the docs: per-project toolchains","info"),gap=12),sbtn("Collapse"))
repos=card("Repos","3 repos use derived images",
  tcard("acme/web",".kinhin/config.yml honored","Toolchains come from the repo's .kinhin/config.yml.",["node@22","pnpm"],["jq"],[],"Base image: kinhin-macos-15 · 62 GB",["Derived image: kinhin-web-abc123 · 9.1 GB · last used 2 hours ago"])
 +tcard("acme/api","Project toolchains","Toolchains come from config.yaml.",["go@1.23"],[],["backend"],"Base image: kinhin-linux · 1.8 GB",["Derived image: kinhin-api-def456 · 0.9 GB · last used yesterday"])
 +tcard("Other repos","No toolchains baked","These repos get the plain base image.",[],[],[],"Base image: kinhin-linux · 1.8 GB",[])
 +status("config.yaml could not be read; see the message below.","error"))
rfi=card("Images from .kinhin/config.yml files","Derived images that no fixed toolchain list accounts for.",row("kinhin-tools-9f2a","1.1 GB","Last used 3 days ago"))
base=card("Base images","Rebuilt per runtime. The base image itself is chosen in Runtimes.",
  row("macOS image (Tart)",sbtn("Rebuild base image…"))+row("Linux image (Apple container)",sbtn("Rebuild base image…"),"Base image: kinhin-linux")+row("Linux image (Docker)",sbtn("Rebuild base image…"),"Base image: kinhin-ci-linux")
 +hrow(T("Rebuilding the Linux image (Apple container)… this can take a while.",13),status("working"),sp(),btn("Cancel"),gap=10)+status("Rebuilt the Linux image ✓ · Cancelled — the previous image is untouched · Not rebuilt — …","info"))
cat=card("Catalog","What you can ask for. Copy a line into a repo's .kinhin/config.yml.",
  hrow(chip("Languages",TX2),chip("Build tools",TX2),chip("Databases",TX2),chip("Stacks",TX2),chip("Examples",TX2),gap=6)
 +row("node","22.x",  "macOS · Linux · Requires: none")+row("flutter (stack)","3.x","macOS only · needs Xcode image")+hrow(sbtn("Copy"),T("Examples: Go + Node · Web app with pnpm and Playwright · Flutter · Expo · JVM with Gradle",11,400,TX2),gap=10)
 +T("How images bake: first job for a repo builds a derived image from the base plus its toolchains; later jobs reuse it.",11,400,TX2))
tool=head("Toolchains","What every runner image has installed.")+guide+repos+rfi+base+cat
page("Toolchains");clear("Toolchains")
render(window(3,"Toolchains · full page",tool,h=1350),0,0,"tool")
