import { mount } from '@vue/test-utils';
import { createI18n } from 'vue-i18n';
import i18nMessages from 'widget/i18n';
import UmiDateLabel from '../UmiDateLabel.vue';

// Each day of the transcript opens with a label in the reader's language.
describe('UmiDateLabel', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date(Date.UTC(2026, 10, 20, 12)));
  });
  afterEach(() => vi.useRealTimers());

  const label = (date, locale = 'en') =>
    mount(UmiDateLabel, {
      props: { timestamp: date.getTime() / 1000 },
      global: {
        plugins: [
          createI18n({ legacy: false, locale, messages: i18nMessages }),
        ],
      },
    }).text();

  it('says today and yesterday in words', () => {
    expect(label(new Date(Date.UTC(2026, 10, 20, 9)))).toBe('Today');
    expect(label(new Date(Date.UTC(2026, 10, 19, 9)), 'th')).toBe('เมื่อวาน');
  });

  it('names an older day in Thai', () => {
    expect(label(new Date(Date.UTC(2026, 10, 4, 9)), 'th')).toBe('4 พฤศจิกายน');
  });
});
