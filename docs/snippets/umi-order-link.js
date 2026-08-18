(() => {
  const PARAMETER = 'umi_cw';
  // Double underscore is Shopify's privacy marker for cart attributes: the order still
  // carries it, but no script on the shop origin can read it back from Liquid or /cart.js.
  const CART_ATTRIBUTE = '__cw';
  const STORAGE_KEY = 'umi_shopify_order_link';
  const TTL_MS = 30 * 24 * 60 * 60 * 1000;

  const readStoredToken = () => {
    try {
      const stored = JSON.parse(localStorage.getItem(STORAGE_KEY) || 'null');
      return stored && stored.expiresAt > Date.now() ? stored.token : null;
    } catch (_error) {
      return null;
    }
  };

  const captureToken = () => {
    const url = new URL(window.location.href);
    const token = url.searchParams.get(PARAMETER);
    if (!token) return readStoredToken();

    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify({ token, expiresAt: Date.now() + TTL_MS }));
    } catch (_error) {
      // The URL is still cleaned even when storage is unavailable.
    }
    url.searchParams.delete(PARAMETER);
    window.history.replaceState({}, document.title, `${url.pathname}${url.search}${url.hash}`);
    return token;
  };

  const reapply = async () => {
    const token = readStoredToken();
    if (!token || !window.Shopify?.routes?.root) return null;

    const response = await fetch(`${window.Shopify.routes.root}cart/update.js`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ attributes: { [CART_ATTRIBUTE]: token } })
    });
    if (!response.ok) throw new Error(`cart attribution update failed: ${response.status}`);
    return response.json();
  };

  const reportFailure = (error) => console.warn('[umi-order-link] cart attribution was not applied', error);

  window.UmiOrderLink = { reapply };
  document.head.insertAdjacentHTML('beforeend', '<meta name="referrer" content="no-referrer">');
  captureToken();
  reapply().catch(reportFailure);

  document.addEventListener('submit', (event) => {
    if (event.target.closest('form[action*="/cart/add"]')) reapply().catch(reportFailure);
  }, true);
})();
