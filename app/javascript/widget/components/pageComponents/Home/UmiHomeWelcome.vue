<script setup>
// UMI patch: a short, translatable availability line at the top of the widget
// home (replaces the "We are online / Start conversation" card). See
// docs/UMI-WIDGET-HOME-SPEC.md.
</script>

<template>
  <p class="text-sm leading-relaxed text-n-slate-11">
    {{ $t('UMI.WELCOME') }}
  </p>
</template>
