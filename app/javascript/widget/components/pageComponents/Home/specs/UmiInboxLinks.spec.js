import { mount } from '@vue/test-utils';
import UmiInboxLinks from '../UmiInboxLinks.vue';

// Returns the key, so an assertion on the key proves the string went through
// i18n rather than being a literal that no translator can reach.
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));

const mountLinks = () =>
  mount(UmiInboxLinks, {
    global: { mocks: { $t: key => key } },
  });

describe('UmiInboxLinks', () => {
  it('renders the five UMI messenger links with the expected hrefs', () => {
    const links = mountLinks().findAll('a');
    expect(links).toHaveLength(5);
    expect(links.map(link => link.attributes('href'))).toEqual([
      'https://wa.me/66800053593',
      'https://line.me/R/ti/p/~@umi.store',
      'https://m.me/umi.clothing.store',
      'https://ig.me/m/umi.asia',
      'tel:+66975311301',
    ]);
  });

  it('opens every link safely in a new tab', () => {
    mountLinks()
      .findAll('a')
      .forEach(link => {
        expect(link.attributes('target')).toBe('_blank');
        expect(link.attributes('rel')).toContain('noopener');
      });
  });

  // Brand names read the same in every language and are deliberately literals.
  it('labels the messenger channels with their proper nouns', () => {
    const text = mountLinks().text();
    ['WhatsApp', 'LINE', 'Messenger', 'Instagram'].forEach(label => {
      expect(text).toContain(label);
    });
  });

  // The heading and the phone link are prose. They were literals until the Thai
  // pass, which is exactly why nobody could translate them — this pins that they
  // stay reachable from a locale file.
  it('translates the prose rather than hardcoding it', () => {
    const text = mountLinks().text();
    expect(text).toContain('UMI.CHANNELS_HEADING');
    expect(text).toContain('UMI.CALL');
    expect(text).not.toContain('Chat with us on');
  });
});
