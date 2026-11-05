import { mount } from '@vue/test-utils';
import AgentMessage from '../AgentMessage.vue';
import UserMessage from '../UserMessage.vue';
import ImageBubble from '../ImageBubble.vue';
import FileBubble from '../FileBubble.vue';

// A photo sent in the chat must show once, as a photo. A file card under it repeats the same
// attachment as a "Download" row; only a photo that fails to load falls back to the file card.
describe('message attachments', () => {
  beforeEach(() => {
    window.chatwootWebChannel = { enabledFeatures: [] };
  });

  const message = (fileType, extra = {}) => ({
    id: 1,
    content: '',
    created_at: 1793808000,
    showAvatar: true,
    attachments: [
      {
        id: 7,
        file_type: fileType,
        data_url: `https://chat.umi.store/blob/${fileType}.bin`,
      },
    ],
    ...extra,
  });

  const mountMessage = (component, msg) =>
    mount(component, {
      props: { message: msg },
      global: {
        mocks: {
          $t: key => key,
          $store: { getters: { 'appConfig/getWidgetColor': '#121212' } },
        },
        directives: { dompurifyHtml: () => {} },
        stubs: { Avatar: true, MessageReplyButton: true, ReplyToChip: true },
      },
    });

  describe.each([
    ['from the team', AgentMessage, { message_type: 1 }],
    ['from the visitor', UserMessage, { message_type: 0 }],
  ])('%s', (_label, component, type) => {
    it('shows a photo once, without a file card under it', () => {
      const wrapper = mountMessage(component, message('image', type));

      expect(wrapper.findComponent(ImageBubble).exists()).toBe(true);
      expect(wrapper.findComponent(FileBubble).exists()).toBe(false);
    });

    it('falls back to the file card when the photo fails to load', async () => {
      const wrapper = mountMessage(component, message('image', type));
      await wrapper.findComponent(ImageBubble).vm.$emit('error');

      expect(wrapper.findComponent(ImageBubble).exists()).toBe(false);
      expect(wrapper.findComponent(FileBubble).exists()).toBe(true);
    });

    it('shows a document as a file card', () => {
      const wrapper = mountMessage(component, message('file', type));

      expect(wrapper.findComponent(FileBubble).exists()).toBe(true);
    });
  });
});
