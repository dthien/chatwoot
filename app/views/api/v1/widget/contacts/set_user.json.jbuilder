json.id @contact.id
json.has_email @contact.email.present?
json.has_name @contact.name.present?
json.has_phone_number @contact.phone_number.present?
json.widget_auth_token @widget_auth_token if @widget_auth_token.present?
# PATCH [crm-widget-live-resubscribe]: the pubsub token of the row
# the session is bound to after identify (the conversation row when
# the contact has a conversation, see
# ContactsController#resolve_live_row_after_identify). The client
# resubscribes its RoomChannel stream with it, restoring live
# delivery without a manual refresh.
json.pubsub_token @contact_inbox&.pubsub_token
