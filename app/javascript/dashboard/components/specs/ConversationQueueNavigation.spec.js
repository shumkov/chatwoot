import { shallowMount, flushPromises } from '@vue/test-utils';
import { ref } from 'vue';
import { createRouter, createMemoryHistory } from 'vue-router';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { useUISettings } from 'dashboard/composables/useUISettings';
import NextButton from 'dashboard/components-next/button/Button.vue';
import SelectMenu from 'dashboard/components-next/selectmenu/SelectMenu.vue';
import ConversationItem from '../ConversationItem.vue';
import ConversationBasicFilter from '../widgets/conversation/ConversationBasicFilter.vue';

vi.mock('@vueuse/core', async () => ({
  ...(await vi.importActual('@vueuse/core')),
  useToggle: () => {
    const open = ref(false);
    return [
      open,
      () => {
        open.value = !open.value;
      },
    ];
  },
}));
vi.mock('dashboard/composables/store');
vi.mock('dashboard/composables/useUISettings');
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('../widgets/conversation/ConversationCard.vue', () => ({
  default: { template: '<button class="card" />' },
}));
vi.mock(
  'dashboard/components-next/Conversation/ConversationCard/ConversationCardExpanded.vue',
  () => ({ default: {} })
);
vi.mock('dashboard/components/ui/ContextMenu.vue', () => ({ default: {} }));
vi.mock('../widgets/conversation/contextMenu/Index.vue', () => ({
  default: {},
}));

describe('shared queue navigation and saved filters', () => {
  let router;
  let wrapper;
  let updateUISettings;
  let provide;
  beforeEach(async () => {
    provide = Object.fromEntries(
      [
        'selectConversation',
        'deSelectConversation',
        'assignAgent',
        'assignTeam',
        'assignLabels',
        'removeLabels',
        'updateConversationStatus',
        'toggleContextMenu',
        'markAsUnread',
        'markAsRead',
        'assignPriority',
        'isConversationSelected',
        'deleteConversation',
      ].map(key => [key, vi.fn(() => false)])
    );
    router = createRouter({
      history: createMemoryHistory(),
      routes: [{ path: '/:pathMatch(.*)*', component: {} }],
    });
    await router.push(
      '/app/accounts/1/label/collaboration-pending?status=all&assignee_type=all'
    );
    await router.isReady();
    useStore.mockReturnValue({ dispatch: vi.fn(), getters: {} });
    useMapGetter.mockImplementation(key =>
      ref(
        {
          getSelectedChat: {},
          'inboxes/getInboxes': [],
          getSelectedInbox: 0,
          getCurrentAccountId: 1,
          getChatStatusFilter: 'all',
          getChatSortFilter: 'last_activity_at_desc',
        }[key]
      )
    );
    updateUISettings = vi.fn();
    useUISettings.mockReturnValue({
      updateUISettings,
      uiSettings: ref({
        conversations_filter_by: {
          status: 'resolved',
          order_by: 'last_activity_at_desc',
        },
      }),
    });
    window.chatwootConfig = { hostURL: 'https://chat.umi.store' };
  });
  afterEach(() => {
    wrapper?.unmount();
    vi.restoreAllMocks();
  });

  it('keeps the shared queue filters when opening a conversation card', async () => {
    wrapper = shallowMount(ConversationItem, {
      props: { source: { id: 42 }, label: 'collaboration-pending' },
      global: {
        plugins: [router],
        provide,
        stubs: { ConversationCard: false },
      },
    });
    await wrapper.find('.card').trigger('click');
    await flushPromises();
    expect(router.currentRoute.value.path).toContain('/42');
    expect(router.currentRoute.value.query).toEqual({
      status: 'all',
      assignee_type: 'all',
    });
  });

  it('keeps the shared queue filters when opening a conversation in a new tab', async () => {
    const open = vi.spyOn(window, 'open').mockImplementation(() => {});
    wrapper = shallowMount(ConversationItem, {
      props: { source: { id: 42 }, label: 'collaboration-pending' },
      global: {
        plugins: [router],
        provide,
        stubs: { ConversationCard: false },
      },
    });
    await wrapper.find('.card').trigger('click', { ctrlKey: true });
    const url = new URL(open.mock.calls[0][0]);
    expect(Object.fromEntries(url.searchParams)).toEqual({
      status: 'all',
      assignee_type: 'all',
    });
  });

  it('changing sort leaves the saved status unchanged despite the temporary all-status queue', async () => {
    wrapper = shallowMount(ConversationBasicFilter, {
      props: { isOnExpandedLayout: false },
      global: {
        plugins: [router],
        mocks: { $t: key => key },
        directives: { tooltip: {} },
      },
    });
    wrapper.findComponent(NextButton).vm.$emit('click');
    await flushPromises();
    const menus = wrapper.findAllComponents(SelectMenu);
    expect(menus).toHaveLength(2);
    menus[1].vm.$emit('update:modelValue', 'created_at_asc');
    await flushPromises();
    expect(updateUISettings).toHaveBeenCalledWith({
      conversations_filter_by: {
        status: 'resolved',
        order_by: 'created_at_asc',
      },
    });
  });

  it.each(['', 'collaboration-pending'])(
    'does not forward unrelated or invalid query values from label %s',
    async label => {
      await router.push(
        '/app/accounts/1/label/collaboration-pending?status=invalid&assignee_type=invalid&search=private'
      );
      wrapper = shallowMount(ConversationItem, {
        props: { source: { id: 42 }, label },
        global: {
          plugins: [router],
          provide,
          stubs: { ConversationCard: false },
        },
      });
      await wrapper.find('.card').trigger('click');
      await flushPromises();
      expect(router.currentRoute.value.query).toEqual({});
    }
  );

  it('a deliberate status choice still saves the chosen status', async () => {
    wrapper = shallowMount(ConversationBasicFilter, {
      props: { isOnExpandedLayout: false },
      global: {
        plugins: [router],
        mocks: { $t: key => key },
        directives: { tooltip: {} },
      },
    });
    wrapper.findComponent(NextButton).vm.$emit('click');
    await flushPromises();
    wrapper
      .findAllComponents(SelectMenu)[0]
      .vm.$emit('update:modelValue', 'pending');
    await flushPromises();
    expect(updateUISettings).toHaveBeenCalledWith({
      conversations_filter_by: {
        status: 'pending',
        order_by: 'last_activity_at_desc',
      },
    });
  });
});
