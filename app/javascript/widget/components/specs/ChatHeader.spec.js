import { mount } from '@vue/test-utils';
import ChatHeader from '../ChatHeader.vue';

vi.mock('vue-router', () => ({ useRouter: () => ({ replace: vi.fn() }) }));
vi.mock('widget/composables/useAvailability', () => ({
  useAvailability: () => ({ isOnline: { value: true } }),
}));

describe('ChatHeader', () => {
  const mountHeader = props =>
    mount(ChatHeader, {
      props: { title: 'Chat', ...props },
      global: {
        mocks: { $t: key => key },
        directives: {
          dompurifyHtml: (el, { value }) => {
            el.innerHTML = value;
          },
        },
        stubs: { HeaderActions: true, AvailabilityContainer: true },
      },
    });

  // Sub-views go back with the storefront's back arrow, mirroring the close cross.
  it('draws the theme back arrow, named for screen readers', () => {
    const back = mountHeader({ showBackButton: true }).find(
      'button[aria-label="UMI.BACK"]'
    );

    expect(back.find('path').attributes('d')).toBe(
      'M10 4.5H1M4.5 1 1 4.5M1 4.5 4.5 8'
    );
  });

  // Presence is a colour dot; it also has to exist as text.
  it('announces the online dot as text', () => {
    expect(mountHeader().find('.umi-online-dot').text()).toBe('UMI.ONLINE');
  });
});
