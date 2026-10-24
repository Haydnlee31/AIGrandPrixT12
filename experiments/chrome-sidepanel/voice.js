/** Encode a bounded mono PCM WAV supported by the backend; never send browser WebM. */
export function encodeWav(samples, inputRate, outputRate = 16000) {
  if (!Number.isFinite(inputRate) || inputRate < 8000 || inputRate > 192000 || samples.length > inputRate * 61) throw new Error('Record a voice note of up to 60 seconds.');
  const length = Math.min(outputRate * 60, Math.floor(samples.length * outputRate / inputRate));
  if (!length) throw new Error('The recording was empty. Try again.');
  const bytes = new ArrayBuffer(44 + length * 2), view = new DataView(bytes);
  const text = (offset, value) => [...value].forEach((char, i) => view.setUint8(offset + i, char.charCodeAt(0)));
  text(0, 'RIFF'); view.setUint32(4, bytes.byteLength - 8, true); text(8, 'WAVE'); text(12, 'fmt ');
  view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
  view.setUint32(24, outputRate, true); view.setUint32(28, outputRate * 2, true);
  view.setUint16(32, 2, true); view.setUint16(34, 16, true); text(36, 'data'); view.setUint32(40, length * 2, true);
  for (let i = 0; i < length; i++) {
    const start = Math.floor(i * inputRate / outputRate), end = Math.max(start + 1, Math.floor((i + 1) * inputRate / outputRate));
    let value = 0; for (let j = start; j < Math.min(end, samples.length); j++) value += samples[j];
    value = Math.max(-1, Math.min(1, value / (end - start)));
    view.setInt16(44 + i * 2, value < 0 ? value * 32768 : value * 32767, true);
  }
  return new Uint8Array(bytes);
}
export function wavDataURL(bytes) {
  let binary = '';
  for (let offset = 0; offset < bytes.length; offset += 8192) binary += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
  return 'data:audio/wav;base64,' + btoa(binary);
}

export class VoiceRecorder {
  constructor(onChange = () => {}) { this.onChange = onChange; }
  async start() {
    if (this.active) return;
    try {
      this.stream = await navigator.mediaDevices.getUserMedia({audio: {channelCount: 1, echoCancellation: true}, video: false});
      this.context = new AudioContext({sampleRate: 16000});
      await this.context.resume();
      this.source = this.context.createMediaStreamSource(this.stream);
      this.processor = this.context.createScriptProcessor(4096, 1, 1);
      this.parts = []; this.count = 0; this.active = true;
      this.processor.onaudioprocess = event => {
        if (!this.active) return;
        const input = event.inputBuffer.getChannelData(0), remaining = Math.max(0, Math.floor(this.context.sampleRate * 60) - this.count);
        const part = input.slice(0, remaining);
        this.parts.push(part); this.count += part.length;
      };
      this.source.connect(this.processor); this.processor.connect(this.context.destination);
      this.started = Date.now();
      this.timer = setInterval(() => {
        const seconds = Math.min(60, Math.floor((Date.now() - this.started) / 1000));
        this.onChange({active: true, seconds});
        if (seconds >= 60) this.stop().then(audio => this.onChange({active: false, audio, seconds})).catch(error => this.onChange({active: false, error}));
      }, 250);
      this.onChange({active: true, seconds: 0});
    } catch (error) {
      this.dispose();
      throw new Error(error.name === 'NotAllowedError' ? 'Microphone access was not allowed. Allow it in Chrome to record, or type your note.' : 'The microphone could not start. Check that it is available and try again.');
    }
  }
  async stop() {
    if (!this.active) return null;
    this.active = false;
    const rate = this.context.sampleRate, samples = new Float32Array(this.count);
    let offset = 0; for (const part of this.parts) { samples.set(part, offset); offset += part.length; }
    this.dispose();
    const audio = wavDataURL(encodeWav(samples, rate));
    this.onChange({active: false, audio, seconds: Math.round(samples.length / rate)});
    return audio;
  }
  dispose() {
    this.active = false; clearInterval(this.timer);
    this.processor?.disconnect(); this.source?.disconnect();
    this.stream?.getTracks().forEach(track => track.stop());
    this.context?.close().catch(() => {});
    this.parts = []; this.count = 0;
  }
}
