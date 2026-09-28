import { flushPromises, shallowMount } from '@vue/test-utils';
import UmiShopifyLinks from '../UmiShopifyLinks.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import en from 'dashboard/i18n/locale/en/conversation.json';
import API from 'dashboard/api/integrations/umiShopify';

vi.mock('dashboard/api/integrations/umiShopify', () => ({
  default: {
    commerce: vi.fn(),
    preview: vi.fn(),
    link: vi.fn(),
    customers: vi.fn(),
    customer: vi.fn(),
    unlink: vi.fn(),
    refresh: vi.fn(),
  },
}));

const empty = {
  customer: null,
  orders: { items: [], cursor: null },
  drafts: { items: [], cursor: null },
  linked: [],
  draft_access: true,
};

const labels = en.CONVERSATION_SIDEBAR.SHOPIFY.LINKS;

describe('UmiShopifyLinks', () => {
  it('clears the old selection when previewing another purchase fails', async () => {
    API.commerce.mockResolvedValue({ data: empty });
    API.preview.mockResolvedValueOnce({
      data: {
        name: '#1001',
        status: 'PENDING',
        admin_url: 'https://umi.myshopify.com/admin/orders/1',
      },
    });
    const wrapper = shallowMount(UmiShopifyLinks, {
      props: { conversationId: 1 },
    });
    await flushPromises();
    await wrapper
      .find('[data-testid="shopify-reference"]')
      .setValue('https://umi.myshopify.com/admin/orders/1');
    await wrapper.findAll('form')[1].trigger('submit');
    await flushPromises();
    expect(wrapper.find('[data-testid="shopify-preview"]').exists()).toBe(true);
    API.preview.mockRejectedValueOnce({
      response: { data: { error: 'unavailable' } },
    });
    await wrapper
      .find('[data-testid="shopify-reference"]')
      .setValue('https://umi.myshopify.com/admin/orders/2');
    await wrapper.findAll('form')[1].trigger('submit');
    await flushPromises();
    expect(wrapper.find('[data-testid="shopify-preview"]').exists()).toBe(
      false
    );
    expect(API.link).not.toHaveBeenCalled();
  });

  it('warns that a completed draft can already contain a recorded payment', async () => {
    API.commerce.mockResolvedValue({ data: empty });
    API.preview.mockResolvedValueOnce({
      data: { name: '#D1001', status: 'COMPLETED', order_id: '10' },
    });
    const wrapper = shallowMount(UmiShopifyLinks, {
      props: { conversationId: 1 },
    });
    await flushPromises();
    await wrapper
      .find('[data-testid="shopify-reference"]')
      .setValue('https://umi.myshopify.com/admin/draft_orders/1');
    await wrapper.findAll('form')[1].trigger('submit');
    await flushPromises();
    expect(wrapper.text()).toContain(
      'changing this link later requires maintenance.'
    );
  });
  it('shows manual linking controls for a contact without email or phone', async () => {
    API.commerce.mockResolvedValue({ data: empty });
    const wrapper = shallowMount(UmiShopifyLinks, {
      props: { conversationId: 1 },
    });
    await flushPromises();
    expect(wrapper.find('[data-testid="shopify-reference"]').exists()).toBe(
      true
    );
    expect(API.link).not.toHaveBeenCalled();
  });

  it('ignores an old conversation response after switching chats', async () => {
    let resolveOld;
    API.commerce.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          resolveOld = resolve;
        })
    );
    API.commerce.mockResolvedValue({
      data: { ...empty, customer: { id: '2', name: 'Current customer' } },
    });
    const wrapper = shallowMount(UmiShopifyLinks, {
      props: { conversationId: 1 },
    });
    await wrapper.setProps({ conversationId: 2 });
    await flushPromises();
    resolveOld({
      data: { ...empty, customer: { id: '1', name: 'Old customer' } },
    });
    await flushPromises();
    expect(wrapper.text()).toContain('Current customer');
    expect(wrapper.text()).not.toContain('Old customer');
  });
  it('keeps the selected customer when an older history request arrives last', async () => {
    let resolveOld;
    API.commerce.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          resolveOld = resolve;
        })
    );
    API.commerce.mockResolvedValue({
      data: { ...empty, customer: { id: '2', name: 'New customer' } },
    });
    API.customers.mockResolvedValue({
      data: { items: [{ id: '2', name: 'New customer' }], cursor: null },
    });
    API.customer.mockResolvedValue({});
    const wrapper = shallowMount(UmiShopifyLinks, {
      props: { conversationId: 1 },
    });
    await wrapper.find('input[type="search"]').setValue('New');
    await wrapper.findAll('form')[0].trigger('submit');
    await flushPromises();
    wrapper
      .findAllComponents(Button)
      .find(button => button.props('label') === labels.CHOOSE_CUSTOMER)
      .vm.$emit('click');
    await flushPromises();
    expect(wrapper.text()).toContain('New customer');
    resolveOld({
      data: { ...empty, customer: { id: '1', name: 'Old customer' } },
    });
    await flushPromises();
    expect(wrapper.text()).toContain('New customer');
    expect(wrapper.text()).not.toContain('Old customer');
  });
  it('shows a Shopify pagination error and keeps the cursor for retry', async () => {
    API.commerce.mockResolvedValueOnce({
      data: {
        ...empty,
        orders: { items: [{ id: '1', name: '#1001' }], cursor: 'more' },
      },
    });
    API.commerce.mockResolvedValueOnce({
      data: { ...empty, error: 'shopify_unavailable' },
    });
    const wrapper = shallowMount(UmiShopifyLinks, {
      props: { conversationId: 1 },
    });
    await flushPromises();
    wrapper
      .findAllComponents(Button)
      .find(button => button.props('label') === labels.MORE)
      .vm.$emit('click');
    await flushPromises();
    expect(wrapper.find('[role="alert"]').text()).toBe(
      labels.ERRORS.shopify_unavailable
    );
    expect(
      wrapper
        .findAllComponents(Button)
        .some(button => button.props('label') === labels.MORE)
    ).toBe(true);
    expect(wrapper.text()).toContain('#1001');
  });
  it('clears the preview when the operator edits the pasted URL', async () => {
    API.commerce.mockResolvedValue({ data: empty });
    API.preview.mockResolvedValue({
      data: { name: '#1001', status: 'PENDING' },
    });
    const wrapper = shallowMount(UmiShopifyLinks, {
      props: { conversationId: 1 },
    });
    await flushPromises();
    await wrapper
      .find('[data-testid="shopify-reference"]')
      .setValue('https://umi.myshopify.com/admin/orders/1');
    await wrapper.findAll('form')[1].trigger('submit');
    await flushPromises();
    expect(wrapper.find('[data-testid="shopify-preview"]').exists()).toBe(true);
    await wrapper
      .find('[data-testid="shopify-reference"]')
      .setValue('https://umi.myshopify.com/admin/orders/2');
    expect(wrapper.find('[data-testid="shopify-preview"]').exists()).toBe(
      false
    );
  });
});
