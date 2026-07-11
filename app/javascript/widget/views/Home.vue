<script>
// UMI home layout: welcome → articles → messenger links → composer.
// The "We are online / Start conversation" availability card is dropped — the
// header already shows availability, and the composer is the single input.
// See docs/UMI-WIDGET-HOME-SPEC.md.
import ArticleContainer from '../components/pageComponents/Home/Article/ArticleContainer.vue';
import UmiHomeWelcome from '../components/pageComponents/Home/UmiHomeWelcome.vue';
import UmiInboxLinks from '../components/pageComponents/Home/UmiInboxLinks.vue';
import UmiHomeComposer from '../components/pageComponents/Home/UmiHomeComposer.vue';

export default {
  name: 'Home',
  components: {
    ArticleContainer,
    UmiHomeWelcome,
    UmiInboxLinks,
    UmiHomeComposer,
  },
};
</script>

<template>
  <div class="z-50 flex flex-col justify-end flex-1 w-full gap-4 p-4">
    <UmiHomeWelcome />
    <ArticleContainer />
    <UmiInboxLinks />
    <UmiHomeComposer />
  </div>
</template>
