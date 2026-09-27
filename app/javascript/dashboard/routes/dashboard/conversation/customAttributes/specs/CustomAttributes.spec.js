import { shallowMount, flushPromises } from '@vue/test-utils';
import { ref } from 'vue';
import CustomAttributes from '../CustomAttributes.vue';
import CustomAttribute from 'dashboard/components/CustomAttribute.vue';
import { useStore, useStoreGetters } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useUISettings } from 'dashboard/composables/useUISettings';

vi.mock('dashboard/composables/store');
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/composables/useUISettings');
vi.mock('vue-router', () => ({ useRoute: () => ({ params: {} }) }));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));

describe('Conversation custom attributes', () => {
  const dispatch = vi.fn();
  let wrapper;

  beforeEach(() => {
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
      'contacts/getContact': ref(() => ({})),
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
