<script setup>
// UMI patch: the widget home's single input block.
// - No conversation yet → a composer; typing sends the first message
//   (`conversation/sendMessage` creates the conversation) and opens the chat.
// - A conversation already exists → a "Continue conversation" button into the chat.
// See UMI-PATCHES.md / docs/UMI-WIDGET-HOME-SPEC.md.
import { ref } from 'vue';
import { useRouter } from 'vue-router';
import { useStore, useMapGetter } from 'dashboard/composables/store.js';
import ChatSendButton from 'widget/components/ChatSendButton.vue';

const store = useStore();
const router = useRouter();
const conversationSize = useMapGetter('conversation/getConversationSize');
const widgetColor = useMapGetter('appConfig/getWidgetColor');

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
    class="flex items-center justify-between w-full gap-2 px-4 py-3 font-medium border border-n-container bg-n-background text-n-slate-12"
    @click="openChat"
  >
    <span>{{ $t('UMI.CONTINUE') }}</span>
    <span
      class="i-lucide-chevron-right size-5 shrink-0"
      :style="{ color: widgetColor }"
    />
  </button>

  <form v-else class="umi-composer w-full" @submit.prevent="submit">
    <textarea
      v-model="content"
      rows="1"
      :placeholder="$t('UMI.TYPE_MESSAGE')"
      class="umi-composer-input flex-1 h-8 min-h-8 py-1 my-2 text-sm bg-transparent border-none outline-none resize-none text-n-slate-12 placeholder:text-n-slate-10 max-h-24"
      @keydown="onKeydown"
    />
    <ChatSendButton
      :color="widgetColor || '#121212'"
      :disabled="!content.trim()"
    />
  </form>
</template>
