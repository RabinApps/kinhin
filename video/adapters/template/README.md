# The template adapter

Copy this directory to `video/adapters/<your-product>/` and make it yours. An adapter is everything the video
pipeline needs to know about one product; the pipeline itself never mentions a product.

| File | What to change |
|---|---|
| `adapter.json` | The clips your videos use (`app`, `demo`, ...), how each is recorded, and the tools recording needs |
| `record-app.sh` | Records your product's window or screen. Write `$VIDEO_RAW_DIR/app.mov` and `app.json` |
| `terminal/demo.tape` | A [VHS](https://github.com/charmbracelet/vhs) tape for a terminal clip; the recorder fills in size and theme |
| `reference/` | Small committed clips, made by `scripts/make-reference.sh --adapter <name>` |

Then point a project at it (`"adapter": "<your-product>"` in `video/script/<name>.json`) and use the clips in scenes:
`{"type": "device", "props": {"clip": "app"}}` and `{"type": "terminal", "props": {"clip": "demo"}}`. See
`script/template-demo.json`, which builds with `video/scripts/build.sh --project template-demo`.
