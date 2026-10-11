# The install scene. Run from video/: vhs terminal/install.tape  (needs vhs, ttyd, ffmpeg)
# It types the real install one-liner but does not run it, then runs the real `kinhin doctor` from this
# checkout's debug build against a throwaway support dir (no real config, no Keychain). The empty-config
# lines at the bottom of the output are masked afterwards by terminal/trim.sh.
Output raw/install-uncut.mp4
Set Shell "bash"
Set FontSize 34
Set Width 1920
Set Height 1080
Set Padding 80
Set Theme "Builtin Light"
Set TypingSpeed 40ms

Hide
Type "export KINHIN_SUPPORT_DIR=$(mktemp -d) KINHIN_TOKEN_STORE=env PATH=$PWD/../.build/out/Products/Debug:$PATH" Enter
Type `kinhin() { command kinhin "$@" 2>/dev/null; }; kinhin doctor >/dev/null; clear` Enter
Sleep 4s
Show

Type "curl -fsSL https://github.com/RabinApps/kinhin/releases/latest/download/install.sh | bash"
Sleep 1.5s
Ctrl+C
Hide
Type "clear" Enter
Show
Type "kinhin doctor"
Sleep 600ms
Enter
Sleep 5s
