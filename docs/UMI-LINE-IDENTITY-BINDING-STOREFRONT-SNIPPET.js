(() => {
  const settings = window.UMILineIdentityBinding || {};
  const backendBase = (settings.backendBase || '').replace(/\/$/, '');
  const selector = '[data-umi-line-button], [data-umi-line-qr]';
  const seenEmails = new Set();
  const qrScriptUrl = 'https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js';
  const qrScriptIntegrity = 'sha512-CNgIRecGo7nphbeZ04Sc13ka07paqdeTu0WR1IM4kNcpmBAUSHSQX0FslNhTDadL4O5SAGapGt4FodqL8My0mA==';
  let qrPromise;

  if (!backendBase) return;

  const loadQr = () => {
    if (window.QRCode) return Promise.resolve(window.QRCode);
    if (qrPromise) return qrPromise;
    qrPromise = new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = qrScriptUrl;
      script.integrity = qrScriptIntegrity;
      script.crossOrigin = 'anonymous';
      script.onload = () => resolve(window.QRCode);
      script.onerror = reject;
      document.head.appendChild(script);
    });
    return qrPromise;
  };

  const renderUrl = async (url) => {
    document.querySelectorAll('[data-umi-line-button]').forEach((button) => {
      button.href = url;
    });
    const qrTargets = [...document.querySelectorAll('[data-umi-line-qr]')];
    if (!qrTargets.length) return;
    try {
      const qrCode = await loadQr();
      const holder = document.createElement('div');
      new qrCode(holder, { text: url, width: 256, height: 256, correctLevel: qrCode.CorrectLevel.M });
      const canvas = holder.querySelector('canvas');
      const image = holder.querySelector('img');
      const imageUrl = canvas ? canvas.toDataURL('image/png') : image && image.src;
      if (!imageUrl) throw new Error('QR library did not produce an image');
      qrTargets.forEach((target) => { target.src = imageUrl; });
    } catch (error) {
      // The personalised button remains usable when QR generation is unavailable.
      console.warn('[UMI-LINE] local QR generation failed', error);
    }
  };

  const observeStepTwo = (url) => {
    const render = () => renderUrl(url);
    render();
    const observer = new MutationObserver(render);
    observer.observe(document.documentElement, { childList: true, subtree: true });
    window.setTimeout(() => observer.disconnect(), 5000);
  };

  const mintForEmail = async (email) => {
    const normalized = email.trim().toLowerCase();
    if (!normalized || seenEmails.has(normalized)) return;
    seenEmails.add(normalized);
    const response = await fetch(`${backendBase}/line-connect/token`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: normalized }),
    });
    if (!response.ok) throw new Error(`LINE token mint failed: ${response.status}`);
    const result = await response.json();
    observeStepTwo(result.url);
  };

  window.addEventListener('klaviyoForms', (event) => {
    const detail = event.detail || {};
    if (!['stepSubmit', 'submit'].includes(detail.type)) return;
    const email = detail.metaData && detail.metaData.email;
    if (typeof email !== 'string' || !email.trim()) return;
    mintForEmail(email).catch((error) => console.warn('[UMI-LINE] token mint failed', error));
  });
})();
