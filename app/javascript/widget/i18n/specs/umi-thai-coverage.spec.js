import en from 'widget/i18n/locale/en.json';
import th from 'widget/i18n/locale/th.json';

// The bug this pins is not "a key is missing" — every key is present, because
// upstream ships the English as the placeholder. It is "a Thai reader sees
// English", which looks identical to a translated file until you read it.
//
// Adding a UMI string without Thai fails here rather than reaching a customer.

const flatten = (object, prefix = '') =>
  Object.entries(object).reduce((acc, [key, value]) => {
    const path = prefix ? `${prefix}.${key}` : key;
    return typeof value === 'object' && value !== null
      ? { ...acc, ...flatten(value, path) }
      : { ...acc, [path]: value };
  }, {});

const enKeys = flatten(en);
const thKeys = flatten(th);

// Nothing in UMI's configuration renders these, so their English is deliberate
// rather than an oversight:
//   PRE_CHAT_FORM / CHAT_FORM — the pre-chat form is disabled on this inbox
//   INTEGRATIONS.DYTE        — Dyte is not enabled
//   PORTAL                   — dead in this fork: the UMI home links articles
//                              out to the storefront instead of rendering them
const UNREACHABLE = /^(PRE_CHAT_FORM|CHAT_FORM|INTEGRATIONS\.DYTE|PORTAL)\./;

describe('Thai widget locale', () => {
  it('carries every key the English locale has', () => {
    expect(Object.keys(enKeys).filter(key => !(key in thKeys))).toEqual([]);
  });

  it('translates every UMI string, so no UMI surface falls back to English', () => {
    const untranslated = Object.keys(enKeys).filter(
      key => key.startsWith('UMI.') && thKeys[key] === enKeys[key]
    );
    expect(untranslated).toEqual([]);
  });

  it('leaves English only in strings this configuration never renders', () => {
    const untranslated = Object.keys(enKeys).filter(
      key => thKeys[key] === enKeys[key] && !UNREACHABLE.test(key)
    );
    expect(untranslated).toEqual([]);
  });

  // Thai has no plural inflection, so the two halves of a pluralised string are
  // deliberately the same words. Dropping the separator would silently change
  // which branch vue-i18n picks.
  it('keeps the plural separator on pluralised strings', () => {
    Object.keys(enKeys)
      .filter(key => String(enKeys[key]).includes(' | '))
      .forEach(key => expect(String(thKeys[key])).toContain(' | '));
  });
});
