<script setup>
import { computed } from 'vue';
import ArticleListItem from './ArticleListItem.vue';
import UmiIcon from 'widget/components/UmiIcon.vue';

const props = defineProps({
  articles: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits(['view', 'viewAll']);

const articlesToDisplay = computed(() => props.articles.slice(0, 6));

const onArticleClick = slug => {
  emit('view', slug);
};
</script>

<template>
  <div class="flex flex-col">
    <h3 class="umi-section-label">{{ $t('UMI.FAQ') }}</h3>
    <div class="flex flex-col">
      <ArticleListItem
        v-for="article in articlesToDisplay"
        :key="article.slug"
        :slug="article.slug"
        :link="article.link"
        :title="article.title"
        @select-article="onArticleClick"
      />
    </div>
    <div class="mt-2">
      <button
        class="umi-ink-hover inline-flex items-center gap-2 min-h-11 text-[13px] leading-5"
        @click="$emit('viewAll')"
      >
        <span>{{ $t('UMI.ALL_TOPICS') }}</span>
        <UmiIcon name="arrow" class="w-[15px] rtl:rotate-180" />
      </button>
    </div>
  </div>
</template>
