// UMI: message times and day labels in the reader's language (Intl), not Chatwoot's fixed
// English date-fns patterns. Chatwoot's locale codes use an underscore (pt_BR, zh_CN), which Intl
// rejects, so they are turned into BCP 47 tags first.
export const umiLocaleTag = locale => (locale || 'en').replace('_', '-');

export const umiMessageTime = (unixSeconds, locale) =>
  new Intl.DateTimeFormat(umiLocaleTag(locale), {
    hour: 'numeric',
    minute: '2-digit',
  }).format(new Date(unixSeconds * 1000));

export const umiDayLabel = (unixSeconds, locale, now = new Date()) => {
  const date = new Date(unixSeconds * 1000);
  return new Intl.DateTimeFormat(umiLocaleTag(locale), {
    day: 'numeric',
    month: 'long',
    ...(date.getFullYear() === now.getFullYear() ? {} : { year: 'numeric' }),
  }).format(date);
};
