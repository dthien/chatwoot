# TODO : Delete this and associated spec once 'api/widget/config' end point is merged
class WidgetsController < ActionController::Base
  include WidgetHelper

  before_action :set_global_config
  before_action :set_web_widget
  before_action :ensure_account_is_active
  before_action :ensure_location_is_supported
  before_action :set_token
  before_action :set_contact
  before_action :build_contact
  after_action :allow_iframe_requests

  private

  def set_global_config
    @global_config = GlobalConfig.get(
      'LOGO_THUMBNAIL',
      'BRAND_NAME',
      'WIDGET_BRAND_URL',
      'DIRECT_UPLOADS_ENABLED',
      'MAXIMUM_FILE_UPLOAD_SIZE',
      'INSTALLATION_NAME'
    )
  end

  def set_web_widget
    @web_widget = ::Channel::WebWidget.find_by!(website_token: permitted_params[:website_token])
  rescue ActiveRecord::RecordNotFound
    Rails.logger.error('web widget does not exist')
    render json: { error: 'web widget does not exist' }, status: :not_found
  end

  def set_token
    @token = permitted_params[:cw_conversation]
    @auth_token_params = if @token.present?
                           ::Widget::TokenService.new(token: @token).decode_token
                         else
                           {}
                         end
  end

  def set_contact
    return if @auth_token_params[:source_id].nil?

    @contact_inbox = ::ContactInbox.find_by(
      inbox_id: @web_widget.inbox.id,
      source_id: @auth_token_params[:source_id]
    )

    @contact = @contact_inbox&.contact
  end

  def build_contact
    # PATCH [crm-cookie-rebind]: a persisted cw_conversation cookie is
    # resolved by set_contact into @contact from an OLD contact_inbox
    # row. The previous `return if @contact.present?` made every reload
    # of a returning student re-bind to that stale row, so the page
    # subscribed to the wrong pubsub token and live delivery was lost
    # (new messages appeared only after a refresh). When the contact is
    # identified via the CRM-signed cw_identity we therefore ALWAYS run
    # the conversation-row selection below and regenerate @token from the
    # correct row; the widget then rewrites the cw_conversation cookie
    # to that row on the next load (self-healing). This deployment has
    # one conversation per student, so the override is safe.
    # Non-identified (cookie-only) loads still respect @contact below.
    identified = identified_contact_from_cw_identity
    if identified
      # PATCH [crm-widget-identity]: resolve the EXISTING contact (from
      # the CRM-signed identity) instead of building a fresh anonymous
      # one, so the page-embedded JWT + pubsub token belong to the real
      # contact and the [crm-widget-unified-thread] patch shows all of
      # its conversations in the inbox on first paint. Reuse the
      # contact's existing contact_inbox row when it has one in this
      # inbox (no row proliferation on repeat page loads).
      # PATCH [crm-widget-conversation-row]: bind the page to the row
      # that owns the contact's most recently active conversation in
      # this inbox. Staff/CRM-initiated conversations create their own
      # contact_inbox row, so the first row in DB order is not
      # necessarily the conversation's row; conversation live events
      # are broadcast to the conversation row's pubsub token (plus
      # inbox agents), so a page bound to a different row gets no
      # live delivery (messages appear only on refresh). The builder
      # below reuses this row by source_id (find_by early return, no
      # new row). Falls back to the first row when the contact has no
      # conversation yet (first-time student: unchanged behavior).
      latest_conversation = identified.conversations
                              .where(inbox_id: @web_widget.inbox.id)
                              .order(last_activity_at: :desc, created_at: :desc, id: :desc)
                              .first
      existing_ci = latest_conversation&.contact_inbox ||
                   @web_widget.inbox.contact_inboxes.where(contact: identified).first
      @contact_inbox = ::ContactInboxWithContactBuilder.new(
        inbox: @web_widget.inbox,
        contact_attributes: { email: identified.email, name: identified.name, additional_attributes: additional_attributes },
        source_id: existing_ci&.source_id
      ).perform
      @token = ::Widget::TokenService.new(
        payload: { source_id: @contact_inbox.source_id, inbox_id: @web_widget.inbox.id }
      ).generate_token
      @contact = @contact_inbox.contact
    elsif @contact.present?
      # Cookie set the contact and there is no cw_identity: respect the
      # cookie (previous behavior for anonymous / cookie-only loads).
      return
    else
      @contact_inbox, @token = build_contact_inbox_with_token(@web_widget, additional_attributes)
      @contact = @contact_inbox.contact
    end
  end

  # PATCH [crm-widget-identity]
  # Validate the CRM-signed widget identity (cw_identity =
  # base64url(JSON{email,exp}).HMAC_SHA256_hex) and resolve the
  # existing contact by email. Any validation failure (missing secret,
  # bad signature, expired, malformed, lookup miss) returns nil and the
  # stock fresh-anonymous-contact behavior applies.
  def identified_contact_from_cw_identity
    require 'base64'
    require 'json'
    require 'openssl'
    # Raw param access: the controller's own permitted_params shadows
    # the helper one, so the permitted hash never carries cw_identity.
    raw = params[:cw_identity]
    return nil if raw.blank?

    secret = ENV['CHATWOOT_WIDGET_IDENTITY_SECRET'].presence
    return nil if secret.nil?

    b64, sig = raw.to_s.split('.', 2)
    return nil if b64.nil? || sig.nil? || sig.empty?

    expected = OpenSSL::HMAC.hexdigest('SHA256', secret, b64)
    return nil unless ActiveSupport::SecurityUtils.secure_compare(expected, sig)

    payload = JSON.parse(Base64.urlsafe_decode64(b64))
    return nil unless payload.is_a?(Hash)
    return nil if payload['exp'].to_i < Time.now.to_i
    return nil if payload['email'].blank?

    @web_widget.account.contacts.from_email(payload['email'])
  rescue StandardError
    nil
  end

  def ensure_account_is_active
    render json: { error: 'Account is suspended' }, status: :unauthorized unless @web_widget.inbox.account.active?
  end

  def ensure_location_is_supported; end

  def additional_attributes
    if @web_widget.inbox.account.feature_enabled?('ip_lookup')
      { created_at_ip: request.remote_ip }
    else
      {}
    end
  end

  def permitted_params
    params.permit(:website_token, :cw_conversation)
  end

  def allow_iframe_requests
    if @web_widget.allowed_domains.blank? || embedded_from_non_web_origin?
      response.headers.delete('X-Frame-Options')
    else
      domains = @web_widget.allowed_domains.split(',').map(&:strip).join(' ')
      response.headers['Content-Security-Policy'] = "frame-ancestors #{domains}"
    end
  end

  # Mobile WebViews (iOS/Android) load content from file:// or null origins,
  # which cannot match any domain in frame-ancestors. When the per-inbox flag
  # is enabled, skip frame-ancestors for these requests.
  def embedded_from_non_web_origin?
    return false unless @web_widget.allow_mobile_webview?

    origin = request.headers['Origin']
    origin.blank? || origin == 'null' || origin&.start_with?('file://')
  end
end

WidgetsController.prepend_mod_with('WidgetsController')
