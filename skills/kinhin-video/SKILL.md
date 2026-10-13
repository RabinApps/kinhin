---
name: kinhin-video
description: Make a narrated product video (launch film, feature clip, vertical cut, README GIF) from a config in the user's repository with `kinhin video` - write .kinhin/videos/*.yml, pick themes, captions and music, search CC0 music, build in a container, or build on the fleet. Use when the user wants a demo, launch or marketing video of their own product.
---

# Make a video of the user's product

**Beta status:** `kinhin video` builds on this Mac in a container (Apple `container` or Docker) from a published image that
holds the whole video suite, so the user copies nothing into their repository. `--on-fleet` (GitHub only) is unit-tested but
has not run against a real runner. Run `kinhin help video` if a flag here is rejected. Full guide:
`docs/videos-for-your-project.md`.

## The loop

| Task | Command |
| --- | --- |
| Create a starter video | `kinhin video init <name> [--dir PATH]` (writes `.kinhin/videos/<name>.yml` and a `.gitignore`) |
| List the videos | `kinhin video list [--json]` |
| Build one | `kinhin video build <name> [--fast] [--theme T] [--format 16:9\|9:16\|4:5\|1:1] [--captions on\|off\|all] [--music TRACK\|off]` |
| Pick the runtime or image | `--runtime container\|docker`, `--image REF` (or `KINHIN_VIDEO_IMAGE`) |
| Build on a runner | `kinhin video init --workflow --runs-on LABELS`, commit and push it, then `kinhin video build <name> --on-fleet` |

The result is in `.kinhin/videos/out/<name>/` (`<name>.mp4`, `.webm`, `-poster.png`, `-hero.gif`, `.srt`). Use `--fast` while
iterating; unchanged scenes come from the render cache. Never open the MP4 and judge it blind: run a build, then read
the log and the `.srt`, and tell the user where the files are.

## The config (`.kinhin/videos/<name>.yml`)

A video is a name, a theme, a format, a voice and typed scenes, each with the words the narrator says (`narration`). The
pictures follow the voice, so editing a line re-times the scene.

- **Scene types:** `title`, `statement`, `queue`, `parallel`, `map`, `outro`, `stats`, `steps`, `code`, `compare` (drawn, no
  recording needed), and `device` / `terminal` (a recorded clip from an adapter). Every scene needs an `id`, a `type`,
  `props` and `narration` (or timed `cues`). `docs/videos-for-your-project.md` lists each type's props.
- **Voice:** `voice: {engine: kokoro, name: af_heart}` (the only engine in the image).
- **Captions:** `captions: {burn: true|false, style: outline|box|shadow|bold|minimal}`; the `.srt` is always written.
- **Themes:** `paper`, `clean`, `midnight`, `blueprint`, `chalk` (`kinhin video theme list`), or the user's own: `kinhin video theme new
  <name> --from midnight` writes `.kinhin/videos/themes/<name>.yml` (`extends:` plus only the values they change; colours are
  `#rrggbb`). Fonts go in `.kinhin/videos/fonts/`.
- Several files in the folder are several videos (`social/vertical.yml` is the video `social/vertical`).

## Music

Nothing plays unless a video (or its adapter) selects a track. Prefer the command to hand-written paths:

| Task | Command |
| --- | --- |
| Search | `kinhin video music search "<words>" [--min-seconds N] [--max-seconds N] [--license cc0\|cc-by]` |
| Listen | `kinhin video music preview <number>` |
| Add to a video | `kinhin video music add <number> [--video NAME] [--volume V]` |
| See what each video uses | `kinhin video music list [--json]` |

- Search is CC0 and public domain by default, from Openverse plus the built-in track. Numbers refer to the **last search**, so
  search again before `add` in a new session. With several videos, `add` needs `--video`; it never prompts.
- `add` downloads the audio into `.kinhin/videos/music/` with a `.json` provenance file and edits `music:` in the YAML, keeping
  the file's comments. A JSON config is not rewritten: paste the printed block.
- **CC BY needs credit.** Only add it if the user asks (`--license cc-by`), and tell them to put the printed credit line in the
  video description (`out/music-credit.txt` has it). Never add a non-commercial or share-alike track.
- Licenses are as declared by the source; remind the user they are responsible for how they use a track.
- Rate limited (about 200 searches a day)? The user can register a free Openverse application and set
  `KINHIN_OPENVERSE_CLIENT_ID` and `KINHIN_OPENVERSE_CLIENT_SECRET`; never ask them to paste the secret into the chat or a file.

## Rules

- **Say only what the product does.** Do not write narration that claims features the repository does not have, and do not
  invent numbers. If the user supplies claims, keep them; ask before adding new ones.
- **The first build downloads about a gigabyte** (the image), then reuses it. If `could not get the video image` appears
  for a development build of kinhin, pass `--image` with a locally built image (`docker build -t kinhin-video:local video/`
  in a kinhin checkout).
- Do not commit `.kinhin/videos/out/` or `.cache/` (the starter `.gitignore` covers them). Downloaded music is the user's
  call to commit.
- Needs a container runtime: `container system start` (Apple) or Docker running. `kinhin doctor` checks them.
- Recording the user's own app, terminal or browser clips is separate and needs host tools; `reference/` clips in an adapter
  are what the build uses. Offer drawn scenes first.
