<script setup>
// UMI patch: the widget home's single input block.
// - No conversation yet → a composer; typing sends the first message
//   (`conversation/sendMessage` creates the conversation) and opens the chat.
// - A conversation already exists → a "Continue conversation" button into the chat.
// See UMI-PATCHES.md / docs/UMI-WIDGET-HOME-SPEC.md.
import { ref } from 'vue';
import { useRouter } from 'vue-router';
import { useStore, useMapGetter } from 'dashboard/composables/store.js';

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
    class="flex items-center justify-between w-full gap-2 px-4 py-3 font-medium outline outline-1 outline-n-container rounded-xl bg-n-background dark:bg-n-solid-2 text-n-slate-12"
    @click="openChat"
  >
    <span>{{ $t('UMI.CONTINUE') }}</span>
    <span
      class="i-lucide-chevron-right size-5 shrink-0"
      :style="{ color: widgetColor }"
    />
  </button>

  <form
    v-else
    class="flex items-end w-full gap-2 p-2 outline outline-1 outline-n-container rounded-xl bg-n-background dark:bg-n-solid-2"
    @submit.prevent="submit"
  >
    <textarea
      v-model="content"
      rows="1"
      :placeholder="$t('UMI.TYPE_MESSAGE')"
      class="flex-1 px-2 py-2 text-sm bg-transparent border-0 outline-none resize-none text-n-slate-12 placeholder:text-n-slate-10 max-h-24"
      @keydown="onKeydown"
    />
    <button
      type="submit"
      :disabled="!content.trim()"
      :aria-label="$t('UMI.SEND')"
      class="inline-flex items-center justify-center text-white rounded-lg shrink-0 size-9 disabled:opacity-40"
      :style="{ backgroundColor: widgetColor || '#1f93ff' }"
    >
      <svg
        viewBox="0 0 24 24"
        width="18"
        height="18"
        fill="none"
        stroke="currentColor"
        stroke-width="1.8"
        stroke-linecap="round"
        stroke-linejoin="round"
        aria-hidden="true"
      >
        <path d="M22 2 11 13" />
        <path d="M22 2 15 22l-4-9-9-4 20-7z" />
      </svg>
    </button>
  </form>
</template>
