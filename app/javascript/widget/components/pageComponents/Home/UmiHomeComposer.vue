<script setup>
// UMI patch: a composer on the widget home screen so visitors can start typing
// immediately instead of clicking through a "Start conversation" screen.
//
// Submitting sends the first message via the same action ChatFooter uses
// (`conversation/sendMessage`, which creates the conversation when none exists)
// and navigates into the chat. See UMI-PATCHES.md.
import { ref } from 'vue';
import { useRouter } from 'vue-router';
import { useStore, useMapGetter } from 'dashboard/composables/store.js';

const store = useStore();
const router = useRouter();
const conversationSize = useMapGetter('conversation/getConversationSize');
const widgetColor = useMapGetter('appConfig/getWidgetColor');
const sendLabel = 'Send';

const content = ref('');
const isSending = ref(false);

const submit = async () => {
  const text = content.value.trim();
  if (!text || isSending.value) return;

  // If a pre-chat form is configured for a brand-new visitor, fall back to the
  // standard flow — we can't carry the draft through the form.
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
  router.replace({ name: 'messages' });
};

const onKeydown = e => {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    submit();
  }
};
</script>

<template>
  <form
    class="flex items-end w-full gap-2 p-2 outline-1 outline outline-n-container rounded-xl bg-n-background dark:bg-n-solid-2"
    @submit.prevent="submit"
  >
    <textarea
      v-model="content"
      rows="1"
      placeholder="Type your message…"
      class="flex-1 px-1 py-1.5 text-sm bg-transparent border-0 outline-none resize-none text-n-slate-12 placeholder:text-n-slate-10 max-h-24"
      @keydown="onKeydown"
    />
    <button
      type="submit"
      :disabled="!content.trim()"
      :aria-label="sendLabel"
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
