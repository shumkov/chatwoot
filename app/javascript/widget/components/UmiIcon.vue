<script setup>
// UMI: the storefront theme's own icon artwork (umi-store-theme assets/icon-close.svg,
// icon-back.svg, icon-arrow.svg), so the Assistance drawer draws the same strokes as the
// drawers around it. Close and back are 1 px hairlines at any size (non-scaling stroke); the
// arrow is the theme's filled list/submit arrow. Always decorative: the button carries the name.
// See docs/UMI-ASSISTANCE-DRAWER-CHROME-SPEC.md.
import { computed } from 'vue';

const props = defineProps({
  name: {
    type: String,
    required: true,
    validator: value => ['close', 'back', 'arrow'].includes(value),
  },
});

const ARTWORK = {
  close: { viewBox: '0 0 10 10', stroke: 'M0 0l10 10M10 0 0 10' },
  back: { viewBox: '0 0 10 10', stroke: 'M10 4.5H1M4.5 1 1 4.5M1 4.5 4.5 8' },
  arrow: {
    viewBox: '0 0 14 10',
    fill: 'M8.537.808a.5.5 0 0 1 .817-.162l4 4a.5.5 0 0 1 0 .708l-4 4a.5.5 0 1 1-.708-.708L11.793 5.5H1a.5.5 0 0 1 0-1h10.793L8.646 1.354a.5.5 0 0 1-.109-.546',
  },
};

const artwork = computed(() => ARTWORK[props.name]);
</script>

<template>
  <svg
    xmlns="http://www.w3.org/2000/svg"
    fill="none"
    :viewBox="artwork.viewBox"
    aria-hidden="true"
    focusable="false"
    class="shrink-0"
  >
    <path
      v-if="artwork.stroke"
      stroke="currentColor"
      vector-effect="non-scaling-stroke"
      :d="artwork.stroke"
    />
    <path
      v-else
      fill="currentColor"
      fill-rule="evenodd"
      clip-rule="evenodd"
      :d="artwork.fill"
    />
  </svg>
</template>
