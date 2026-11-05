<script>
import Spinner from 'shared/components/Spinner.vue';
import UmiIcon from 'widget/components/UmiIcon.vue';

export default {
  components: {
    UmiIcon,
    Spinner,
  },
  props: {
    loading: {
      type: Boolean,
      default: false,
    },
    disabled: {
      type: Boolean,
      default: false,
    },
  },
};
</script>

<template>
  <button
    type="submit"
    :disabled="disabled"
    class="umi-composer-send"
    :aria-label="$t('UMI.SEND')"
  >
    <UmiIcon v-if="!loading" name="arrow" class="w-[15px] rtl:rotate-180" />
    <Spinner v-else size="small" />
  </button>
</template>
