<script setup>
// UMI: the day label above each day of the Assistance transcript, in the cart's section-label
// style and the reader's language. Takes the day's first message time rather than Chatwoot's
// English "MMM dd, yyyy" group key. See docs/UMI-ASSISTANCE-CONVERSATION-SPEC.md section 3.
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { isToday, isYesterday } from 'date-fns';
import { umiDayLabel } from 'widget/helpers/umiMessageTime';

const props = defineProps({
  timestamp: { type: Number, required: true },
});

const { t, locale } = useI18n();

const label = computed(() => {
  const date = new Date(props.timestamp * 1000);
  if (isToday(date)) return t('TODAY');
  if (isYesterday(date)) return t('YESTERDAY');
  return umiDayLabel(props.timestamp, locale.value);
});
</script>

<template>
  <div class="umi-section-label umi-date-label">{{ label }}</div>
</template>
