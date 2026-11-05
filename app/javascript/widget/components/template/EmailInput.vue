<script>
import { useVuelidate } from '@vuelidate/core';
import { required, email } from '@vuelidate/validators';

import UmiIcon from 'widget/components/UmiIcon.vue';
import Spinner from 'shared/components/Spinner.vue';

export default {
  components: {
    UmiIcon,
    Spinner,
  },
  props: {
    messageId: {
      type: Number,
      required: true,
    },
    messageContentAttributes: {
      type: Object,
      default: () => {},
    },
  },
  setup() {
    return { v$: useVuelidate() };
  },
  data() {
    return {
      email: '',
      isUpdating: false,
    };
  },
  computed: {
    hasSubmitted() {
      return (
        this.messageContentAttributes &&
        this.messageContentAttributes.submitted_email
      );
    },
  },
  validations: {
    email: {
      required,
      email,
    },
  },
  methods: {
    async onSubmit() {
      if (this.v$.$invalid) {
        return;
      }
      this.isUpdating = true;
      try {
        await this.$store.dispatch('message/update', {
          email: this.email,
          messageId: this.messageId,
        });
      } catch (error) {
        // Ignore error
      } finally {
        this.isUpdating = false;
      }
    },
  },
};
</script>

<template>
  <div>
    <form
      v-if="!hasSubmitted"
      class="email-input-group umi-composer my-2 mx-0 min-w-[200px]"
      @submit.prevent="onSubmit"
    >
      <input
        v-model="email"
        type="email"
        :placeholder="$t('EMAIL_PLACEHOLDER')"
        class="umi-composer-input"
        :class="{ error: v$.email.$error }"
        :aria-label="$t('EMAIL_PLACEHOLDER')"
        :aria-invalid="v$.email.$error"
        autocomplete="email"
        @input="v$.email.$touch"
        @keydown.enter="onSubmit"
      />
      <button
        class="umi-composer-send"
        :disabled="v$.email.$invalid"
        :aria-label="$t('UMI.SEND')"
      >
        <UmiIcon
          v-if="!isUpdating"
          name="arrow"
          class="w-[15px] rtl:rotate-180"
        />
        <Spinner v-else class="mx-2" />
      </button>
    </form>
  </div>
</template>
