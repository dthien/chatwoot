json.id @conversation.display_id
json.inbox_id @conversation.inbox_id
json.contact_last_seen_at @conversation.contact_last_seen_at.to_i
json.status @conversation.status
json.messages do
  # PATCH [crm-single-thread]
  # Newest first so messages[0] is the just-sent message: the widget JS
  # reads messages[0] as the optimistic-UI message, which matters when the
  # create endpoint delivers into a reused conversation.
  json.array! @conversation.messages.reorder(created_at: :desc, id: :desc) do |message|
    json.partial! 'api/v1/models/widget_message', resource: message
  end
end
json.custom_attributes @conversation.custom_attributes
json.contact @conversation.contact
