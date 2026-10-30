import { mount } from '@vue/test-utils';
import HeaderActions from '../HeaderActions.vue';

vi.mock('widget/helpers/utils', () => ({
  IFrameHelper: { isIFrame: () => true, sendMessage: vi.fn() },
  RNHelper: { isRNWebView: () => false, sendMessage: vi.fn() },
}));

// The drawer closes with the storefront's one close cross, and an icon-only button needs a name.
describe('HeaderActions close button', () => {
  const mountActions = () =>
    mount(HeaderActions, {
      props: { showPopoutButton: false, showEndConversationButton: false },
      global: {
        mocks: {
          $t: key => key,
          $store: {
            getters: {
              'conversationAttributes/getConversationParams': {},
              'appConfig/getCanUserEndConversation': false,
            },
          },
        },
      },
    });

  beforeEach(() => {
    window.chatwootWebChannel = { enabledFeatures: [] };
  });

  it('draws the theme hairline cross and is named for screen readers', () => {
    const close = mountActions().find('.close-button');

    expect(close.attributes('aria-label')).toBe('UMI.CLOSE');
    expect(close.find('path').attributes('d')).toBe('M0 0l10 10M10 0 0 10');
  });
});
