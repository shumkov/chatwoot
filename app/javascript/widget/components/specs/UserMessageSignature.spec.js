import { mount } from '@vue/test-utils';
import { createI18n } from 'vue-i18n';
import i18nMessages from 'widget/i18n';
import UserMessage from '../UserMessage.vue';
import UmiMessageMeta from '../UmiMessageMeta.vue';

// The visitor's messages are signed with the time under the last one of a group. A message that
// failed to send must say so in words wherever it sits, because the transcript has no red bubble.
describe('UserMessage signature', () => {
  const mountMessage = message =>
    mount(UserMessage, {
      props: {
        message: {
          id: 1,
          content: 'Hi!',
          message_type: 0,
          created_at: 1793808000,
          showAvatar: true,
          ...message,
        },
      },
      global: {
        plugins: [
          createI18n({ legacy: false, locale: 'en', messages: i18nMessages }),
        ],
        mocks: {
          $store: { getters: { 'appConfig/getWidgetColor': '#121212' } },
        },
        directives: { dompurifyHtml: () => {} },
        stubs: { UserMessageBubble: true, MessageReplyButton: true },
      },
    });

  it('ends a group with its time', () => {
    const wrapper = mountMessage({});

    expect(wrapper.findComponent(UmiMessageMeta).props('failed')).toBe(false);
    expect(wrapper.classes()).toContain('umi-group-end');
  });

  it('stays unsigned inside a group', () => {
    const wrapper = mountMessage({ showAvatar: false });

    expect(wrapper.findComponent(UmiMessageMeta).exists()).toBe(false);
    expect(wrapper.classes()).not.toContain('umi-group-end');
  });

  it('shows no time while it is still sending', () => {
    expect(
      mountMessage({ status: 'in_progress' })
        .findComponent(UmiMessageMeta)
        .exists()
    ).toBe(false);
  });

  it('says "Not sent" on a failed message even inside a group', () => {
    const wrapper = mountMessage({ status: 'failed', showAvatar: false });

    expect(wrapper.findComponent(UmiMessageMeta).props('failed')).toBe(true);
    expect(wrapper.text()).toContain('Not sent');
  });
});
