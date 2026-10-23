import { describe, it, beforeEach, afterEach, expect, vi } from 'vitest';
import ActionCableConnector from '../actionCable';

const mocks = vi.hoisted(() => ({
  create: vi.fn(() => ({})),
  remove: vi.fn(),
}));
vi.mock('@rails/actioncable', () => ({
  createConsumer: () => ({
    subscriptions: { create: mocks.create, remove: mocks.remove },
    disconnect: vi.fn(),
  }),
}));

describe('Widget ActionCableConnector', () => {
  let app;
  let mockDispatch;
  let connector;

  beforeEach(() => {
    vi.useFakeTimers();
    mockDispatch = vi.fn();
    app = {
      $store: {
        dispatch: mockDispatch,
        getters: {
          getCurrentAccountId: 1,
          getCurrentUserID: 1,
        },
      },
    };
    connector = new ActionCableConnector(app, 'test-token');
    mockDispatch.mockClear();
    mocks.create.mockClear();
    mocks.remove.mockClear();
  });

  afterEach(() => {
    vi.clearAllMocks();
    vi.useRealTimers();
  });

  it('registers the conversation.status_changed event handler', () => {
    expect(connector.events['conversation.status_changed']).toBe(
      connector.onStatusChange
    );
  });

  it('re-fetches conversation attributes on reconnect so a status change missed while disconnected is reflected', () => {
    connector.onReconnect();

    expect(mockDispatch).toHaveBeenCalledWith(
      'conversation/syncLatestMessages'
    );
    expect(mockDispatch).toHaveBeenCalledWith(
      'conversationAttributes/getAttributes'
    );
  });

  it('resubscribe: switches the RoomChannel subscription to the new pubsub token', () => {
    const previous = connector.subscription;

    connector.resubscribe('new-token');

    expect(mocks.remove).toHaveBeenCalledWith(previous);
    expect(connector.pubsubToken).toBe('new-token');
    expect(connector.subscription).not.toBe(previous);
  });

  it('resubscribe: is a no-op for an unchanged or blank token', () => {
    const current = connector.subscription;

    connector.resubscribe('test-token');
    connector.resubscribe(null);

    expect(mocks.remove).not.toHaveBeenCalled();
    expect(connector.pubsubToken).toBe('test-token');
    expect(connector.subscription).toBe(current);
  });

  describe('refreshConnector (live widget connector)', () => {
    it('resubscribes the live widget connector to the new token', () => {
      ActionCableConnector.refreshConnector('other-token');

      expect(connector.pubsubToken).toBe('other-token');
    });

    it('is a no-op without a live connector', () => {
      const saved = ActionCableConnector.current;
      ActionCableConnector.current = null;

      expect(() => ActionCableConnector.refreshConnector('x')).not.toThrow();
      expect(mocks.remove).not.toHaveBeenCalled();
      ActionCableConnector.current = saved;
    });
  });
});
