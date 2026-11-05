import { mount } from '@vue/test-utils';
import { createI18n } from 'vue-i18n';
import i18nMessages from 'widget/i18n';
import UmiMessageMeta from '../UmiMessageMeta.vue';

// The line under each group says who wrote it and when, in the reader's language.
const AT_23_22 = Date.UTC(2026, 10, 4, 23, 22) / 1000;

const mountMeta = (props, locale = 'en') =>
  mount(UmiMessageMeta, {
    props: { time: AT_23_22, ...props },
    global: {
      plugins: [createI18n({ legacy: false, locale, messages: i18nMessages })],
    },
  });

describe('UmiMessageMeta', () => {
  it('signs a team group with the person, their photo and the time', () => {
    const wrapper = mountMeta({ name: 'Nok', avatarUrl: 'https://x/nok.jpg' });

    expect(wrapper.text()).toMatch(/^Nok\s+·/);
    expect(wrapper.find('time').text()).toMatch(/^11:22\sPM$/);
    // The dot is hidden from screen readers; a comma keeps "Nok" and the time apart.
    expect(wrapper.find('.sr-only').text()).toBe(',');
    expect(wrapper.find('img').attributes('src')).toBe('https://x/nok.jpg');
    // The name is already in the text; the photo must not be read out again.
    expect(wrapper.find('img').attributes('alt')).toBe('');
    expect(wrapper.find('time').attributes('datetime')).toBe(
      '2026-11-04T23:22:00.000Z'
    );
  });

  it('draws no photo when there is none', () => {
    expect(mountMeta({ name: 'UMI, automatic' }).find('img').exists()).toBe(
      false
    );
  });

  // Position alone does not reach a screen reader: the visitor's line says "You".
  it('names the visitor for screen readers only', () => {
    const wrapper = mountMeta({ align: 'end' });

    expect(wrapper.find('.sr-only').text()).toBe('You,');
    expect(wrapper.classes()).toContain('justify-end');
  });

  it('says a failed message was not sent, instead of a time', () => {
    const wrapper = mountMeta({ align: 'end', failed: true });

    expect(wrapper.text()).toContain('Not sent');
    expect(wrapper.find('time').exists()).toBe(false);
  });

  it('uses the Thai clock in Thai', () => {
    expect(mountMeta({ name: 'Nok' }, 'th').find('time').text()).toBe('23:22');
  });
});
