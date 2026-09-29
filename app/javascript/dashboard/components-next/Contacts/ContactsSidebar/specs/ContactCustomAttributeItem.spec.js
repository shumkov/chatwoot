import { shallowMount, flushPromises } from '@vue/test-utils';
import axios from 'axios';
import { createStore } from 'vuex';
import Contacts from 'dashboard/store/modules/contacts';
import ContactCustomAttributeItem from '../ContactCustomAttributeItem.vue';
import ListAttribute from 'dashboard/components-next/CustomAttributes/ListAttribute.vue';
import { useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';

global.axios = axios;
vi.mock('axios');
vi.mock('dashboard/composables/store');
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { contactId: 7 } }),
}));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));

describe('Contact custom attribute server errors', () => {
  it.each(['update', 'delete'])(
    'shows the protected-field 422 explanation through the real store for %s',
    async action => {
      const store = createStore({ modules: { contacts: Contacts } });
      useStore.mockReturnValue(store);
      const request = action === 'update' ? axios.patch : axios.post;
      request.mockRejectedValue({
        message: 'Request failed with status code 422',
        response: {
          status: 422,
          data: { error: 'Customer payment history is managed automatically' },
        },
      });
      const wrapper = shallowMount(ContactCustomAttributeItem, {
        props: {
          attribute: {
            attributeKey: 'umi_paid_order_count',
            attributeDisplayType: 'list',
            attributeDisplayName: 'Paid orders',
          },
        },
      });
      wrapper.findComponent(ListAttribute).vm.$emit(action, '2');
      await flushPromises();
      expect(request).toHaveBeenCalledOnce();
      expect(useAlert).toHaveBeenCalledOnce();
      expect(useAlert).toHaveBeenCalledWith(
        'Customer payment history is managed automatically'
      );
    }
  );
});
