import { getFeaturedArticles, getMostReadArticles } from 'widget/api/article';
import { getFromCache, setCache } from 'shared/helpers/cache';

const CACHE_KEY_PREFIX = 'chatwoot_featured_articles_';

const state = {
  records: [],
  uiFlags: {
    isError: false,
    hasFetched: false,
    isFetching: false,
  },
};

export const getters = {
  uiFlags: $state => $state.uiFlags,
  popularArticles: $state => $state.records,
};

export const actions = {
  fetch: async ({ commit }, { slug, locale }) => {
    commit('setIsFetching', true);
    commit('setError', false);

    try {
      if (!locale) return;
      const cachedData = getFromCache(`${CACHE_KEY_PREFIX}${slug}_${locale}`);
      if (cachedData) {
        commit('setArticles', cachedData);
        return;
      }

      // Prefer the storefront-curated featured set; fall back to most-read when
      // nothing is featured yet, or if the featured request errors — so the drawer
      // FAQ is never blank.
      let payload = [];
      try {
        const { data } = await getFeaturedArticles(slug, locale);
        payload = data.payload || [];
      } catch (error) {
        payload = [];
      }
      if (!payload.length) {
        const { data } = await getMostReadArticles(slug, locale);
        payload = data.payload || [];
      }

      // Only cache a non-empty result — caching [] would mask a later curated set
      // for the full cache TTL and keep the drawer FAQ blank.
      if (payload.length) {
        setCache(`${CACHE_KEY_PREFIX}${slug}_${locale}`, payload);
        commit('setArticles', payload);
      }
    } catch (error) {
      commit('setError', true);
    } finally {
      commit('setIsFetching', false);
    }
  },
};

export const mutations = {
  setArticles($state, data) {
    $state.records = data;
  },
  setError($state, value) {
    $state.uiFlags.isError = value;
  },
  setIsFetching($state, value) {
    $state.uiFlags.isFetching = value;
  },
};

export default {
  namespaced: true,
  state,
  getters,
  actions,
  mutations,
};
