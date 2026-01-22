# stt-hotkey

Build
```
cat > .env <<'EOF'
OPENAI_API_KEY=your_key_here
# HOTKEY=cmd+shift+s
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
