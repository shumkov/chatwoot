import { umiDayLabel, umiLocaleTag, umiMessageTime } from '../umiMessageTime';

// The Assistance transcript shows times and days in the reader's language. Specs run in UTC.
const AT_23_22 = Date.UTC(2026, 10, 4, 23, 22) / 1000;

describe('umiMessageTime', () => {
  it('reads as a 12-hour clock in English and a 24-hour one in Thai', () => {
    // ICU may put a narrow no-break space before PM.
    expect(umiMessageTime(AT_23_22, 'en')).toMatch(/^11:22\sPM$/);
    expect(umiMessageTime(AT_23_22, 'th')).toBe('23:22');
  });

  // Chatwoot names some locales pt_BR / zh_CN; Intl throws on the underscore.
  it('accepts Chatwoot locale codes with an underscore', () => {
    expect(umiLocaleTag('pt_BR')).toBe('pt-BR');
    expect(() => umiMessageTime(AT_23_22, 'pt_BR')).not.toThrow();
  });
});

describe('umiDayLabel', () => {
  const now = new Date(Date.UTC(2026, 10, 20));

  it('names the day and month in the reader language, without this year', () => {
    expect(umiDayLabel(AT_23_22, 'en', now)).toBe('November 4');
    expect(umiDayLabel(AT_23_22, 'th', now)).toBe('4 พฤศจิกายน');
  });

  // Thai readers count years in the Buddhist era (2025 CE = 2568 BE).
  it('adds the year only for another year', () => {
    const lastYear = Date.UTC(2025, 10, 4) / 1000;
    expect(umiDayLabel(lastYear, 'en', now)).toBe('November 4, 2025');
    expect(umiDayLabel(lastYear, 'th', now)).toBe('4 พฤศจิกายน 2568');
  });
});
