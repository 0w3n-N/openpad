// Scan a QR code with the camera (the computer's pairing code). Uses the
// browser's BarcodeDetector where it exists, otherwise jsQR (iPad Safari).

let jsQR = null;
async function loadJsQR() {
  if (!jsQR) {
    await import(new URL('./node_modules/jsqr/jsqr.js', import.meta.url).href); // UMD: sets self.jsQR
    jsQR = self.jsQR;
  }
  return jsQR;
}

async function detector() {
  if ('BarcodeDetector' in window) {
    try {
      if ((await BarcodeDetector.getSupportedFormats()).includes('qr_code')) {
        const d = new BarcodeDetector({ formats: ['qr_code'] });
        return async (source) => (await d.detect(source))[0]?.rawValue || null;
      }
    } catch {}
  }
  const read = await loadJsQR();
  const canvas = document.createElement('canvas');
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  return async (source) => {
    const w = source.videoWidth || source.width, h = source.videoHeight || source.height;
    if (!w || !h) return null;
    const k = Math.min(1, 800 / Math.max(w, h)); // smaller frames decode faster
    canvas.width = Math.round(w * k);
    canvas.height = Math.round(h * k);
    ctx.drawImage(source, 0, 0, canvas.width, canvas.height);
    const img = ctx.getImageData(0, 0, canvas.width, canvas.height);
    return read(img.data, img.width, img.height, { inversionAttempts: 'dontInvert' })?.data || null;
  };
}

// Decode a QR code in an image or canvas (used by tests and the scanner).
export async function decode(source) {
  return (await detector())(source);
}

export const cameraAvailable = () => !!navigator.mediaDevices?.getUserMedia && window.isSecureContext;

// Show the back camera in `video` until a code matching `accept(text)` is
// seen. Returns {stop, done}: done resolves with the text (or null if stopped).
export function scan(video, accept) {
  let stopped = false;
  let stream = null;
  let settle, fail;
  const done = new Promise((res, rej) => {
    settle = res;
    fail = rej;
  });
  const end = (value) => {
    if (stopped) return;
    stopped = true;
    stream?.getTracks().forEach((t) => t.stop());
    video.srcObject = null;
    settle(value);
  };
  (async () => {
    try {
      stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' }, audio: false });
    } catch (e) {
      stopped = true;
      return fail(e);
    }
    if (stopped) return stream.getTracks().forEach((t) => t.stop());
    video.srcObject = stream;
    video.setAttribute('playsinline', '');
    video.muted = true;
    await video.play().catch(() => {});
    const read = await detector();
    while (!stopped) {
      let text = null;
      try {
        text = await read(video);
      } catch {}
      if (text && accept(text)) return end(text);
      await new Promise((r) => setTimeout(r, 150));
    }
  })();
  return { stop: () => end(null), done };
}
