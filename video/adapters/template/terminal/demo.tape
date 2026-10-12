# A terminal clip for your product. scripts/record-terminal.sh fills in the Output and Set lines (size, padding, theme)
# for each variant (light or dark, landscape or portrait); everything else is yours. $VIDEO_REPO_ROOT is the repository.
Output raw/template/demo-uncut.mp4
Set Shell "bash"
Set FontSize 34
Set Width 1920
Set Height 1080
Set Padding 80
Set Theme "Builtin Light"
Set TypingSpeed 40ms

Type "echo 'hello from my product'"
Sleep 400ms
Enter
Sleep 1s
Type "ls"
Sleep 400ms
Enter
Sleep 2500ms
