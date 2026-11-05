import { isIosWebview, markIosWebview } from '../umiIosWebview';

// Widget fields are 14 px. Mobile Safari is kept from zooming on focus by the storefront's
// viewport cap; every other iOS browser (apps' in-app browsers included) is not, so there the
// fields must be 16 px. The cases mirror umi-store-theme test/field-type.test.js.
const IOS =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 26_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko)';
const SAFARI_IPHONE = `${IOS} Version/26.5 Mobile/15E148 Safari/604.1`;
const SAFARI_IPAD =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.5 Safari/605.1.15';
const ANDROID =
  'Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36';

const WEBVIEWS = [
  [
    'Instagram',
    `${IOS} Mobile/15E148 Instagram 400.0.0.0 (iPhone16,2; iOS 26_5; en_US)`,
  ],
  ['Facebook', `${IOS} Mobile/15E148 [FBAN/FBIOS;FBAV/500.0.0;FBBV/1]`],
  ['LINE', `${IOS} Mobile/15E148 Safari Line/15.0.0`],
  ['TikTok', `${IOS} Mobile/15E148 musical_ly_40.0.0 BytedanceWebview/d8a21c6`],
  [
    'WeChat',
    `${IOS} Mobile/15E148 MicroMessenger/8.0.50(0x18003237) NetType/WIFI Language/en`,
  ],
  [
    'Snapchat',
    `${IOS} Mobile/15E148 Snapchat/13.0.0.0 (like Safari/8621.1.15, panda)`,
  ],
  ['Chrome on iOS', `${IOS} CriOS/140.0.0.0 Mobile/15E148 Safari/604.1`],
  ['Firefox on iOS', `${IOS} FxiOS/140.0 Mobile/15E148 Safari/605.1.15`],
  [
    'Edge on iOS',
    `${IOS} Version/26.0 EdgiOS/140.0.0.0 Mobile/15E148 Safari/605.1.15`,
  ],
  ['Opera on iOS', `${IOS} Version/26.5 Mobile/15E148 Safari/604.1 OPT/5.0.0`],
  [
    'DuckDuckGo',
    `${IOS} Version/26.5 Mobile/15E148 DuckDuckGo/7 Safari/605.1.15`,
  ],
  ['Google app', `${IOS} GSA/380.0.0 Mobile/15E148 Safari/604.1`],
];

describe('isIosWebview', () => {
  // Brave sends Safari's exact user agent, so it lands here too, as on the storefront.
  it('leaves Safari on iPhone and iPad at 14 px', () => {
    expect(isIosWebview({ platform: 'iPhone', userAgent: SAFARI_IPHONE })).toBe(
      false
    );
    // iPadOS Safari reports a Mac; its touch screen gives it away.
    expect(
      isIosWebview({
        platform: 'MacIntel',
        maxTouchPoints: 5,
        userAgent: SAFARI_IPAD,
      })
    ).toBe(false);
  });

  it.each(WEBVIEWS)('puts %s on iPhone at 16 px', (_name, userAgent) => {
    expect(isIosWebview({ platform: 'iPhone', userAgent })).toBe(true);
  });

  it('marks an in-app browser on iPad too', () => {
    expect(
      isIosWebview({
        platform: 'MacIntel',
        maxTouchPoints: 5,
        userAgent: WEBVIEWS[0][1],
      })
    ).toBe(true);
  });

  it('leaves a Mac and Android alone', () => {
    expect(
      isIosWebview({
        platform: 'MacIntel',
        maxTouchPoints: 0,
        userAgent: SAFARI_IPAD,
      })
    ).toBe(false);
    expect(
      isIosWebview({
        platform: 'MacIntel',
        maxTouchPoints: 0,
        userAgent: WEBVIEWS[0][1],
      })
    ).toBe(false);
    expect(
      isIosWebview({
        platform: 'Linux armv8l',
        maxTouchPoints: 5,
        userAgent: ANDROID,
      })
    ).toBe(false);
  });
});

describe('markIosWebview', () => {
  afterEach(() => document.documentElement.classList.remove('ios-webview'));

  it('tags the widget root in an in-app browser', () => {
    markIosWebview(document, { platform: 'iPhone', userAgent: WEBVIEWS[0][1] });
    expect(document.documentElement.classList.contains('ios-webview')).toBe(
      true
    );
  });

  it('leaves the root untagged in Safari', () => {
    markIosWebview(document, { platform: 'iPhone', userAgent: SAFARI_IPHONE });
    expect(document.documentElement.classList.contains('ios-webview')).toBe(
      false
    );
  });
});
