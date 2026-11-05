<script setup>
// UMI: the line under each group of messages in the Assistance transcript: who wrote it (a
// 20 px photo for people) and when, or "Not sent" for a failed visitor message. The visitor's
// line carries a hidden "You" so screen readers can tell the two sides apart.
// See docs/UMI-ASSISTANCE-CONVERSATION-SPEC.md section 3.
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { umiMessageTime } from 'widget/helpers/umiMessageTime';

const props = defineProps({
  time: { type: Number, required: true },
  name: { type: String, default: '' },
  avatarUrl: { type: String, default: '' },
  align: { type: String, default: 'start' },
  failed: { type: Boolean, default: false },
});

const { t, locale } = useI18n();

const formattedTime = computed(() => umiMessageTime(props.time, locale.value));
const isoTime = computed(() => new Date(props.time * 1000).toISOString());
// Punctuation only: the dot is for the eye, the commas are pauses for screen readers.
const SEPARATOR = ' · ';
const PAUSE = ', ';
const youLabel = computed(() => `${t('YOU')}, `);
</script>

<template>
  <div
    class="umi-message-meta flex items-center gap-2 pt-1 text-xs leading-[16.8px] text-[rgba(var(--umi-ink),0.75)] [:lang(th)_&]:leading-[19.2px]"
    :class="align === 'end' ? 'justify-end' : 'justify-start'"
  >
    <img
      v-if="avatarUrl"
      :src="avatarUrl"
      alt=""
      aria-hidden="true"
      class="umi-avatar size-5 shrink-0 object-cover"
    />
    <span>
      <template v-if="name">
        {{ name }}
        <span aria-hidden="true">{{ SEPARATOR }}</span>
        <span class="sr-only">{{ PAUSE }}</span>
      </template>
      <span v-else-if="align === 'end'" class="sr-only">{{ youLabel }}</span>
      <span v-if="failed">{{ t('UMI.NOT_SENT') }}</span>
      <time v-else :datetime="isoTime">{{ formattedTime }}</time>
    </span>
  </div>
</template>
