import { mount } from '@vue/test-utils';
import UmiIcon from '../UmiIcon.vue';

// The drawer must draw the storefront theme's artwork, not an approximation: the cross and the
// back arrow stay 1 px hairlines at any size only because their stroke does not scale.
describe('UmiIcon', () => {
  it.each([
    ['close', 'M0 0l10 10M10 0 0 10'],
    ['back', 'M10 4.5H1M4.5 1 1 4.5M1 4.5 4.5 8'],
  ])('draws the theme %s as a non-scaling hairline', (name, d) => {
    const path = mount(UmiIcon, { props: { name } }).find('path');

    expect(path.attributes('d')).toBe(d);
    expect(path.attributes('stroke')).toBe('currentColor');
    expect(path.attributes('vector-effect')).toBe('non-scaling-stroke');
  });

  it('draws the theme list arrow', () => {
    const path = mount(UmiIcon, { props: { name: 'arrow' } }).find('path');

    expect(path.attributes('d')).toBe(
      'M8.537.808a.5.5 0 0 1 .817-.162l4 4a.5.5 0 0 1 0 .708l-4 4a.5.5 0 1 1-.708-.708L11.793 5.5H1a.5.5 0 0 1 0-1h10.793L8.646 1.354a.5.5 0 0 1-.109-.546'
    );
  });

  it('is hidden from assistive technology, so the button carries the name', () => {
    const svg = mount(UmiIcon, { props: { name: 'arrow' } }).find('svg');

    expect(svg.attributes('aria-hidden')).toBe('true');
    expect(svg.attributes('focusable')).toBe('false');
  });
});
