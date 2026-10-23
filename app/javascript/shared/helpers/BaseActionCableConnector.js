import { createConsumer } from '@rails/actioncable';

const PRESENCE_INTERVAL = 20000;
const RECONNECT_INTERVAL = 1000;

class BaseActionCableConnector {
  static isDisconnected = false;

  constructor(
    app,
    pubsubToken,
    websocketHost = '',
    presenceInterval = PRESENCE_INTERVAL
  ) {
    const websocketURL = websocketHost ? `${websocketHost}/cable` : undefined;

    this.consumer = createConsumer(websocketURL);
    this.pubsubToken = pubsubToken;
    this.app = app;
    this.subscription = this.createSubscription(pubsubToken);
    this.events = {};
    this.reconnectTimer = null;
    this.isAValidEvent = () => true;
    this.triggerPresenceInterval = () => {
      setTimeout(() => {
        this.subscription.updatePresence();
        this.triggerPresenceInterval();
      }, presenceInterval);
    };
    this.triggerPresenceInterval();
  }

  createSubscription(pubsubToken) {
    return this.consumer.subscriptions.create(
      {
        channel: 'RoomChannel',
        pubsub_token: pubsubToken,
        account_id: this.app.$store.getters.getCurrentAccountId,
        user_id: this.app.$store.getters.getCurrentUserID,
      },
      {
        updatePresence() {
          this.perform('update_presence');
        },
        received: this.onReceived,
        disconnected: () => {
          BaseActionCableConnector.isDisconnected = true;
          this.onDisconnected();
          this.initReconnectTimer();
        },
      }
    );
  }

  // PATCH [crm-widget-live-resubscribe]: after a contact identify
  // (set_user) the widget session can be bound to a different
  // contact_inbox row than the one the page-load token referred to.
  // Live conversation events are broadcast to the conversation's row
  // pubsub token, so the RoomChannel subscription must follow the new
  // row; otherwise live delivery is lost until a manual refresh.
  // No-op for a blank or unchanged token.
  resubscribe(pubsubToken) {
    if (!pubsubToken || pubsubToken === this.pubsubToken) {
      return;
    }
    this.pubsubToken = pubsubToken;
    if (this.subscription) {
      this.consumer.subscriptions.remove(this.subscription);
    }
    this.subscription = this.createSubscription(pubsubToken);
  }

  checkConnection() {
    const isConnectionActive = this.consumer.connection.isOpen();
    const isReconnected =
      BaseActionCableConnector.isDisconnected && isConnectionActive;
    if (isReconnected) {
      this.clearReconnectTimer();
      this.onReconnect();
      BaseActionCableConnector.isDisconnected = false;
    } else {
      this.initReconnectTimer();
    }
  }

  clearReconnectTimer = () => {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
  };

  initReconnectTimer = () => {
    this.clearReconnectTimer();
    this.reconnectTimer = setTimeout(() => {
      this.checkConnection();
    }, RECONNECT_INTERVAL);
  };

  // eslint-disable-next-line class-methods-use-this
  onReconnect = () => {};

  // eslint-disable-next-line class-methods-use-this
  onDisconnected = () => {};

  disconnect() {
    this.consumer.disconnect();
  }

  onReceived = ({ event, data } = {}) => {
    if (this.isAValidEvent(data)) {
      if (this.events[event] && typeof this.events[event] === 'function') {
        this.events[event](data);
      }
    }
  };
}

export default BaseActionCableConnector;
