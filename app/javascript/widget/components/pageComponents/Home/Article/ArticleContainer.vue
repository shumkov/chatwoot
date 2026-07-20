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

// Open the matching topic on the storefront Help Center page, expanded (same tab).
const openArticleOnHelpPage = slug => {
  window.top.location.href = `${storefrontOrigin()}/pages/help#q-${slug}`;
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
    class="w-full mb-2"
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
