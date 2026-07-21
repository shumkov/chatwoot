import { mutations, actions, getters } from '../articles';
import { getFeaturedArticles, getMostReadArticles } from 'widget/api/article';
import { getFromCache, setCache } from 'shared/helpers/cache';

vi.mock('widget/api/article');
vi.mock('shared/helpers/cache');

describe('Vuex Articles Module', () => {
  let state;

  beforeEach(() => {
    state = {
      records: [],
      uiFlags: {
        isError: false,
        hasFetched: false,
        isFetching: false,
      },
    };
  });

  describe('Mutations', () => {
    it('sets articles correctly', () => {
      const articles = [{ id: 1 }, { id: 2 }];
      mutations.setArticles(state, articles);
      expect(state.records).toEqual(articles);
    });

    it('sets error flag correctly', () => {
      mutations.setError(state, true);
      expect(state.uiFlags.isError).toBe(true);
    });

    it('sets fetching state correctly', () => {
      mutations.setIsFetching(state, true);
      expect(state.uiFlags.isFetching).toBe(true);
    });

    it('does not mutate records when no articles are provided', () => {
      const previousState = { ...state };
      mutations.setArticles(state, []);
      expect(state.records).toEqual(previousState.records);
    });

    it('toggles the error state correctly', () => {
      mutations.setError(state, true);
      expect(state.uiFlags.isError).toBe(true);
      mutations.setError(state, false);
      expect(state.uiFlags.isError).toBe(false);
    });

    it('toggles the fetching state correctly', () => {
      mutations.setIsFetching(state, true);
      expect(state.uiFlags.isFetching).toBe(true);
      mutations.setIsFetching(state, false);
      expect(state.uiFlags.isFetching).toBe(false);
    });
  });

  describe('Actions', () => {
    describe('#fetch', () => {
      const slug = 'test-slug';
      const locale = 'en';
      const articles = [
        { id: 1, title: 'Test' },
        { id: 2, title: 'Test 2' },
      ];
      let commit;

      beforeEach(() => {
        commit = vi.fn();
        vi.clearAllMocks();
      });

      it('returns cached data if available', async () => {
        getFromCache.mockReturnValue(articles);

        await actions.fetch({ commit }, { slug, locale });

        expect(getFromCache).toHaveBeenCalledWith(
          `chatwoot_featured_articles_${slug}_${locale}`
        );
        expect(getFeaturedArticles).not.toHaveBeenCalled();
        expect(getMostReadArticles).not.toHaveBeenCalled();
        expect(setCache).not.toHaveBeenCalled();
        expect(commit).toHaveBeenCalledWith('setArticles', articles);
        expect(commit).toHaveBeenCalledWith('setError', false);
      });

      it('uses the featured set when available, without the most-read fallback', async () => {
        getFromCache.mockReturnValue(null);
        getFeaturedArticles.mockResolvedValue({ data: { payload: articles } });

        await actions.fetch({ commit }, { slug, locale });

        expect(getFeaturedArticles).toHaveBeenCalledWith(slug, locale);
        expect(getMostReadArticles).not.toHaveBeenCalled();
        expect(setCache).toHaveBeenCalledWith(
          `chatwoot_featured_articles_${slug}_${locale}`,
          articles
        );
        expect(commit).toHaveBeenCalledWith('setArticles', articles);
        expect(commit).toHaveBeenCalledWith('setError', false);
      });

      it('falls back to most-read when the featured set is empty', async () => {
        getFromCache.mockReturnValue(null);
        getFeaturedArticles.mockResolvedValue({ data: { payload: [] } });
        getMostReadArticles.mockResolvedValue({ data: { payload: articles } });

        await actions.fetch({ commit }, { slug, locale });

        expect(getMostReadArticles).toHaveBeenCalledWith(slug, locale);
        expect(commit).toHaveBeenCalledWith('setArticles', articles);
        expect(commit).toHaveBeenCalledWith('setError', false);
      });

      it('falls back to most-read when the featured request errors', async () => {
        getFromCache.mockReturnValue(null);
        getFeaturedArticles.mockRejectedValue(new Error('featured boom'));
        getMostReadArticles.mockResolvedValue({ data: { payload: articles } });

        await actions.fetch({ commit }, { slug, locale });

        expect(getMostReadArticles).toHaveBeenCalledWith(slug, locale);
        expect(commit).toHaveBeenCalledWith('setArticles', articles);
        expect(commit).toHaveBeenCalledWith('setError', false);
      });

      it('sets error when both featured and most-read fail', async () => {
        getFromCache.mockReturnValue(null);
        getFeaturedArticles.mockRejectedValue(new Error('featured boom'));
        getMostReadArticles.mockRejectedValue(new Error('most-read boom'));

        await actions.fetch({ commit }, { slug, locale });

        expect(commit).toHaveBeenCalledWith('setError', true);
        expect(commit).toHaveBeenCalledWith('setIsFetching', false);
        expect(commit).not.toHaveBeenCalledWith(
          'setArticles',
          expect.any(Array)
        );
      });

      it('does not mutate state when both sources return empty', async () => {
        getFromCache.mockReturnValue(null);
        getFeaturedArticles.mockResolvedValue({ data: { payload: [] } });
        getMostReadArticles.mockResolvedValue({ data: { payload: [] } });

        await actions.fetch({ commit }, { slug, locale });

        expect(commit).toHaveBeenCalledWith('setIsFetching', true);
        expect(commit).toHaveBeenCalledWith('setError', false);
        expect(commit).not.toHaveBeenCalledWith(
          'setArticles',
          expect.any(Array)
        );
        expect(commit).toHaveBeenCalledWith('setIsFetching', false);
      });

      it('sets loading state during fetch', async () => {
        getFromCache.mockReturnValue(null);
        getFeaturedArticles.mockResolvedValue({ data: { payload: articles } });

        await actions.fetch({ commit }, { slug, locale });

        expect(commit).toHaveBeenCalledWith('setIsFetching', true);
        expect(commit).toHaveBeenCalledWith('setIsFetching', false);
      });
    });
  });

  describe('Getters', () => {
    it('returns uiFlags correctly', () => {
      const result = getters.uiFlags(state);
      expect(result).toEqual(state.uiFlags);
    });

    it('returns popularArticles correctly', () => {
      const result = getters.popularArticles(state);
      expect(result).toEqual(state.records);
    });
  });
});
