<script setup>
// UMI patch: the widget home's single input block.
// - No conversation yet → a composer; typing sends the first message
//   (`conversation/sendMessage` creates the conversation) and opens the chat.
// - A conversation already exists → a "Continue conversation" button into the chat.
// See UMI-PATCHES.md / docs/UMI-WIDGET-HOME-SPEC.md.
import { ref } from 'vue';
import { useRouter } from 'vue-router';
import { useStore, useMapGetter } from 'dashboard/composables/store.js';
import UmiIcon from 'widget/components/UmiIcon.vue';

const store = useStore();
const router = useRouter();
const conversationSize = useMapGetter('conversation/getConversationSize');

const content = ref('');
const isSending = ref(false);

const openChat = () => router.replace({ name: 'messages' });

const submit = async () => {
  const text = content.value.trim();
  if (!text || isSending.value) return;

  // Pre-chat form for a brand-new visitor: fall back to the standard flow —
  // we can't carry the draft through the form.
  if (
    window.chatwootWebChannel?.preChatFormEnabled &&
    conversationSize.value === 0
  ) {
    router.replace({ name: 'prechat-form' });
    return;
  }

  isSending.value = true;
  content.value = '';
  await store.dispatch('conversation/sendMessage', { content: text });
  openChat();
};

const onKeydown = e => {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    submit();
  }
};
</script>

<template>
  <button
    v-if="conversationSize > 0"
    type="button"
    class="umi-control flex items-center justify-between w-full gap-2 px-4 min-h-11 text-[15px] leading-6 bg-n-background text-n-slate-12"
    @click="openChat"
  >
    <span>{{ $t('UMI.CONTINUE') }}</span>
    <UmiIcon name="arrow" class="w-[15px] rtl:rotate-180" />
  </button>

  <form v-else class="umi-composer w-full" @submit.prevent="submit">
    <textarea
      v-model="content"
      rows="1"
      :placeholder="$t('UMI.TYPE_MESSAGE')"
      :aria-label="$t('UMI.TYPE_MESSAGE')"
      class="umi-composer-input"
      @keydown="onKeydown"
    />
    <button
      type="submit"
      class="umi-composer-send"
      :aria-label="$t('UMI.SEND')"
      :disabled="!content.trim()"
    >
      <UmiIcon name="arrow" class="w-[15px] rtl:rotate-180" />
    </button>
  </form>
</template>
