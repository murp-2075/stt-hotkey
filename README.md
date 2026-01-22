# sst-hotkey

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
open ./build/sst-hotkey.app
```

Deploy
```
rm -rf /Applications/sst-hotkey.app
cp -R ./build/sst-hotkey.app /Applications/
open /Applications/sst-hotkey.app
```
