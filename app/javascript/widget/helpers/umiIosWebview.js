// UMI: the storefront's iOS field-zoom guard (umi-store-theme snippets/ios-field-zoom.liquid),
// repeated inside the widget. iOS zooms the page when a field under 16 px takes focus. Mobile
// Safari is stopped by the storefront's maximum-scale viewport, which covers this iframe too, so
// fields stay 14 px there. Apps' in-app browsers and other iOS browsers would lose pinch zoom under
// that cap, so the storefront leaves their viewport alone and marks them `ios-webview`; that class
// cannot reach this cross-origin iframe, so the widget runs the same test and marks its own root.
// The user agent inside the iframe is the page's, so both answer alike. Keep the test identical
// to the theme's.

const IOS_PLATFORM = /^iP(hone|ad|od)/;
const SAFARI = /Version\/[\d.]+.*Safari\//;
const NOT_SAFARI =
  /CriOS|FxiOS|EdgiOS|OPiOS|OPT\/|DuckDuckGo|GSA\/|Instagram|FBAN|FBAV|Line\/|musical_ly|TikTok|BytedanceWebview|MicroMessenger|Snapchat/;

export const isIosWebview = ({
  platform = '',
  userAgent = '',
  maxTouchPoints = 0,
}) => {
  // iPadOS reports a Mac; its touch screen gives it away.
  const isIos =
    IOS_PLATFORM.test(platform) ||
    (platform === 'MacIntel' && maxTouchPoints > 1);
  if (!isIos) return false;
  return !(SAFARI.test(userAgent) && !NOT_SAFARI.test(userAgent));
};

export const markIosWebview = (doc, nav) => {
  if (isIosWebview(nav)) doc.documentElement.classList.add('ios-webview');
};
