import { mount } from '@vue/test-utils';
import { createI18n } from 'vue-i18n';
import i18nMessages from 'widget/i18n';
import AgentMessage from '../AgentMessage.vue';
import UmiMessageMeta from '../UmiMessageMeta.vue';

// Under each team group the transcript names who wrote it. People get their photo; Chatwoot's
// automatic messages are signed by UMI, never as a blue "Bot".
describe('AgentMessage signature', () => {
  beforeEach(() => {
    window.chatwootWebChannel = { enabledFeatures: [], websiteName: 'Website' };
  });

  const signature = message =>
    mount(AgentMessage, {
      props: {
        message: {
          id: 1,
          content: 'Hi!',
          created_at: 1793808000,
          showAvatar: true,
          ...message,
        },
      },
      global: {
        plugins: [
          createI18n({ legacy: false, locale: 'en', messages: i18nMessages }),
        ],
        directives: { dompurifyHtml: () => {} },
        stubs: { AgentMessageBubble: true, MessageReplyButton: true },
      },
    }).findComponent(UmiMessageMeta);

  it('names an agent with their photo', () => {
    const meta = signature({
      message_type: 1,
      sender: {
        type: 'user',
        available_name: 'Nok',
        avatar_url: 'https://x/nok.jpg',
      },
    });

    expect(meta.props('name')).toBe('Nok');
    expect(meta.props('avatarUrl')).toBe('https://x/nok.jpg');
  });

  it('signs a message with no sender as UMI, automatic, without a photo', () => {
    const meta = signature({ message_type: 3, content_type: 'input_email' });

    expect(meta.props('name')).toBe('UMI, automatic');
    expect(meta.props('avatarUrl')).toBe('');
  });

  it('gives a bot its name but not a photo', () => {
    const meta = signature({
      message_type: 1,
      sender: {
        type: 'agent_bot',
        name: 'Helper',
        avatar_url: 'https://x/bot.png',
      },
    });

    expect(meta.props('name')).toBe('Helper');
    expect(meta.props('avatarUrl')).toBe('');
  });

  it('keeps the name a channel gave a message without a Chatwoot sender', () => {
    const meta = signature({
      message_type: 1,
      additional_attributes: { sender_name: 'Ploy' },
    });

    expect(meta.props('name')).toBe('Ploy');
    expect(meta.props('avatarUrl')).toBe('');
  });

  it('signs only the last message of a group', () => {
    expect(signature({ message_type: 1, showAvatar: false }).exists()).toBe(
      false
    );
  });
});
