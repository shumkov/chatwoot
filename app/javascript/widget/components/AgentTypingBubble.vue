<script>
export default {
  name: 'AgentTypingBubble',
};
</script>

<!-- UMI: the transcript says "Typing…" in words instead of Chatwoot's typing gif. -->
<template>
  <div class="agent-message-wrap sticky bottom-1">
    <div
      class="umi-typing mt-2 bg-white text-xs leading-[16.8px] text-[rgba(var(--umi-ink),0.75)]"
    >
      {{ $t('UMI.TYPING') }}
    </div>
  </div>
</template>
