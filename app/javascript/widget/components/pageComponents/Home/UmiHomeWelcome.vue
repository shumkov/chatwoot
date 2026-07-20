<script setup>
// UMI patch: the welcome adapts to our support hours (9 AM–9 PM, Asia/Bangkok,
// UTC+7). Open → "available within minutes"; closed → a countdown to the next
// 9 AM, so a visitor in any timezone knows when we're back without converting
// clocks. Snapshot when the widget opens (does not tick live).
// See docs/UMI-WIDGET-HOME-SPEC.md.
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

const OPEN_HOUR = 9;
const CLOSE_HOUR = 21;
const BKK_OFFSET_MS = 7 * 60 * 60 * 1000;

const { t, locale } = useI18n();

const formatDuration = (hrs, mins) => {
  const parts = [];
  if (locale.value === 'th') {
    if (hrs) parts.push(`${hrs} ชั่วโมง`);
    if (mins) parts.push(`${mins} นาที`);
  } else {
    if (hrs) parts.push(`${hrs} hour${hrs > 1 ? 's' : ''}`);
    if (mins) parts.push(`${mins} minute${mins > 1 ? 's' : ''}`);
  }
  return parts.join(' ');
};

const message = computed(() => {
  const bkk = new Date(Date.now() + BKK_OFFSET_MS);
  const h = bkk.getUTCHours();
  const m = bkk.getUTCMinutes();
  if (h >= OPEN_HOUR && h < CLOSE_HOUR) return t('UMI.WELCOME_ONLINE');
  const minsUntil =
    h < OPEN_HOUR
      ? OPEN_HOUR * 60 - (h * 60 + m)
      : 24 * 60 - (h * 60 + m) + OPEN_HOUR * 60;
  return t('UMI.WELCOME_AWAY', {
    time: formatDuration(Math.floor(minsUntil / 60), minsUntil % 60),
  });
});
</script>

<template>
  <p class="py-2 text-sm leading-relaxed text-n-slate-12">{{ message }}</p>
</template>
