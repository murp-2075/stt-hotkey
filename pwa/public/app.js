(() => {
  'use strict';

  const els = {
    body: document.body,
    statusText: document.getElementById('statusText'),
    statusLabel: document.getElementById('statusLabel'),
    timer: document.getElementById('timer'),
    recordBtn: document.getElementById('recordBtn'),
    hint: document.getElementById('hint'),
    waveform: document.getElementById('waveform'),
    transcript: document.getElementById('transcript'),
    copyBtn: document.getElementById('copyBtn'),
    clearBtn: document.getElementById('clearBtn'),
    copyStatus: document.getElementById('copyStatus'),
    apiKey: document.getElementById('apiKey'),
    saveKeyBtn: document.getElementById('saveKeyBtn'),
    clearKeyBtn: document.getElementById('clearKeyBtn'),
    keyStatus: document.getElementById('keyStatus'),
    keyIndicator: document.getElementById('keyIndicator'),
    keyPanel: document.getElementById('keyPanel')
  };

  const STORAGE_KEY = 'stt_pwa_openai_key';
  const STATE = {
    idle: { label: 'Idle', hint: 'Tap to start recording.', button: 'Start' },
    recording: { label: 'Recording', hint: 'Tap again to stop and transcribe.', button: 'Stop' },
    transcribing: { label: 'Transcribing', hint: 'Working on transcription...', button: 'Working...' },
    done: { label: 'Done', hint: 'Tap to record again.', button: 'Start' },
    error: { label: 'Error', hint: 'Resolve the issue and try again.', button: 'Start' }
  };

  let currentState = 'idle';
  let audioContext = null;
  let mediaStream = null;
  let sourceNode = null;
  let analyserNode = null;
  let processorNode = null;
  let gainNode = null;
  let recordedBuffers = [];
  let recordingStart = 0;
  let timerInterval = null;
  let drawHandle = null;
  let audioSampleRate = 44100;
  let doneTimeout = null;
  let beepContext = null;
  let keyPanelOpen = true;

  const canvasCtx = els.waveform.getContext('2d');
  const analyserData = new Uint8Array(2048);

  function setState(nextState, message) {
    currentState = nextState;
    els.body.classList.remove('state-idle', 'state-recording', 'state-transcribing', 'state-done', 'state-error');
    els.body.classList.add(`state-${nextState}`);
    els.statusText.textContent = message || STATE[nextState].label;
    els.statusLabel.textContent = message || STATE[nextState].label;
    els.hint.textContent = STATE[nextState].hint;
    els.recordBtn.textContent = STATE[nextState].button;
    els.recordBtn.disabled = nextState === 'transcribing';

    if (nextState === 'done') {
      if (doneTimeout) {
        clearTimeout(doneTimeout);
      }
      doneTimeout = setTimeout(() => {
        if (currentState === 'done') {
          setState('idle');
        }
      }, 2000);
    }
  }

  function updateKeyIndicator() {
    const hasKey = Boolean(getApiKey());
    els.keyIndicator.textContent = hasKey ? 'API key: saved' : 'API key: not set';
    els.keyStatus.textContent = hasKey ? 'Key saved locally.' : 'No key saved yet.';
    if (!hasKey) {
      keyPanelOpen = true;
    }
    applyKeyPanelState();
  }

  function getApiKey() {
    return localStorage.getItem(STORAGE_KEY) || '';
  }

  function saveApiKey() {
    const value = els.apiKey.value.trim();
    if (!value) {
      els.keyStatus.textContent = 'Enter a key before saving.';
      return;
    }
    localStorage.setItem(STORAGE_KEY, value);
    els.apiKey.value = '';
    updateKeyIndicator();
  }

  function clearApiKey() {
    localStorage.removeItem(STORAGE_KEY);
    updateKeyIndicator();
  }

  function formatTime(seconds) {
    const minutes = Math.floor(seconds / 60);
    const secs = Math.floor(seconds % 60);
    return `${String(minutes).padStart(2, '0')}:${String(secs).padStart(2, '0')}`;
  }

  function startTimer() {
    recordingStart = performance.now();
    els.timer.textContent = '00:00';
    timerInterval = setInterval(() => {
      const elapsed = (performance.now() - recordingStart) / 1000;
      els.timer.textContent = formatTime(elapsed);
    }, 200);
  }

  function stopTimer() {
    if (timerInterval) {
      clearInterval(timerInterval);
      timerInterval = null;
    }
  }

  function resizeCanvas() {
    const ratio = window.devicePixelRatio || 1;
    const width = els.waveform.clientWidth;
    const height = els.waveform.clientHeight;
    els.waveform.width = Math.floor(width * ratio);
    els.waveform.height = Math.floor(height * ratio);
    canvasCtx.setTransform(ratio, 0, 0, ratio, 0, 0);
  }

  function updateCompactMode() {
    const compact = window.innerWidth <= 700 || window.innerHeight <= 820;
    els.body.classList.toggle('compact', compact);
    applyKeyPanelState();
  }

  function applyKeyPanelState() {
    const compact = els.body.classList.contains('compact');
    if (!compact) {
      keyPanelOpen = true;
    }
    els.body.classList.toggle('show-key', keyPanelOpen);
    els.keyIndicator.setAttribute('aria-expanded', keyPanelOpen ? 'true' : 'false');
  }

  function toggleKeyPanel() {
    if (!els.body.classList.contains('compact')) {
      return;
    }
    keyPanelOpen = !keyPanelOpen;
    applyKeyPanelState();
  }

  function drawWaveform() {
    if (!analyserNode) {
      canvasCtx.clearRect(0, 0, els.waveform.width, els.waveform.height);
      return;
    }

    analyserNode.getByteTimeDomainData(analyserData);
    const width = els.waveform.clientWidth;
    const height = els.waveform.clientHeight;
    canvasCtx.clearRect(0, 0, width, height);

    canvasCtx.lineWidth = 2;
    canvasCtx.strokeStyle = currentState === 'recording' ? '#ff7a7a' : '#6f7aa9';
    canvasCtx.beginPath();

    const sliceWidth = width / analyserData.length;
    let x = 0;
    for (let i = 0; i < analyserData.length; i += 1) {
      const v = analyserData[i] / 128.0;
      const y = (v * height) / 2;
      if (i === 0) {
        canvasCtx.moveTo(x, y);
      } else {
        canvasCtx.lineTo(x, y);
      }
      x += sliceWidth;
    }
    canvasCtx.lineTo(width, height / 2);
    canvasCtx.stroke();

    drawHandle = requestAnimationFrame(drawWaveform);
  }

  function stopWaveform() {
    if (drawHandle) {
      cancelAnimationFrame(drawHandle);
      drawHandle = null;
    }
    analyserNode = null;
    canvasCtx.clearRect(0, 0, els.waveform.clientWidth, els.waveform.clientHeight);
  }

  function getAudioContext() {
    const Ctx = window.AudioContext || window.webkitAudioContext;
    if (!Ctx) {
      return null;
    }
    return new Ctx();
  }

  function getBeepContext() {
    const Ctx = window.AudioContext || window.webkitAudioContext;
    if (!Ctx) {
      return null;
    }
    if (!beepContext || beepContext.state === 'closed') {
      beepContext = new Ctx();
    }
    if (beepContext.state === 'suspended') {
      beepContext.resume();
    }
    return beepContext;
  }

  function scheduleTone(freq, startOffset, duration, type) {
    const ctx = getBeepContext();
    if (!ctx) {
      return;
    }
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.type = type || 'sine';
    osc.frequency.value = freq;
    gain.gain.value = 0.08;
    osc.connect(gain);
    gain.connect(ctx.destination);
    const start = ctx.currentTime + startOffset;
    osc.start(start);
    osc.stop(start + duration);
  }

  function playStartSignal() {
    scheduleTone(420, 0, 0.12, 'sine');
  }

  function playStopSignal() {
    scheduleTone(380, 0, 0.08, 'sine');
    scheduleTone(320, 0.12, 0.08, 'sine');
  }

  function playDoneSignal() {
    scheduleTone(540, 0, 0.1, 'triangle');
  }

  async function startRecording() {
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      setState('error', 'Mic unavailable');
      els.hint.textContent = 'This browser does not support microphone recording.';
      return;
    }

    if (!getApiKey()) {
      setState('error', 'API key missing');
      els.hint.textContent = 'Save an OpenAI API key before recording.';
      return;
    }

    try {
      setState('recording');
      els.transcript.value = '';
      els.copyStatus.textContent = '';
      els.copyBtn.disabled = true;
      playStartSignal();

      mediaStream = await navigator.mediaDevices.getUserMedia({
        audio: {
          echoCancellation: true,
          noiseSuppression: true,
          channelCount: 1
        }
      });

      audioContext = getAudioContext();
      if (!audioContext) {
        throw new Error('AudioContext unavailable.');
      }

      if (audioContext.state === 'suspended') {
        await audioContext.resume();
      }

      audioSampleRate = audioContext.sampleRate;
      sourceNode = audioContext.createMediaStreamSource(mediaStream);
      analyserNode = audioContext.createAnalyser();
      analyserNode.fftSize = analyserData.length;

      if (!audioContext.createScriptProcessor) {
        throw new Error('ScriptProcessorNode unavailable.');
      }

      processorNode = audioContext.createScriptProcessor(4096, 1, 1);
      gainNode = audioContext.createGain();
      gainNode.gain.value = 0;

      recordedBuffers = [];

      processorNode.onaudioprocess = (event) => {
        const input = event.inputBuffer.getChannelData(0);
        recordedBuffers.push(new Float32Array(input));
      };

      sourceNode.connect(analyserNode);
      analyserNode.connect(processorNode);
      processorNode.connect(gainNode);
      gainNode.connect(audioContext.destination);

      resizeCanvas();
      drawWaveform();
      startTimer();
    } catch (error) {
      setState('error', 'Recording failed');
      els.hint.textContent = error instanceof Error ? error.message : 'Recording error.';
      cleanupAudio();
    }
  }

  function cleanupAudio() {
    stopTimer();
    stopWaveform();

    if (processorNode) {
      processorNode.disconnect();
      processorNode.onaudioprocess = null;
      processorNode = null;
    }

    if (analyserNode) {
      analyserNode.disconnect();
      analyserNode = null;
    }

    if (sourceNode) {
      sourceNode.disconnect();
      sourceNode = null;
    }

    if (gainNode) {
      gainNode.disconnect();
      gainNode = null;
    }

    if (audioContext) {
      audioContext.close();
      audioContext = null;
    }

    if (mediaStream) {
      mediaStream.getTracks().forEach((track) => track.stop());
      mediaStream = null;
    }
  }

  function encodeWav(buffers, sampleRate) {
    const totalLength = buffers.reduce((sum, buffer) => sum + buffer.length, 0);
    const pcmData = new Int16Array(totalLength);
    let offset = 0;

    buffers.forEach((buffer) => {
      for (let i = 0; i < buffer.length; i += 1) {
        let sample = buffer[i];
        sample = Math.max(-1, Math.min(1, sample));
        pcmData[offset] = sample < 0 ? sample * 0x8000 : sample * 0x7fff;
        offset += 1;
      }
    });

    const buffer = new ArrayBuffer(44 + pcmData.length * 2);
    const view = new DataView(buffer);

    function writeString(viewRef, offsetRef, value) {
      for (let i = 0; i < value.length; i += 1) {
        viewRef.setUint8(offsetRef + i, value.charCodeAt(i));
      }
    }

    writeString(view, 0, 'RIFF');
    view.setUint32(4, 36 + pcmData.length * 2, true);
    writeString(view, 8, 'WAVE');
    writeString(view, 12, 'fmt ');
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true);
    view.setUint16(22, 1, true);
    view.setUint32(24, sampleRate, true);
    view.setUint32(28, sampleRate * 2, true);
    view.setUint16(32, 2, true);
    view.setUint16(34, 16, true);
    writeString(view, 36, 'data');
    view.setUint32(40, pcmData.length * 2, true);

    new Int16Array(buffer, 44).set(pcmData);
    return new Blob([buffer], { type: 'audio/wav' });
  }

  async function stopRecording() {
    setState('transcribing');
    els.hint.textContent = 'Uploading audio for transcription...';
    playStopSignal();

    const buffers = recordedBuffers.slice();
    const sampleRate = audioSampleRate;
    cleanupAudio();

    if (!buffers.length) {
      setState('error', 'No audio');
      els.hint.textContent = 'No audio captured. Try again.';
      return;
    }

    try {
      const wavBlob = encodeWav(buffers, sampleRate);
      const text = await transcribeAudio(wavBlob);
      if (!text) {
        throw new Error('No transcription text returned.');
      }
      els.transcript.value = text;
      els.copyBtn.disabled = false;
      els.copyStatus.textContent = '';
      setState('done');
      playDoneSignal();
      await attemptAutoCopy(text);
    } catch (error) {
      setState('error', 'Transcription failed');
      if (error instanceof Error && /failed to fetch/i.test(error.message)) {
        els.hint.textContent = 'Network or CORS error. Check connectivity or API access.';
      } else {
        els.hint.textContent = error instanceof Error ? error.message : 'Transcription error.';
      }
    }
  }

  async function transcribeAudio(blob) {
    const apiKey = getApiKey();
    if (!apiKey) {
      throw new Error('Missing API key.');
    }

    const formData = new FormData();
    formData.append('model', 'gpt-4o-mini-transcribe');
    formData.append('response_format', 'json');
    formData.append('file', blob, 'recording.wav');

    const response = await fetch('https://api.openai.com/v1/audio/transcriptions', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${apiKey}`
      },
      body: formData
    });

    if (!response.ok) {
      const text = await response.text();
      throw new Error(text || `HTTP ${response.status}`);
    }

    const data = await response.json();
    if (typeof data.text === 'string') {
      return data.text.trim();
    }
    if (typeof data.transcript === 'string') {
      return data.transcript.trim();
    }
    return '';
  }

  async function attemptAutoCopy(text) {
    if (!navigator.clipboard || !navigator.clipboard.writeText) {
      els.copyStatus.textContent = 'Clipboard not available. Tap Copy.';
      return;
    }

    try {
      await navigator.clipboard.writeText(text);
      els.copyStatus.textContent = 'Copied to clipboard.';
    } catch (error) {
      els.copyStatus.textContent = 'Tap Copy to place text on the clipboard.';
    }
  }

  function handleRecordClick() {
    if (currentState === 'recording') {
      stopRecording();
      return;
    }

    if (currentState === 'transcribing') {
      return;
    }

    startRecording();
  }

  function handleCopy() {
    const text = els.transcript.value.trim();
    if (!text) {
      els.copyStatus.textContent = 'Nothing to copy yet.';
      return;
    }
    attemptAutoCopy(text);
  }

  function handleClear() {
    els.transcript.value = '';
    els.copyStatus.textContent = '';
    els.copyBtn.disabled = true;
  }

  function init() {
    resizeCanvas();
    window.addEventListener('resize', resizeCanvas);
    window.addEventListener('resize', updateCompactMode);

    updateKeyIndicator();
    updateCompactMode();

    els.recordBtn.addEventListener('click', handleRecordClick);
    els.copyBtn.addEventListener('click', handleCopy);
    els.clearBtn.addEventListener('click', handleClear);
    els.saveKeyBtn.addEventListener('click', saveApiKey);
    els.clearKeyBtn.addEventListener('click', clearApiKey);
    els.keyIndicator.addEventListener('click', toggleKeyPanel);

    els.apiKey.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') {
        saveApiKey();
      }
    });

    if (getApiKey()) {
      els.keyStatus.textContent = 'Key saved locally.';
    }
  }

  init();
})();
