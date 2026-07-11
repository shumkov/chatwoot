<script setup>
import { computed, onMounted, watch } from 'vue';
import ArticleBlock from 'widget/components/pageComponents/Home/Article/ArticleBlock.vue';
import ArticleCardSkeletonLoader from 'widget/components/pageComponents/Home/Article/SkeletonLoader.vue';
import { useI18n } from 'vue-i18n';
import { useStore } from 'dashboard/composables/store';
import { useMapGetter } from 'dashboard/composables/store.js';
import { getMatchingLocale } from 'shared/helpers/portalHelper';

// UMI: articles open on the storefront Help Center (see UMI-WIDGET-HOME-SPEC.md).
const STOREFRONT_FALLBACK = 'https://umi.store';
const storefrontOrigin = () => {
  try {
    return new URL(document.referrer).origin;
  } catch (error) {
    return STOREFRONT_FALLBACK;
  }
};

const store = useStore();
const i18n = useI18n();

const portal = computed(() => window.chatwootWebChannel.portal);

const popularArticles = useMapGetter('article/popularArticles');
const articleUiFlags = useMapGetter('article/uiFlags');

const locale = computed(() => {
  const { locale: selectedLocale } = i18n;

  if (!portal.value || !portal.value.config) return null;

  const { allowed_locales: allowedLocales } = portal.value.config;
  return getMatchingLocale(selectedLocale.value, allowedLocales);
});

const fetchArticles = () => {
  if (portal.value && locale.value) {
    store.dispatch('article/fetch', {
      slug: portal.value.slug,
      locale: locale.value,
    });
  }
};

// Open the matching storefront blog article (same tab).
const openArticleOnHelpPage = slug => {
  window.top.location.href = `${storefrontOrigin()}/blogs/help/${slug}`;
};

const viewAllArticles = () => {
  window.top.location.href = `${storefrontOrigin()}/pages/help`;
};

const hasArticles = computed(
  () =>
    !articleUiFlags.value.isFetching &&
    !articleUiFlags.value.isError &&
    !!popularArticles.value.length &&
    !!locale.value
);

// Watch for locale changes and refetch articles
watch(locale, (newLocale, oldLocale) => {
  if (newLocale && newLocale !== oldLocale) {
    fetchArticles();
  }
});

onMounted(() => fetchArticles());
</script>

<template>
  <div
    v-if="portal && (articleUiFlags.isFetching || !!popularArticles.length)"
    class="w-full shadow outline-1 outline outline-n-container rounded-xl bg-n-background dark:bg-n-solid-2 px-5 py-4"
  >
    <ArticleBlock
      v-if="hasArticles"
      :articles="popularArticles"
      @view="openArticleOnHelpPage"
      @view-all="viewAllArticles"
    />
    <ArticleCardSkeletonLoader v-if="articleUiFlags.isFetching" />
  </div>
  <div v-else class="hidden" />
</template>
