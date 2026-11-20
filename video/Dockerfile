# Builds the launch video without a Mac: Node, Chromium (renders the Motion Canvas title scenes), ffmpeg with
# libass (frames, captions, final cut) and Kokoro (local voice-over). Works with Apple's `container` and Docker:
#   scripts/build.sh --container
# The base image's Playwright version must match playwright-core in package.json (a unit test checks it), and the image is
# pinned by digest (the multi-arch index, so arm64 and amd64 both resolve) so a build today is the build tomorrow. Dependabot
# does NOT bump this line (.github/dependabot.yml ignores it, because it cannot also bump playwright-core); update both by hand, see docs/making-a-video.md.
FROM mcr.microsoft.com/playwright:v1.65.1-noble@sha256:1507cbfc550a63a6b7396791ca4f00df17beb56342d2447b3f106c306f525579

# The Playwright image points apt at Azure's Ubuntu mirror over plain HTTP, which the CI runners cannot reach (update
# succeeds, then every package download fails). Use Canonical's HTTPS mirrors, and retry transient mirror failures.
RUN sed -i -e 's|http://azure.archive.ubuntu.com|https://archive.ubuntu.com|g' \
           -e 's|http://security.ubuntu.com|https://security.ubuntu.com|g' \
           /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true

RUN apt-get -o Acquire::Retries=3 update \
 && apt-get -o Acquire::Retries=3 install -y --no-install-recommends ffmpeg python3 rsync curl ca-certificates fonts-inter fonts-liberation fonts-comic-neue fonts-dejavu-core \
 && rm -rf /var/lib/apt/lists/*

# Fonts for the built-in themes: Inter (paper, clean, midnight), DejaVu Sans Mono (blueprint), Comic Neue (chalk).
# Your own fonts in video/fonts/ are installed when a build starts. Helvetica resolves to Liberation Sans.
RUN printf '<?xml version="1.0"?><!DOCTYPE fontconfig SYSTEM "fonts.dtd"><fontconfig>\
<alias binding="same"><family>Helvetica</family><prefer><family>Liberation Sans</family></prefer></alias>\
</fontconfig>' > /etc/fonts/local.conf && fc-cache -f

WORKDIR /work
COPY package.json package-lock.json ./
# onnxruntime-node's install script downloads a CUDA build on linux/x64 (a 404 from Microsoft's release page failed this step).
# Kokoro runs on the CPU here (device: "cpu" below), so the CUDA provider is never used; skip it.
RUN npm ci --onnxruntime-node-install-cuda=skip

# Bake the Kokoro model into the image (about 90 MB; the voices ship in the npm package) so a build needs no network.
# The warm-up is a real module file (not `node -e`, which hides a missing voice) and must print "warm ok": the ONNX runtime
# aborts while shutting down after the work is done, so the exit code means nothing.
RUN printf '%s\n' \
  'import {KokoroTTS} from "kokoro-js";' \
  'const tts = await KokoroTTS.from_pretrained("onnx-community/Kokoro-82M-v1.0-ONNX", {dtype: "q8", device: "cpu"});' \
  'for (const v of ["af_heart", "am_michael", "bf_emma"]) await tts.generate("warm up", {voice: v});' \
  'console.log("warm ok"); process.exit(0);' > warm.mjs \
 && (node warm.mjs 2>&1 | tee /tmp/warm.log | tail -2; grep -q "warm ok" /tmp/warm.log) \
 && rm warm.mjs \
 && find node_modules/@huggingface -name '*.onnx' | grep -q .

# The suite itself. This makes the image self-contained: `kinhin video build` (or scripts/container-build.sh) runs it against a
# repository mounted at /project, and nobody needs a copy of video/. The developer flow (scripts/build.sh --container) still
# rsyncs the working tree over this copy when a build starts. It comes after the dependency and voice-model layers so editing the
# suite does not rebuild them. (One whole-context COPY on purpose: Apple's builder truncates a directory that an earlier,
# narrower COPY already asked for.)
COPY . /work

# The catalog's bundled music (music/catalog.json: CC0 tracks), checked against their SHA-256, so a build that selects one
# needs no network. scripts/fetch-music.mjs copies from /opt/music (the build's raw/ is a bind mount, hiding /work/raw).
RUN node /work/scripts/fetch-music.mjs --bake /opt/music

ENV KINHIN_VIDEO_IN_CONTAINER=1
