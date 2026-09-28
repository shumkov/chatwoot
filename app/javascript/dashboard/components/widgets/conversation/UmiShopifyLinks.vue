<script setup>
import { ref, watch } from 'vue';
import { format } from 'date-fns';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import API from 'dashboard/api/integrations/umiShopify';

const props = defineProps({
  conversationId: { type: [Number, String], required: true },
});
const { t, te } = useI18n();
const prefix = 'CONVERSATION_SIDEBAR.SHOPIFY.LINKS';
// Shopify returns status and error codes that map to the LINKS translations.
/* eslint-disable @intlify/vue-i18n/no-dynamic-keys */
const text = (key, values = {}) => t(`${prefix}.${key}`, values);
const formatDate = value => format(new Date(value), 'MMM d, yyyy');
const data = ref(null);
const loading = ref(false);
const busy = ref(false);
const error = ref('');
const notice = ref('');
const reference = ref('');
const search = ref('');
const customers = ref([]);
const customerCursor = ref(null);
const selection = ref(null);
const removal = ref(null);
let generation = 0;
let loadSequence = 0;

const errorText = code => {
  const key = `${prefix}.ERRORS.${code}`;
  return te(key) ? t(key) : text('ERRORS.shopify_unavailable');
};
const statusText = value => {
  const key = `${prefix}.STATUSES.${value?.toLowerCase()}`;
  return te(key) ? t(key) : text('STATUSES.awaiting');
};

const load = async (page = null) => {
  const current = generation;
  loadSequence += 1;
  const request = loadSequence;
  const id = props.conversationId;
  loading.value = true;
  error.value = '';
  try {
    const params = page ? { [`${page}_after`]: data.value[page].cursor } : {};
    const response = await API.commerce(id, params);
    if (current !== generation || request !== loadSequence) return;
    if (page && response.data.error) {
      error.value = errorText(response.data.error);
      return;
    }
    if (page) {
      data.value[page] = {
        items: [...data.value[page].items, ...response.data[page].items],
        cursor: response.data[page].cursor,
      };
    } else {
      data.value = response.data;
      if (response.data.error) error.value = errorText(response.data.error);
    }
  } catch (e) {
    if (current === generation && request === loadSequence)
      error.value = errorText(e.response?.data?.error);
  } finally {
    if (current === generation && request === loadSequence)
      loading.value = false;
  }
};

const act = async operation => {
  const current = generation;
  const id = props.conversationId;
  busy.value = true;
  error.value = '';
  notice.value = '';
  try {
    await operation(id, current);
  } catch (e) {
    if (current === generation)
      error.value = errorText(e.response?.data?.error);
  } finally {
    if (current === generation) busy.value = false;
  }
};

const findCustomers = (more = false) =>
  act(async (id, current) => {
    const response = await API.customers(
      id,
      search.value,
      more ? customerCursor.value : null
    );
    if (current !== generation) return;
    customers.value = more
      ? [...customers.value, ...response.data.items]
      : response.data.items;
    customerCursor.value = response.data.cursor;
    if (!customers.value.length) notice.value = text('NO_CUSTOMERS');
  });

const chooseCustomer = customer =>
  act(async (id, current) => {
    await API.customer(id, customer.id);
    if (current !== generation) return;
    customers.value = [];
    customerCursor.value = null;
    search.value = '';
    await load();
  });

const preview = url =>
  act(async (id, current) => {
    reference.value = url;
    selection.value = null;
    const response = await API.preview(id, url);
    if (current === generation && reference.value === url) {
      selection.value = response.data;
    }
  });

const confirm = () =>
  act(async (id, current) => {
    await API.link(id, selection.value);
    if (current !== generation) return;
    selection.value = null;
    reference.value = '';
    await load();
  });

const unlink = () =>
  act(async (id, current) => {
    await API.unlink(id, removal.value);
    if (current !== generation) return;
    removal.value = null;
    await load();
  });

const refresh = () =>
  act(async (id, current) => {
    await API.refresh(id);
    if (current !== generation) return;
    notice.value = text('REFRESH_QUEUED');
    await load();
  });

watch(reference, () => {
  selection.value = null;
});

watch(
  () => props.conversationId,
  () => {
    generation += 1;
    data.value = null;
    selection.value = null;
    removal.value = null;
    customers.value = [];
    customerCursor.value = null;
    reference.value = '';
    search.value = '';
    notice.value = '';
    busy.value = false;
    load();
  },
  { immediate: true }
);
</script>

<template>
  <div class="flex flex-col gap-3 px-4 py-2 text-sm text-n-slate-12">
    <p v-if="error" role="alert" class="text-n-ruby-11">{{ error }}</p>
    <p v-if="notice" role="status" class="text-n-slate-11">{{ notice }}</p>
    <Spinner v-if="loading" :size="24" />
    <div v-if="data?.customer" class="break-words">
      <p class="font-medium">{{ data.customer.name }}</p>
      <p class="text-n-slate-11">
        {{ data.customer.email || data.customer.phone }}
      </p>
    </div>
    <form class="flex flex-col gap-2" @submit.prevent="findCustomers()">
      <label :for="`shopify-customer-${conversationId}`">{{
        text('CUSTOMER_SEARCH')
      }}</label>
      <input
        :id="`shopify-customer-${conversationId}`"
        v-model="search"
        type="search"
        :placeholder="text('CUSTOMER_HINT')"
      />
      <Button
        type="submit"
        size="sm"
        variant="outline"
        :disabled="busy || !search.trim()"
        :label="text('SEARCH')"
      />
    </form>
    <div
      v-for="customer in customers"
      :key="customer.id"
      class="flex flex-col gap-1 break-words rounded border border-n-weak p-2"
    >
      <span>{{ customer.name }}</span>
      <span class="text-n-slate-11">
        {{ customer.email }} {{ customer.phone }}
      </span>
      <Button
        size="sm"
        variant="outline"
        :disabled="busy"
        :label="text('CHOOSE_CUSTOMER')"
        @click="chooseCustomer(customer)"
      />
    </div>
    <Button
      v-if="customerCursor"
      size="sm"
      variant="ghost"
      :disabled="busy"
      :label="text('MORE')"
      @click="findCustomers(true)"
    />
    <form class="flex flex-col gap-2" @submit.prevent="preview(reference)">
      <label :for="`shopify-reference-${conversationId}`">{{
        text('REFERENCE')
      }}</label>
      <input
        :id="`shopify-reference-${conversationId}`"
        v-model="reference"
        data-testid="shopify-reference"
        type="url"
        :placeholder="text('REFERENCE_HINT')"
      />
      <Button
        type="submit"
        size="sm"
        variant="outline"
        :disabled="busy || !reference.trim()"
        :label="text('PREVIEW')"
      />
    </form>
    <div
      v-if="selection"
      class="flex flex-col gap-2 rounded border border-n-weak p-3"
      data-testid="shopify-preview"
    >
      <p class="font-medium">
        {{ text('ORDER_SUMMARY', selection) }}
      </p>
      <p>{{ selection.customer?.name || text('NO_CUSTOMER') }}</p>
      <p class="break-words text-n-slate-11">
        {{ selection.customer?.email }} {{ selection.customer?.phone }}
      </p>
      <p>{{ statusText(selection.status) }}</p>
      <p v-if="selection.candidate_conversation">
        {{
          t(`${prefix}.PREVIOUS_CANDIDATE`, {
            id: selection.candidate_conversation,
          })
        }}
      </p>
      <p
        v-if="
          selection.order_id ||
          ['PAID', 'PARTIALLY_REFUNDED', 'REFUNDED'].includes(selection.status)
        "
        class="text-n-amber-11"
      >
        {{
          text(selection.order_id ? 'COMPLETED_DRAFT_WARNING' : 'PAID_WARNING')
        }}
      </p>
      <p v-if="!data?.customer && selection.customer">
        {{ text('ALSO_LINK_CUSTOMER') }}
      </p>
      <Button
        size="sm"
        :disabled="busy"
        :label="text('CONFIRM')"
        @click="confirm"
      />
      <Button
        size="sm"
        variant="ghost"
        :disabled="busy"
        :label="text('CANCEL')"
        @click="selection = null"
      />
    </div>
    <div
      v-if="removal"
      class="flex flex-col gap-2 rounded border border-n-weak p-3"
    >
      <p>{{ t(`${prefix}.REMOVE_PROMPT`, { name: removal.name }) }}</p>
      <Button
        size="sm"
        color="ruby"
        :disabled="busy"
        :label="text('UNLINK')"
        @click="unlink"
      />
      <Button
        size="sm"
        variant="ghost"
        :disabled="busy"
        :label="text('CANCEL')"
        @click="removal = null"
      />
    </div>
    <template v-if="data">
      <h4 class="text-sm font-medium">{{ text('LINKED') }}</h4>
      <p v-if="!data.linked.length" class="text-n-slate-11">
        {{ text('NONE_LINKED') }}
      </p>
      <div
        v-for="item in data.linked"
        :key="`${item.kind}-${item.id}`"
        class="flex flex-col gap-1 rounded border border-n-weak p-2"
      >
        <a
          :href="item.admin_url"
          target="_blank"
          rel="noopener noreferrer"
          class="break-words text-n-blue-11"
        >
          {{ item.name || item.id }}
        </a>
        <span>{{
          text('STATUS_SUMMARY', { ...item, status: statusText(item.status) })
        }}</span>
        <span class="text-n-slate-11">{{
          text(item.source === 'operator' ? 'MANUAL' : 'AUTOMATIC')
        }}</span>
        <span v-if="item.draft_name">{{ item.draft_name }}</span>
        <span v-if="item.error" class="text-n-ruby-11">{{
          errorText(item.error)
        }}</span>
        <span v-if="item.paid" class="text-n-slate-11">{{
          text('PAID_LOCKED')
        }}</span>
        <Button
          v-else
          size="sm"
          variant="ghost"
          :disabled="busy"
          :label="text('UNLINK')"
          @click="removal = item"
        />
      </div>
      <Button
        size="sm"
        variant="outline"
        :disabled="busy"
        :label="text('REFRESH')"
        @click="refresh"
      />
      <Button
        size="sm"
        variant="ghost"
        :disabled="busy || loading"
        :label="text('RELOAD')"
        @click="load()"
      />
      <p v-if="data.draft_access === false" class="text-n-amber-11">
        {{ text('ERRORS.missing_draft_scope') }}
      </p>
      <template v-for="section in ['orders', 'drafts']" :key="section">
        <h4 class="text-sm font-medium">
          {{
            text(section === 'orders' ? 'CUSTOMER_ORDERS' : 'CUSTOMER_DRAFTS')
          }}
        </h4>
        <p v-if="!data[section].items.length" class="text-n-slate-11">
          {{ text('EMPTY_HISTORY') }}
        </p>
        <div
          v-for="item in data[section].items"
          :key="item.id"
          class="flex flex-col gap-1 rounded border border-n-weak p-2"
        >
          <a
            :href="item.admin_url"
            target="_blank"
            rel="noopener noreferrer"
            class="text-n-blue-11"
          >
            {{ item.name }}
          </a>
          <span>{{
            text('STATUS_SUMMARY', { ...item, status: statusText(item.status) })
          }}</span>
          <span v-if="item.created_at" class="text-n-slate-11">
            {{ formatDate(item.created_at) }}
          </span>
          <Button
            size="sm"
            variant="outline"
            :disabled="busy"
            :label="text('LINK')"
            @click="preview(item.admin_url)"
          />
        </div>
        <Button
          v-if="data[section].cursor"
          size="sm"
          variant="ghost"
          :disabled="loading"
          :label="text('MORE')"
          @click="load(section)"
        />
      </template>
    </template>
  </div>
</template>
