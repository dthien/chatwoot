class Api::V1::Widget::BaseController < ApplicationController
  include SwitchLocale
  include WebsiteTokenHelper

  before_action :set_web_widget
  before_action :set_contact

  private

  def conversations
    # PATCH [crm-widget-unified-thread] rev 2
    # Both branches list ALL of the contact's conversations in this inbox.
    # The stock HMAC branch only listed conversations linked to the
    # session's own hmac-verified contact_inbox rows, which hid
    # staff/CRM-initiated conversations (their contact_inbox rows are
    # not hmac-verified). The CRM widget always authenticates via
    # set_user (hmac_verified=true), so students saw 'create a new
    # conversation' instead of the existing thread.
    @conversations = @contact.conversations.where(inbox_id: auth_token_params[:inbox_id])
  end

  def conversation
    @conversation ||= conversations.last
  end

  def create_conversation
    ::Conversation.create!(conversation_params)
  end

  def inbox
    @inbox ||= ::Inbox.find_by(id: auth_token_params[:inbox_id])
  end

  def conversation_params
    {
      account_id: inbox.account_id,
      inbox_id: inbox.id,
      contact_id: @contact.id,
      contact_inbox_id: @contact_inbox.id,
      additional_attributes: {
        browser_language: browser.accept_language&.first&.code,
        browser: browser_params,
        initiated_at: timestamp_params,
        referer: permitted_params[:message][:referer_url]
      },
      custom_attributes: permitted_params[:custom_attributes].presence || {}
    }
  end

  def contact_email
    permitted_params.dig(:contact, :email)&.downcase
  end

  def contact_name
    return if @contact.email.present? || @contact.phone_number.present? || @contact.identifier.present?

    permitted_params.dig(:contact, :name) || (contact_email.split('@')[0] if contact_email.present?)
  end

  def contact_phone_number
    permitted_params.dig(:contact, :phone_number)
  end

  def contact_custom_attributes
    permitted_params.dig(:contact, :custom_attributes)&.to_h
  end

  def browser_params
    {
      browser_name: browser.name,
      browser_version: browser.full_version,
      device_name: browser.device.name,
      platform_name: browser.platform.name,
      platform_version: browser.platform.version
    }
  end

  def timestamp_params
    { timestamp: permitted_params[:message][:timestamp] }
  end

  def message_params
    {
      account_id: conversation.account_id,
      sender: @contact,
      content: permitted_params[:message][:content],
      inbox_id: conversation.inbox_id,
      content_attributes: {
        in_reply_to: permitted_params[:message][:reply_to]
      },
      echo_id: permitted_params[:message][:echo_id],
      message_type: :incoming
    }
  end
end
