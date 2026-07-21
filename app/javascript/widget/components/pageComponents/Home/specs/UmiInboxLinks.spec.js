import { mount } from '@vue/test-utils';
import UmiInboxLinks from '../UmiInboxLinks.vue';

describe('UmiInboxLinks', () => {
  it('renders the five UMI messenger links with the expected hrefs', () => {
    const wrapper = mount(UmiInboxLinks);
    const links = wrapper.findAll('a');
    expect(links).toHaveLength(5);
    expect(links.map(link => link.attributes('href'))).toEqual([
      'https://wa.me/66975311301',
      'https://line.me/R/ti/p/~@umi.store',
      'https://m.me/umi.clothing.store',
      'https://ig.me/m/umi.asia',
      'tel:+66975311301',
    ]);
  });

  it('opens every link safely in a new tab', () => {
    const wrapper = mount(UmiInboxLinks);
    wrapper.findAll('a').forEach(link => {
      expect(link.attributes('target')).toBe('_blank');
      expect(link.attributes('rel')).toContain('noopener');
    });
  });

  it('labels each channel', () => {
    const text = mount(UmiInboxLinks).text();
    ['WhatsApp', 'LINE', 'Messenger', 'Instagram', 'Call'].forEach(label => {
      expect(text).toContain(label);
    });
  });
});
