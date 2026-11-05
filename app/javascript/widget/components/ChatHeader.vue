<script setup>
import { toRef } from 'vue';
import { useRouter } from 'vue-router';
import UmiIcon from './UmiIcon.vue';
import HeaderActions from './HeaderActions.vue';
import AvailabilityContainer from 'widget/components/Availability/AvailabilityContainer.vue';
import { useAvailability } from 'widget/composables/useAvailability';

const props = defineProps({
  avatarUrl: { type: String, default: '' },
  title: { type: String, default: '' },
  showPopoutButton: { type: Boolean, default: false },
  showBackButton: { type: Boolean, default: false },
  showStatus: { type: Boolean, default: false },
  availableAgents: { type: Array, default: () => [] },
});

const availableAgents = toRef(props, 'availableAgents');

const router = useRouter();
const { isOnline } = useAvailability(availableAgents);

const onBackButtonClick = () => {
  router.replace({ name: 'home' });
};
</script>

<template>
  <!-- UMI: the storefront drawer header — theme inset, 16/24 Regular title, the theme's
       back arrow and close cross (see UMI-ASSISTANCE-DRAWER-CHROME-SPEC.md). The row aligns to
       its top, so the 44 px buttons centre on the title's line (the status line sits under it,
       outside that axis), as the theme centres its cross on a one-line drawer title. -->
  <header
    class="umi-header flex justify-between items-start w-full bg-n-background gap-2"
  >
    <div class="flex items-start min-w-0">
      <button
        v-if="showBackButton"
        class="umi-header-button umi-header-button--start"
        :aria-label="$t('UMI.BACK')"
        @click="onBackButtonClick"
      >
        <UmiIcon name="back" class="umi-header-icon rtl:rotate-180" />
      </button>
      <img
        v-if="avatarUrl"
        class="w-8 h-8 -my-1 ltr:mr-3 rtl:ml-3 rounded-full"
        :src="avatarUrl"
        alt="avatar"
      />
      <div class="flex flex-col min-w-0">
        <div class="umi-header-title flex items-center">
          <span v-dompurify-html="title" class="truncate" />
          <span v-if="isOnline" class="umi-online-dot bg-n-teal-10">
            <span class="sr-only">{{ $t('UMI.ONLINE') }}</span>
          </span>
        </div>
        <AvailabilityContainer
          v-if="showStatus"
          :agents="availableAgents"
          :show-header="false"
          :show-avatars="false"
          text-classes="umi-header-status"
        />
      </div>
    </div>
    <HeaderActions
      :show-popout-button="showPopoutButton"
      :show-end-conversation-button="false"
    />
  </header>
</template>
