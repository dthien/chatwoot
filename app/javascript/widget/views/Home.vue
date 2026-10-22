<script>
import TeamAvailability from 'widget/components/TeamAvailability.vue';
import { mapGetters } from 'vuex';
import { useRouter } from 'vue-router';
import configMixin from 'widget/mixins/configMixin';
import ArticleContainer from '../components/pageComponents/Home/Article/ArticleContainer.vue';
export default {
  name: 'Home',
  components: {
    ArticleContainer,
    TeamAvailability,
  },
  mixins: [configMixin],
  data() {
    // PATCH [crm-auto-open]: one-shot guard so the auto navigation below
    // runs at most once (prevents a re-navigation loop if the student
    // goes back to the home screen).
    return { autoOpened: false };
  },
  setup() {
    const router = useRouter();
    return { router };
  },
  computed: {
    ...mapGetters({
      availableAgents: 'agent/availableAgents',
      conversationSize: 'conversation/getConversationSize',
      unreadMessageCount: 'conversation/getUnreadMessageCount',
    }),
  },
  mounted() {
    // PATCH [crm-auto-open]: skip the "We are online" landing screen.
    // Navigate as soon as a conversation exists (or appears when the
    // conversation list loads after the student is identified via
    // set_user); otherwise, after a short 2s delay (long enough for the
    // initial list fetch + the set_user merge window), navigate to the
    // pre-chat form (or messages page when pre-chat is disabled).
    this.maybeAutoOpen();
    this.$watch('conversationSize', () => this.maybeAutoOpen());
    setTimeout(() => this.maybeAutoOpenNoConversation(), 2000);
  },
  methods: {
    startConversation() {
      if (this.preChatFormEnabled && !this.conversationSize) {
        return this.router.replace({ name: 'prechat-form' });
      }
      return this.router.replace({ name: 'messages' });
    },
    // PATCH [crm-auto-open]
    maybeAutoOpen() {
      if (this.autoOpened) {
        return;
      }
      if (this.conversationSize) {
        this.autoOpened = true;
        this.startConversation();
      }
    },
    // PATCH [crm-auto-open]
    maybeAutoOpenNoConversation() {
      if (this.autoOpened) {
        return;
      }
      if (!this.conversationSize) {
        this.autoOpened = true;
        this.startConversation();
      }
    },
  },
};
</script>

<template>
  <div class="z-50 flex flex-col justify-end flex-1 w-full p-4 gap-4">
    <TeamAvailability
      :available-agents="availableAgents"
      :has-conversation="!!conversationSize"
      :unread-count="unreadMessageCount"
      @start-conversation="startConversation"
    />

    <ArticleContainer />
  </div>
</template>
