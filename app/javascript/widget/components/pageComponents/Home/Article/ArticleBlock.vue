<script setup>
import { computed } from 'vue';
import ArticleListItem from './ArticleListItem.vue';
import { useMapGetter } from 'dashboard/composables/store';

const props = defineProps({
  articles: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits(['view', 'viewAll']);

const widgetColor = useMapGetter('appConfig/getWidgetColor');

const articlesToDisplay = computed(() => props.articles.slice(0, 6));

const onArticleClick = slug => {
  emit('view', slug);
};
</script>

<template>
  <div class="flex flex-col gap-3">
    <h3 class="text-sm font-semibold text-n-slate-12">{{ $t('UMI.FAQ') }}</h3>
    <div class="flex flex-col gap-2">
      <ArticleListItem
        v-for="article in articlesToDisplay"
        :key="article.slug"
        :slug="article.slug"
        :link="article.link"
        :title="article.title"
        @select-article="onArticleClick"
      />
    </div>
    <div>
      <button
        class="text-sm font-medium tracking-wide inline-flex items-center gap-1"
        :style="{ color: widgetColor }"
        @click="$emit('viewAll')"
      >
        <span>{{ $t('UMI.ALL_TOPICS') }}</span>
        <span class="i-lucide-arrow-right size-3.5 shrink-0" />
      </button>
    </div>
  </div>
</template>
