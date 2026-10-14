# Troubleshooting videos

The messages a video build is most likely to print, and what to do. Find the text your build printed in the left column.

[← Back to Add videos to your project](videos-for-your-project.md) · [Config reference](video-config.md) · [Recordings](video-adapters.md)

The build prints the pipeline's own output as it runs. Read the whole log, not only the last line: the line above the failure
usually says why. `kinhin doctor` checks your container runtimes.

| You see | What to do |
|---|---|
| `videos build in a container, and neither Apple's container nor Docker is running` | Start one: `container system start` (install with `brew install container`), or open Docker Desktop. `--runtime container` or `--runtime docker` forces one and says why it is not usable. |
| `kinhin video validate` lists problems and exits 3 | Each line names the scene or setting and what is wrong. Nothing was rendered, so fix the file and run `kinhin video validate` again. |
| `this video image predates 'kinhin video validate'` | The image for your kinhin version is older than the check. Update kinhin, or pass `--image` with a newer image. |
| `no .kinhin/videos/ in <path>` or `no video "x"` | You are in the wrong directory, or the file is missing. `kinhin video list` shows what is found. `kinhin video init x` creates it. `--dir PATH` points at another repository. |
| `could not get the video image ghcr.io/...` | Check the network. The image for your kinhin version must be published: a development build of kinhin has no published image, so pass `--image` or set `KINHIN_VIDEO_IMAGE`. If the package is private, sign in with `docker login ghcr.io`. |
| The build stops with a message from the pipeline | The log above the final line says why: a scene with no `id`, an unknown theme (the message lists the ones that exist), a clip that is not in the adapter, or a claim that `claims.json` forbids. Fix the config and run the build again. Scenes you did not change come from the render cache, so the rerun is fast. |
| `no space left` or `read-only file system` | The image is about 1 GB and a build needs a few GB free. Free disk space. Apple's `container` keeps its images and builder cache under your home folder; `docker system prune` frees Docker's. |
| `scene "x": no clip "app" in the acme adapter` | The adapter does not declare that clip, or its file is missing. Add the clip to `.kinhin/videos/adapters/<name>/adapter.yml` and put the recording at `reference/<clip>.mp4` (a terminal clip may also have `-dark`, `-portrait` and `-dark-portrait` variants). See [Recordings](video-adapters.md#the-adapter-folder). |
| `theme "x": ... is missing` or `... must be a colour` | A theme file in `.kinhin/videos/themes/` is incomplete. Add `extends: midnight` (or another theme) and write only what you change. Colours are `#rrggbb`. The message names every problem at once. See [Your own theme](video-config.md#your-own-theme). |
| `"Windows" is planned, not shipped` (a claims failure) | A scene mentions something your `claims.json` lists as planned without saying so, or it uses a forbidden word. Reword the line, or say that it is planned. See [Keep it honest](video-adapters.md#keep-it-honest). |
| A music file or font is not found | Paths are relative to your repository, and the repository is mounted read-only in the container. Check that the file is committed and inside the repository, and that its extension is mp3, m4a, wav, flac or ogg. Fonts go in `.kinhin/videos/fonts/`. |
| `music search` says the library is rate limiting | Anonymous use allows about 20 searches a minute and 200 a day. Wait, or set `KINHIN_OPENVERSE_CLIENT_ID` and `KINHIN_OPENVERSE_CLIENT_SECRET` from a free Openverse application. Tracks built into the image still show up offline. |
| `add` refuses a track: `is licensed ..., which kinhin does not put in a video` | Only CC0 and public-domain tracks are accepted, and CC BY with `--license cc-by`. Non-commercial, no-derivatives and share-alike tracks are never added. Pick another result. |
| `add` says `which video?` or `there is no video` | Name the video with `--video <name>` when the folder has several, or run `kinhin video init` first. `--no-config` only downloads the track. |
| `did not download the track` | The file is over 50 MB, is not mp3, m4a, wav, flac or ogg, is not served over https, or its source link is gone. Try another result. `preview` shows the source page. |
| `--on-fleet`: `kinhin-video.yml is not on <branch>` | Run `kinhin video init --workflow`, commit and push the file, then try again. `--on-fleet` also needs `gh` signed in (`gh auth login`) and a runner with Docker that matches `--runs-on`. |

Still stuck? Open an issue with the full build log, with any token or key removed.
