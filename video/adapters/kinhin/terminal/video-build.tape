# The video-build scene of the kinhin adapter. Recorded by video/scripts/record-terminal.sh --adapter kinhin --clip video-build
# (it fills in the Output and Set lines for each variant); needs vhs, ttyd, ffmpeg and Docker with a video image.
# It runs the real `kinhin video init` and `kinhin video build` from this checkout's debug build, in a throwaway repository.
# The build takes about half a minute, so the middle of it is cut (Hide/Show): the clip jumps from the first log lines to the finish.
# VIDEO_IMAGE names the image to build with (for example kinhin-video:local after `docker build -t kinhin-video:local video/`).
Output raw/video-build-uncut.mp4
Set Shell "bash"
Set FontSize 34
Set Width 1920
Set Height 1080
Set Padding 80
Set Theme "Builtin Light"
Set TypingSpeed 40ms

Hide
Type "export KINHIN_SUPPORT_DIR=$(mktemp -d) KINHIN_TOKEN_STORE=env PATH=$VIDEO_REPO_ROOT/.build/out/Products/Debug:$PATH" Enter
Type "export KINHIN_VIDEO_IMAGE=${VIDEO_IMAGE:-kinhin-video:local} PS1='$ '; cd $(mktemp -d) && git init -q" Enter
Type `kinhin() { if [ "$2" = build ]; then command kinhin "$@" --runtime docker; else command kinhin "$@"; fi; }; clear` Enter
Sleep 1s
Show

Type "kinhin video init launch"
Sleep 400ms
Enter
Sleep 1.5s
Type "kinhin video build launch --music first-light-particles"
Sleep 400ms
Enter
Sleep 5s
Hide
Sleep 210s
Show
Sleep 3s
