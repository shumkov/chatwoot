<script setup>
import UmiIcon from 'widget/components/UmiIcon.vue';

const props = defineProps({
  slug: {
    type: String,
    default: '',
  },
  link: {
    type: String,
    default: '',
  },
  title: {
    type: String,
    default: '',
  },
});
const emit = defineEmits(['selectArticle']);
const onClick = () => {
  emit('selectArticle', props.slug || props.link);
};
</script>

<template>
  <button
    class="umi-ink-hover flex items-center justify-between w-full gap-4 py-2.5 text-[15px] leading-6 ltr:text-left rtl:text-right"
    @click="onClick"
  >
    <span>{{ title }}</span>
    <UmiIcon name="arrow" class="w-[15px] rtl:rotate-180" />
  </button>
</template>
