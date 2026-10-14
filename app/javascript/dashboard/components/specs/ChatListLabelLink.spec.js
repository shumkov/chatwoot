import { config, shallowMount } from '@vue/test-utils';
import { nextTick, reactive, ref } from 'vue';
import { useRoute } from 'vue-router';
import { useStore } from 'vuex';
import { useMapGetter, useFunctionGetter } from 'dashboard/composables/store';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { useBulkActions } from 'dashboard/composables/chatlist/useBulkActions';
import ChatList from '../ChatList.vue';
import ChatTypeTabs from '../widgets/ChatTypeTabs.vue';

vi.mock('vue-router', () => ({ useRoute: vi.fn(), useRouter: () => ({}) }));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('vuex', () => ({ useStore: vi.fn() }));
vi.mock('dashboard/composables/store');
vi.mock('dashboard/composables/useUISettings');
vi.mock('dashboard/composables/chatlist/useBulkActions');
vi.mock('shared/composables/useFilter', () => ({ useFilter: () => ({}) }));
vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
  useTrack: vi.fn(),
}));
vi.mock('dashboard/composables/emitter', () => ({ useEmitter: vi.fn() }));
vi.mock('dashboard/composables/useConversationRequiredAttributes', () => ({
  useConversationRequiredAttributes: () => ({}),
}));
vi.mock('../ChatListHeader.vue', () => ({ default: {} }));
vi.mock('../ConversationList.vue', () => ({ default: {} }));
vi.mock('dashboard/components-next/dialog/Dialog.vue', () => ({ default: {} }));
vi.mock('next/filter/ConversationFilter.vue', () => ({ default: {} }));
vi.mock('next/filter/SaveCustomView.vue', () => ({ default: {} }));
vi.mock('../widgets/ChatTypeTabs.vue', () => ({ default: {} }));
vi.mock('dashboard/routes/dashboard/customviews/DeleteCustomViews.vue', () => ({
  default: {},
}));
vi.mock('../widgets/conversation/conversationBulkActions/Index.vue', () => ({
  default: {},
}));
vi.mock('dashboard/components-next/TeleportWithDirection.vue', () => ({
  default: {},
}));
vi.mock(
  'dashboard/components-next/ConversationWorkflow/ConversationResolveAttributesModal.vue',
  () => ({ default: {} })
);

describe('label queue deep links', () => {
  let route;
  let dispatch;
  let fetchedFilters;
  let uiSettings;
  let updateUISettings;
  let wrapper;
  let currentUser;

  beforeEach(() => {
    config.global.mocks.$t = key => key;
    route = reactive({ query: {} });
    useRoute.mockReturnValue(route);
    fetchedFilters = [];
    let currentFilters;
    dispatch = vi.fn((action, value) => {
      if (
        action === 'updateChatListFilters' ||
        action === 'setChatListFilters'
      ) {
        currentFilters = { ...value };
      }
      if (action === 'fetchAllConversations') {
        fetchedFilters.push(currentFilters);
      }
      return Promise.resolve();
    });
    useStore.mockReturnValue({ dispatch });
    uiSettings = ref({ conversations_filter_by: { status: 'resolved' } });
    updateUISettings = vi.fn();
    useUISettings.mockReturnValue({ uiSettings, updateUISettings });
    currentUser = ref({
      id: 1,
      accounts: [{ id: 1, permissions: ['administrator'] }],
    });
    useMapGetter.mockImplementation(key => {
      if (key === 'getCurrentUser') {
        return currentUser;
      }
      if (key === 'getCurrentAccountId') return ref(1);
      if (key === 'conversationStats/getStats') return ref({});
      if (
        ['getMineChats', 'getAllStatusChats', 'getUnAssignedChats'].includes(
          key
        )
      ) {
        return ref(() => []);
      }
      return ref([]);
    });
    useFunctionGetter.mockImplementation(key => {
      if (key === 'inboxes/getInbox') return ref({});
      return ref(0);
    });
    useBulkActions.mockReturnValue({
      selectedConversations: ref([]),
      selectedInboxes: ref([]),
      resetBulkActions: vi.fn(),
    });
  });

  afterEach(() => wrapper?.unmount());

  it('opens all owners and statuses on its first fetch despite Mine and a saved resolved filter', () => {
    route.query = { status: 'all', assignee_type: 'all' };
    wrapper = shallowMount(ChatList, {
      props: { label: 'collaboration-pending' },
    });
    expect(fetchedFilters).toHaveLength(1);
    expect(fetchedFilters[0]).toMatchObject({
      status: 'all',
      assigneeType: 'all',
      labels: ['collaboration-pending'],
    });
    expect(updateUISettings).not.toHaveBeenCalled();
    expect(uiSettings.value.conversations_filter_by.status).toBe('resolved');
  });

  it('updates an already mounted label view when only the query changes, then restores normal filters', async () => {
    wrapper = shallowMount(ChatList, {
      props: { label: 'collaboration-pending' },
    });
    expect(fetchedFilters.at(-1)).toMatchObject({
      status: 'resolved',
      assigneeType: 'me',
    });
    route.query = { status: 'all', assignee_type: 'all' };
    await nextTick();
    expect(fetchedFilters.at(-1)).toMatchObject({
      status: 'all',
      assigneeType: 'all',
    });
    expect(
      dispatch.mock.calls
        .filter(([action]) => action === 'setChatStatusFilter')
        .at(-1)
    ).toEqual(['setChatStatusFilter', 'all']);
    route.query = {};
    await nextTick();
    expect(fetchedFilters.at(-1)).toMatchObject({
      status: 'resolved',
      assigneeType: 'me',
    });
    expect(
      dispatch.mock.calls
        .filter(([action]) => action === 'setChatStatusFilter')
        .at(-1)
    ).toEqual(['setChatStatusFilter', 'resolved']);
    expect(updateUISettings).not.toHaveBeenCalled();
  });

  it('restores ordinary filters when leaving the label and reapplies the explicit link when returning', async () => {
    route.query = { status: 'all', assignee_type: 'all' };
    wrapper = shallowMount(ChatList, {
      props: { label: 'collaboration-pending' },
    });
    await wrapper.setProps({ label: '' });
    expect(fetchedFilters.at(-1)).toMatchObject({
      status: 'resolved',
      assigneeType: 'me',
      labels: undefined,
    });
    await wrapper.setProps({ label: 'collaboration-pending' });
    expect(fetchedFilters.at(-1)).toMatchObject({
      status: 'all',
      assigneeType: 'all',
    });
  });

  it.each([
    [{ status: 'all' }, { status: 'all', assigneeType: 'me' }],
    [
      { assignee_type: 'unassigned' },
      { status: 'resolved', assigneeType: 'unassigned' },
    ],
    [
      { status: 'invalid', assignee_type: 'all' },
      { status: 'resolved', assigneeType: 'all' },
    ],
    [
      { status: ['all'], assignee_type: ['all'] },
      { status: 'resolved', assigneeType: 'me' },
    ],
    [
      { status: null, assignee_type: 'invalid' },
      { status: 'resolved', assigneeType: 'me' },
    ],
  ])('validates each explicit filter separately: %j', (query, expected) => {
    route.query = query;
    wrapper = shallowMount(ChatList, {
      props: { label: 'collaboration-pending' },
    });
    expect(fetchedFilters[0]).toMatchObject(expected);
  });

  it('restores the tab selected before opening a link, including after a partial query replaces it', async () => {
    wrapper = shallowMount(ChatList, {
      props: { label: 'collaboration-pending' },
    });
    wrapper.findComponent(ChatTypeTabs).vm.$emit('chatTabChange', 'unassigned');
    await nextTick();
    expect(fetchedFilters.at(-1).assigneeType).toBe('unassigned');
    route.query = { status: 'all', assignee_type: 'all' };
    await nextTick();
    route.query = { status: 'pending' };
    await nextTick();
    expect(fetchedFilters.at(-1)).toMatchObject({
      status: 'pending',
      assigneeType: 'unassigned',
    });
    route.query = {};
    await nextTick();
    expect(fetchedFilters.at(-1)).toMatchObject({
      status: 'resolved',
      assigneeType: 'unassigned',
    });
    expect(updateUISettings).not.toHaveBeenCalled();
  });

  it('cannot select an assignee tab hidden by native permissions', () => {
    currentUser.value.accounts[0].permissions = [
      'conversation_unassigned_manage',
    ];
    route.query = { status: 'all', assignee_type: 'all' };
    wrapper = shallowMount(ChatList, {
      props: { label: 'collaboration-pending' },
    });
    expect(fetchedFilters[0]).toMatchObject({
      status: 'all',
      assigneeType: 'me',
    });
  });

  it('uses ordinary defaults when no preferences exist and preserves default sort for an explicit link', async () => {
    uiSettings.value = {};
    wrapper = shallowMount(ChatList, {
      props: { label: 'collaboration-pending' },
    });
    expect(fetchedFilters[0]).toMatchObject({
      status: 'open',
      assigneeType: 'me',
    });
    route.query = { status: 'all', assignee_type: 'all' };
    await nextTick();
    expect(fetchedFilters.at(-1)).toMatchObject({
      status: 'all',
      assigneeType: 'all',
      sortBy: 'last_activity_at_desc',
    });
    route.query = {};
    await nextTick();
    expect(fetchedFilters.at(-1)).toMatchObject({
      status: 'open',
      assigneeType: 'me',
    });
  });

  it('leaves ordinary routes unchanged even when those query keys are present', async () => {
    route.query = { status: 'all', assignee_type: 'all' };
    wrapper = shallowMount(ChatList);
    expect(fetchedFilters[0]).toMatchObject({
      status: 'resolved',
      assigneeType: 'me',
    });
    route.query = { status: 'open', assignee_type: 'unassigned' };
    await nextTick();
    expect(fetchedFilters).toHaveLength(1);
  });
});
