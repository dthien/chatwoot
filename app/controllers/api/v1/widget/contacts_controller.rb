class Api::V1::Widget::ContactsController < Api::V1::Widget::BaseController
  include WidgetHelper

  before_action :validate_hmac, only: [:set_user]
  before_action :validate_hmac_for_identified_update, only: [:update]

  def show; end

  def update
    identify_contact(@contact)
  end

  def set_user
    contact = nil

    if a_different_contact?
      @contact_inbox, @widget_auth_token = build_contact_inbox_with_token(@web_widget)
      contact = @contact_inbox.contact
    else
      contact = @contact
    end

    # PATCH [crm-widget-verified-session]: the widget is only reachable
    # for authenticated CRM students (the widget renders exclusively
    # inside the CRM for logged-in students), so the CRM login IS the
    # identity verification. The stock hmac_verified path can never
    # fire here: the identifier_hash is an HMAC of the identifier with
    # the website's hmac_token, which exists only on the Chatwoot
    # server and is never exposed to the client. Mark the bound row
    # verified unconditionally. Stock behavior when a hash IS provided
    # is untouched (validate_hmac still rejects an invalid hash).
    @contact_inbox.update(hmac_verified: true) # PATCH [crm-widget-verified-session]

    identify_contact(contact)

    # PATCH [crm-widget-live-resubscribe]: identify_contact can rebind
    # the session contact (the different-identifier branch builds a
    # fresh contact; an in-place identify merges it into an existing
    # identifier/email contact, reassigning this contact_inbox row to
    # the surviving contact). Live conversation events are broadcast to
    # the CONVERSATION's contact_inbox row pubsub token (see
    # [crm-widget-conversation-row] in WidgetsController#build_contact),
    # so the row the API session is bound to must follow the final
    # contact — otherwise the widget keeps its page-load pubsub token
    # and live delivery is lost until a manual refresh (new messages
    # appear only after a reload). Re-resolve the row that owns the
    # contact's most recently active conversation in this inbox (first
    # row when the contact has none yet, current row when the contact
    # has no row in this inbox), and re-mint the widget auth token
    # from it so the next page load self-heals to the same row (the
    # [crm-cookie-rebind] behavior). The fresh pubsub_token is
    # rendered in set_user.json.jbuilder so the client can
    # resubscribe its RoomChannel live stream (see the matching
    # resubscribe/refreshConnector client patch).
    resolve_live_row_after_identify
  end

  # TODO : clean up this with proper routes delete contacts/custom_attributes
  def destroy_custom_attributes
    @contact.custom_attributes = @contact.custom_attributes.excluding(params[:custom_attributes])
    @contact.save!
    render json: @contact
  end

  private

  def identify_contact(contact)
    contact_identify_action = ContactIdentifyAction.new(
      contact: contact,
      params: permitted_params.to_h.deep_symbolize_keys,
      discard_invalid_attrs: true
    )
    @contact = contact_identify_action.perform
  end

  # PATCH [crm-widget-live-resubscribe]: see set_user. Mirrors the row
  # selection of [crm-widget-conversation-row] in
  # WidgetsController#build_contact (the page-load path) so the API
  # session and the page embed stay bound to the same contact_inbox
  # row — the row whose pubsub token receives live events for the
  # contact's conversations in this inbox.
  def resolve_live_row_after_identify
    return if @contact.blank?

    latest_conversation = @contact.conversations
                               .where(inbox_id: @web_widget.inbox.id)
                               .order(last_activity_at: :desc, created_at: :desc, id: :desc)
                               .first
    row = latest_conversation&.contact_inbox ||
          @web_widget.inbox.contact_inboxes.where(contact: @contact).first ||
          @contact_inbox
    @contact_inbox = row
    # The set_user action marked the PRE-identify row hmac_verified
    # (line: `@contact_inbox.update(hmac_verified: true) if
    # should_verify_hmac?`), which made the API session a verified
    # session: the live fanout covered all of the contact's verified
    # rows and the widget conversation list used
    # `contact.conversations`. Without marking the row the session is
    # now bound to, a multi-row contact's widget list narrows to the
    # bound row's conversations (`contact_inbox.conversations`). Mark
    # it the same way (idempotent when row is the already-marked
    # original row; a verified pre-identify session keeps its
    # pre-patch semantics).
    # PATCH [crm-widget-verified-session]: unconditional (see set_user).
    @contact_inbox.update(hmac_verified: true)
    @widget_auth_token = ::Widget::TokenService.new(
      payload: { source_id: row.source_id, inbox_id: @web_widget.inbox.id }
    ).generate_token
  end

  def a_different_contact?
    @contact.identifier.present? && @contact.identifier != permitted_params[:identifier]
  end

  # The plain update endpoint is also used for anonymous prechat updates
  # (name/email/phone/custom_attributes with no identifier), which must keep
  # working on hmac_mandatory inboxes. Only the identity-binding path, where an
  # identifier is supplied and the contact can be rebound, requires HMAC.
  def validate_hmac_for_identified_update
    return if params[:identifier].blank?

    validate_hmac
  end

  def validate_hmac
    return unless should_verify_hmac?

    render json: { error: 'HMAC failed: Invalid Identifier Hash Provided' }, status: :unauthorized unless valid_hmac?
  end

  def should_verify_hmac?
    return false if params[:identifier_hash].blank? && !@web_widget.hmac_mandatory

    # Taking an extra caution that the hmac is triggered whenever identifier is present
    return false if params[:custom_attributes].present? && params[:identifier].blank?

    true
  end

  def valid_hmac?
    expected_hash = OpenSSL::HMAC.hexdigest(
      'sha256',
      @web_widget.hmac_token,
      params[:identifier].to_s
    )
    identifier_hash = params[:identifier_hash].to_s
    return false unless identifier_hash.bytesize == expected_hash.bytesize

    ActiveSupport::SecurityUtils.secure_compare(identifier_hash, expected_hash)
  end

  def permitted_params
    params.permit(:website_token, :identifier, :identifier_hash, :email, :name, :avatar_url, :phone_number, custom_attributes: {},
                                                                                                            additional_attributes: {})
  end
end
