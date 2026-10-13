#!/usr/bin/env python3
"""Renders a list of jobs with Supertonic, loading the model once.
Usage: tts_supertonic.py jobs.json    jobs.json: [{"text": "...", "voice": "F3", "out": "path.wav"}, ...]
Needs the venv from scripts/voice.mjs --setup (pip install supertonic). Prints the duration of each file."""
import json, sys
from supertonic import TTS

jobs = json.load(open(sys.argv[1]))
tts = TTS()
styles = {}
for job in jobs:
    voice = job["voice"]
    if voice not in styles:
        styles[voice] = tts.get_voice_style(voice_name=voice)
    wav, duration = tts.synthesize(job["text"], voice_style=styles[voice], lang="en", speed=job.get("speed", 1.0))
    tts.save_audio(wav, job["out"])
    print(f'{job["out"]}\t{float(duration[0]):.2f}')
