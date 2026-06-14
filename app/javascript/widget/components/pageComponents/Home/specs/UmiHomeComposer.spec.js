import { mount, flushPromises } from '@vue/test-utils';
import UmiHomeComposer from '../UmiHomeComposer.vue';

const { dispatch, replace, conversationSize } = vi.hoisted(() => ({
  dispatch: vi.fn(),
  replace: vi.fn(),
  conversationSize: { value: 0 },
}));

vi.mock('dashboard/composables/store.js', () => ({
  useStore: () => ({ dispatch }),
  useMapGetter: () => conversationSize,
}));

vi.mock('vue-router', () => ({
  useRouter: () => ({ replace }),
}));

describe('UmiHomeComposer', () => {
  beforeEach(() => {
    window.chatwootWebChannel = { preChatFormEnabled: false };
    conversationSize.value = 0;
  });

  it('sends the typed message and opens the chat', async () => {
    const wrapper = mount(UmiHomeComposer);
    await wrapper.find('textarea').setValue('Hello there');
    await wrapper.find('form').trigger('submit');
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith('conversation/sendMessage', {
      content: 'Hello there',
    });
    expect(replace).toHaveBeenCalledWith({ name: 'messages' });
  });

  it('ignores empty / whitespace-only input', async () => {
    const wrapper = mount(UmiHomeComposer);
    await wrapper.find('textarea').setValue('   ');
    await wrapper.find('form').trigger('submit');
    await flushPromises();

    expect(dispatch).not.toHaveBeenCalled();
    expect(replace).not.toHaveBeenCalled();
  });

  it('falls back to the pre-chat form for a new visitor when it is enabled', async () => {
    window.chatwootWebChannel = { preChatFormEnabled: true };
    const wrapper = mount(UmiHomeComposer);
    await wrapper.find('textarea').setValue('Hi');
    await wrapper.find('form').trigger('submit');
    await flushPromises();

    expect(replace).toHaveBeenCalledWith({ name: 'prechat-form' });
    expect(dispatch).not.toHaveBeenCalled();
  });

  it('still sends directly for a returning visitor even if pre-chat is enabled', async () => {
    window.chatwootWebChannel = { preChatFormEnabled: true };
    conversationSize.value = 1;
    const wrapper = mount(UmiHomeComposer);
    await wrapper.find('textarea').setValue('Back again');
    await wrapper.find('form').trigger('submit');
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith('conversation/sendMessage', {
      content: 'Back again',
    });
    expect(replace).toHaveBeenCalledWith({ name: 'messages' });
  });
});
