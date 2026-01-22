# TODO

- Guard mic permission callback against state changes; only start if still idle. (Sources/stt-hotkey/stt_hotkey.swift:381-403)
- Verify recorder stop succeeded before switching to transcribing; handle failure. (Sources/stt-hotkey/stt_hotkey.swift:410-419)
- Stop any existing recorder before starting a new one to avoid overlap. (Sources/stt-hotkey/stt_hotkey.swift:113-135, 395-403)
