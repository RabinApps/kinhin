import sys;sys.path.insert(0,".")
from lib import *
tel=card("Telemetry","Send metrics and traces to your own collector",
  row("Send telemetry",toggle(True),"Telemetry is on, exporting metrics, traces.")+row("Exported by","the daemon")+row("Prometheus URL","http://127.0.0.1:9464/metrics")
 +hrow(field("Prometheus address","127.0.0.1:9464",w=240),sbtn("Save"),sbtn("Refresh"),gap=8,items="end")+status("No export problems reported. · Export problem 12:01 (3 so far): connection refused","info")+status("Set OTEL_EXPORTER_OTLP_HEADERS for authenticated endpoints; a port-only value binds to localhost."))
alerts=card("Alerts","Webhooks for failures and healing events",
  row("Send alerts",toggle(True))+row("slack-ops",hrow(sbtn("Test"),sbtn("Edit"),sbtn("Remove"),fill=False,gap=6),"hooks.slack.com · warning+ · all events")+T("No webhooks yet. Add one to start receiving alerts.",11,400,TX2)+hrow(sbtn("Add webhook…"),sbtn("Refresh"),gap=8)+status("Test alert sent to slack-ops.","ok")+status("Webhook URLs are kept in config.yaml without their path. Tokens go in the Keychain."))
page("Settings");clear("Settings")
body=(head("Settings")
 +card("Launch","",row("Show at launch",seg(["Window + menu bar","Window only","Menu bar only"],"Window + menu bar"),"Window only hides the menu bar item and quits when you close the window.")+row("Launch kinhin at login",toggle(True))+row("Start the fleet when kinhin opens",toggle(True))+status("Applies to the installed kinhin.app — no effect while running from swift run."))
 +card("Updates","",row("kinhin 0.9.2 — last checked today 09:10",btn("Check for Updates…"),"Update available — kinhin 0.9.3 (you have 0.9.2)." )+status("Checking… · Up to date · Update check failed: …"))
 +card("Files","Everything here is saved in config.yaml — open it for settings that have no control.",row("config.yaml",sbtn("Open config file"))+row("Logs",sbtn("Open logs folder")))
 +tel+alerts
 +banner("warn","Stale daemon LaunchAgent: its binary is missing — run `kinhin daemon uninstall`.")
 +card("Daemon mode","Run the fleet inside this app, or in a background LaunchAgent that survives restarts.",row("Installed","Yes")+row("Running","Serving the fleet")+hrow(btn("Uninstall daemon…"),status("Installing…"),sp(),btn("Cancel"),gap=10)+status("couldn't find the kinhin CLI — install it with scripts/install.sh","error"))
 +card("Reset","",row("Reset kinhin…",btn("Reset kinhin…","x"),"Erase credentials, the daemon, or everything. Three confirmations.")+status("Resetting — deleting files, tokens and VMs…"))
 +card("Feedback","",hrow(btn("Report an issue"),T("Opens a GitHub issue in your browser.",11,400,TX2),gap=10))
 +card("Support kinhin","kinhin is free and built by one developer.",hrow(btn("Support kinhin…"),status("Opens the same sheet as the sidebar star."),gap=10)))
render(window(5,"Settings · full page",body,h=2900),0,0,"settings")
# alert webhook sheet
page("Sheets")
