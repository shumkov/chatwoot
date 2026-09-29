import { shallowMount, flushPromises } from '@vue/test-utils';
import { ref } from 'vue';
import axios from 'axios';
import { createStore } from 'vuex';
import Contacts from 'dashboard/store/modules/contacts';
import CustomAttributes from '../CustomAttributes.vue';
import CustomAttribute from 'dashboard/components/CustomAttribute.vue';
import { useStore, useStoreGetters } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useUISettings } from 'dashboard/composables/useUISettings';

global.axios = axios;
vi.mock('axios');
vi.mock('dashboard/composables/store');
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/composables/useUISettings');
vi.mock('vue-router', () => ({ useRoute: () => ({ params: {} }) }));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));

describe('Conversation custom attributes', () => {
  const dispatch = vi.fn();
  let wrapper;

  beforeEach(() => {
    dispatch.mockReset();
    useStore.mockReturnValue({ dispatch });
    useStoreGetters.mockReturnValue({
      getSelectedChat: ref({
        id: 42,
        custom_attributes: { umi_sales_status: 'engaged' },
      }),
      'attributes/getAttributesByModel': ref(() => [
        {
          id: 1,
          attribute_key: 'umi_sales_status',
          attribute_display_type: 'list',
          attribute_display_name: 'Sales status',
          attribute_values: ['engaged', 'qualified'],
        },
      ]),
      'contacts/getContact': ref(() => ({
        custom_attributes: { umi_vip: 'no', umi_wholesale: 'unknown' },
      })),
    });
    useUISettings.mockReturnValue({
      uiSettings: ref({}),
      updateUISettings: vi.fn(),
    });
    wrapper = shallowMount(CustomAttributes, {
      props: { attributeFrom: 'conversation' },
      global: {
        stubs: {
          Draggable: {
            props: ['list'],
            template:
              '<div><slot v-for="element in list" name="item" :element="element" /></div>',
          },
        },
      },
    });
  });

  it('does not resend an unrelated stale role from the contact form', async () => {
    await wrapper.setProps({
      attributeType: 'contact_attribute',
      contactId: 7,
    });
    dispatch.mockResolvedValue({});
    wrapper.findComponent(CustomAttribute).vm.$emit('update', 'umi_vip', 'yes');
    await flushPromises();
    expect(dispatch).toHaveBeenCalledWith('contacts/update', {
      id: 7,
      customAttributes: { umi_vip: 'yes' },
    });
  });

  it('patches only the edited contact field and waits for the server', async () => {
    await wrapper.setProps({
      attributeType: 'contact_attribute',
      contactId: 7,
    });
    let finish;
    dispatch.mockReturnValue(
      new Promise(resolve => {
        finish = resolve;
      })
    );
    wrapper.findComponent(CustomAttribute).vm.$emit('update', 'umi_vip', 'yes');
    await flushPromises();
    expect(useAlert).not.toHaveBeenCalled();
    expect(dispatch).toHaveBeenCalledWith('contacts/update', {
      id: 7,
      customAttributes: { umi_vip: 'yes' },
    });
    finish();
    await flushPromises();
    expect(useAlert).toHaveBeenCalledWith(
      'CUSTOM_ATTRIBUTES.FORM.UPDATE.SUCCESS'
    );
  });

  it.each(['update', 'delete'])(
    'shows the protected-field 422 explanation through the real store for contact %s',
    async action => {
      await wrapper.setProps({
        attributeType: 'contact_attribute',
        contactId: 7,
      });
      const store = createStore({ modules: { contacts: Contacts } });
      dispatch.mockImplementation(store.dispatch);
      const request = action === 'update' ? axios.patch : axios.post;
      request.mockRejectedValue({
        message: 'Request failed with status code 422',
        response: {
          status: 422,
          data: { error: 'Customer payment history is managed automatically' },
        },
      });
      wrapper
        .findComponent(CustomAttribute)
        .vm.$emit(action, 'umi_paid_order_count', 0);
      await flushPromises();
      expect(useAlert).toHaveBeenCalledOnce();
      expect(useAlert).toHaveBeenCalledWith(
        'Customer payment history is managed automatically'
      );
      expect(request).toHaveBeenCalledOnce();
    }
  );

  it('marks the attribute the operator actually edited', async () => {
    wrapper
      .findComponent(CustomAttribute)
      .vm.$emit('update', 'umi_sales_status', 'qualified');
    await flushPromises();
    expect(dispatch).toHaveBeenCalledWith('updateCustomAttributes', {
      conversationId: 42,
      customAttributes: { umi_sales_status: 'qualified' },
      changedAttributeKey: 'umi_sales_status',
    });
    expect(useAlert).toHaveBeenCalledWith(
      'CUSTOM_ATTRIBUTES.FORM.UPDATE.SUCCESS'
    );
  });

  it('shows rejected qualification as an error without a success alert', async () => {
    dispatch.mockRejectedValue({
      response: {
        data: { error: 'Qualification requires live incoming evidence' },
      },
    });
    wrapper
      .findComponent(CustomAttribute)
      .vm.$emit('update', 'umi_sales_status', 'qualified');
    await flushPromises();
    expect(useAlert).toHaveBeenCalledOnce();
    expect(useAlert).toHaveBeenCalledWith(
      'Qualification requires live incoming evidence'
    );
  });

  it('marks deletion intent and displays its rejection', async () => {
    dispatch.mockRejectedValue({
      response: { data: { error: 'Sales status cannot be removed' } },
    });
    wrapper
      .findComponent(CustomAttribute)
      .vm.$emit('delete', 'umi_sales_status');
    await flushPromises();
    expect(dispatch).toHaveBeenCalledWith('updateCustomAttributes', {
      conversationId: 42,
      customAttributes: {},
      changedAttributeKey: 'umi_sales_status',
    });
    expect(useAlert).toHaveBeenCalledOnce();
    expect(useAlert).toHaveBeenCalledWith('Sales status cannot be removed');
  });
});
