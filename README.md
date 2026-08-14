# stt-hotkey

One global hotkey:
- `cmd+shift+s` (or `HOTKEY`) for speech-to-text.

Speech-to-text uses OpenAI audio transcriptions with `gpt-transcribe`.

Environment variables:
- `OPENAI_API_KEY` (required)
- `HOTKEY` (optional, default `cmd+shift+s`)
- `SHOW_DOCK_ICON` (optional)
- `SCREEN_SHARING_CLIPBOARD_NUDGE` (optional, default enabled; set to `0` to disable the same-Space focus bounce after transcribing from Screen Sharing)

Build
```
cat > .env <<'EOF'
OPENAI_API_KEY=your_key_here
HOTKEY=cmd+shift+s
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
