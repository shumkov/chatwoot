import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const snippetPath = resolve(dirname(fileURLToPath(import.meta.url)), 'UMI-LINE-IDENTITY-BINDING-STOREFRONT-SNIPPET.js');
const snippet = readFileSync(snippetPath, 'utf8');

const loadSnippet = () => {
  window.UMILineIdentityBinding = { backendBase: 'https://chatwoot.example' };
  window.eval(snippet);
};

describe('UMI LINE storefront snippet', () => {
  beforeEach(() => {
    document.body.innerHTML = '<a data-umi-line-button></a>';
    delete window.QRCode;
    vi.restoreAllMocks();
  });

  it('mints once for a Klaviyo email and rewrites the button', async () => {
    document.body.innerHTML = '<a data-umi-line-button></a><img data-umi-line-qr>';
    window.QRCode = class {
      static CorrectLevel = { M: 0 };

      constructor(holder) {
        const canvas = document.createElement('canvas');
        canvas.toDataURL = () => 'data:image/png;base64,local';
        holder.appendChild(canvas);
      }
    };
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, json: async () => ({ url: 'https://chatwoot.example/line-connect?token=opaque' }) });
    globalThis.fetch = fetchMock;
    loadSnippet();

    window.dispatchEvent(new CustomEvent('klaviyoForms', {
      detail: { type: 'stepSubmit', metaData: { email: ' Person@Example.com ' } },
    }));
    window.dispatchEvent(new CustomEvent('klaviyoForms', {
      detail: { type: 'stepSubmit', metaData: { email: 'person@example.com' } },
    }));
    await Promise.resolve();
    await Promise.resolve();
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock).toHaveBeenCalledWith('https://chatwoot.example/line-connect/token', expect.objectContaining({
      body: JSON.stringify({ email: 'person@example.com' }),
    }));
    expect(document.querySelector('[data-umi-line-button]').href)
      .toBe('https://chatwoot.example/line-connect?token=opaque');
    expect(document.querySelector('[data-umi-line-qr]').src).toBe('data:image/png;base64,local');
  });

  it('ignores form events without an email', async () => {
    const fetchMock = vi.fn();
    globalThis.fetch = fetchMock;
    loadSnippet();

    window.dispatchEvent(new CustomEvent('klaviyoForms', { detail: { type: 'stepSubmit', metaData: {} } }));
    await Promise.resolve();

    expect(fetchMock).not.toHaveBeenCalled();
  });
});
