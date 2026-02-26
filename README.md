# stt-hotkey

Two global hotkeys:
- `cmd+shift+s` (or `HOTKEY`) for pure STT.
- `cmd+shift+r` (or `REWRITE_HOTKEY`) for STT, then rewrite via Responses API.

Rewrite mode uses strict structured output and copies only one field to clipboard: `rewritten_prompt`.

Environment variables:
- `OPENAI_API_KEY` (required)
- `HOTKEY` (optional, default `cmd+shift+s`)
- `REWRITE_HOTKEY` (optional, default `cmd+shift+r`)
- `REWRITE_PROMPT` (required for rewrite hotkey)
- `REWRITE_MODEL` (optional, default `gpt-5.2`)
- `REWRITE_REASONING_EFFORT` (optional: `none|minimal|low|medium|high|xhigh`)
- `REWRITE_VERBOSITY` (optional: `low|medium|high`)
- `REWRITE_FALLBACK_TO_RAW` (optional, default `true`)
- `REALTIME_TRANSCRIPTION` (optional)
- `SHOW_DOCK_ICON` (optional)

Build
```
cat > .env <<'EOF'
OPENAI_API_KEY=your_key_here
HOTKEY=cmd+shift+s
REWRITE_HOTKEY=cmd+shift+r
REWRITE_PROMPT=Rewrite this STT transcript into a concise, clear prompt while preserving intent.
REWRITE_MODEL=gpt-5.2
# REWRITE_REASONING_EFFORT=none
# REWRITE_VERBOSITY=medium
# REWRITE_FALLBACK_TO_RAW=true
# REALTIME_TRANSCRIPTION=1
# SHOW_DOCK_ICON=1
EOF

./scripts/build_app.sh
```

Run
```
open ./build/stt-hotkey.app
```

Deploy
```
rm -rf /Applications/stt-hotkey.app
cp -R ./build/stt-hotkey.app /Applications/
open /Applications/stt-hotkey.app
```

Example rewrite config using `gpt-5-mini`:
```
REWRITE_MODEL=gpt-5-mini
REWRITE_REASONING_EFFORT=minimal
REWRITE_VERBOSITY=low
```
