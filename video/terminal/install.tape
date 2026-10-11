# The install scene. Run from video/: vhs terminal/install.tape  (needs vhs, ttyd, ffmpeg)
# It types the real install one-liner but does not run it; the CLI part
# runs the real `kinhin` on this Mac.
Output raw/install.mp4
Set Shell "bash"
Set FontSize 34
Set Width 1920
Set Height 1080
Set Padding 80
Set Theme "Builtin Light"
Set TypingSpeed 55ms

Type "curl -fsSL https://github.com/RabinApps/kinhin/releases/latest/download/install.sh | bash"
Sleep 2s
Ctrl+C
Hide
Type "clear" Enter
Show
Type "kinhin doctor"
Sleep 600ms
Enter
Sleep 6s
Type "clear" Enter
Type "kinhin start"
Sleep 600ms
Enter
Sleep 4s
