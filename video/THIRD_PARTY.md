# Third-party components of the video suite

What the build image (`video/Dockerfile`) and the output contain, and under which licences. Checked against the package
metadata, the distribution's package files and the model card on 2026-10-12; recheck when you bump a version.

| Component | Where | Licence |
|---|---|---|
| Kokoro-82M (the voice model) and `kokoro-js` 1.2.1 | baked into the image | Apache-2.0 (model card and package) |
| `@huggingface/transformers` 3.8.1, `phonemizer` 1.2.1 | npm, in the image | Apache-2.0 |
| `onnxruntime-node` 1.21.0 | npm, in the image | MIT |
| Motion Canvas (`@motion-canvas/core`, `2d`, `ffmpeg`, `vite-plugin`, `ui`) 3.17.2 | npm | MIT |
| Playwright / `playwright-core` 1.56.1 and its Chromium | the base image | Apache-2.0 (Chromium: BSD-style and others) |
| Vite 5, TypeScript 5 | npm | MIT, Apache-2.0 |
| ffmpeg (Ubuntu package, with libx264 and libass) | the image; the bundled `@ffmpeg-installer/ffmpeg` binary (LGPL-2.1) is used by Motion Canvas's exporter | LGPL/GPL; the build tools are not redistributed, only the videos they make |
| Inter, Comic Neue, Liberation Sans, DejaVu fonts | the image | SIL OFL 1.1 (Inter also Apache-2.0); DejaVu's free licence |
| First Light Particles by Yoiyami (the music bed) | the image (`/opt/music`, every `bundled` entry of `music/catalog.json`), verified by SHA-256; selected by the kinhin adapter | CC0 1.0 (no credit required; anyone may reuse it) |
| Supertonic (optional voice engine, not in the image) | `scripts/voice.mjs --setup supertonic` | Code MIT, model OpenRAIL-M; archived upstream |

Music you find with `kinhin video music search` is not part of the image: it is downloaded into your repository when you add it, from Openverse (mostly Freesound), and keeps the licence its author gave it (recorded in a `.json` file beside the audio). Only CC0 and public-domain tracks are offered unless you ask for CC BY, which comes with its credit line.

Videos made by the suite contain the voice (Kokoro), the music (CC0, or the track you added), the fonts as rendered text and your own recordings. The
tools themselves are never part of an output. This is a summary, not legal advice.
