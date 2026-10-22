class Api::V1::Accounts::AgentsController < Api::V1::Accounts::BaseController
  before_action :fetch_agent, except: [:create, :index, :bulk_create]
  before_action :check_authorization, except: [:create, :index, :bulk_create, :login_link] # PATCH [crm-agent-login-link]
  before_action :check_agent_admin, only: [:login_link]

  def index
    @agents = agents
  end

  def create
    builder = AgentBuilder.new(
      email: new_agent_params['email'],
      name: new_agent_params['name'],
      role: new_agent_params['role'],
      availability: new_agent_params['availability'],
      auto_offline: new_agent_params['auto_offline'],
      inviter: current_user,
      account: Current.account
    )

    @agent = builder.perform
  rescue AgentBuilder::LimitExceededError => e
    render_payment_required(e.message)
  end

  def update
    @agent.update!(agent_params.slice(:name).compact)
    @agent.current_account_user.update!(agent_params.slice(*account_user_attributes).compact)
  end

  def destroy
    @agent.current_account_user.destroy!
    delete_user_record(@agent)
    head :ok
  end

  # PATCH [crm-agent-login-link]
  # Single-use SSO sign-in link ("magic link") for this agent.
  # The stock AgentBuilder creates API agents unconfirmed with a
  # temporary password, so stock web sign-in is impossible until the
  # agent confirms via the stock confirmation email. This endpoint
  # (admin API tokens only) confirms the agent and mints a token the
  # stock login page accepts: open
  #   /app/login?email=<agent email>&sso_auth_token=<token>
  # and the stock frontend auto-signs-in (SsoAuthenticatable flow).
  # The token is single-use (invalidated after the first sign-in) and
  # expires after ttl_seconds (default 300, clamped to 300..86400).
  # It returns the token only; the caller composes the URL (no
  # FRONTEND_URL dependency here).
  def login_link
    # update_columns: no callbacks, no email, no validation side effects
    @agent.update_columns(confirmed_at: Time.now.utc) unless @agent.confirmed?
    ttl = params[:ttl_seconds].to_i.clamp(300, 86_400)
    token = SecureRandom.hex(32)
    ::Redis::Alfred.setex(
      format(::Redis::RedisKeys::USER_SSO_AUTH_TOKEN, user_id: @agent.id, token: token),
      'normal',
      ttl
    )
    render json: { sso_auth_token: token, expires_in: ttl, email: @agent.email }
  end

  def bulk_create
    emails = params[:emails]

    bulk_create_agents(emails)
    # This endpoint is used to bulk create agents during onboarding
    # onboarding_step key in present in Current account custom attributes, since this is a one time operation
    clear_onboarding_step
    head :ok
  rescue AgentBuilder::LimitExceededError => e
    render_payment_required(e.message)
  end

  private

  def check_authorization
    super(User)
  end

  def fetch_agent
    @agent = agents.find(params[:id])
  end

  # PATCH [crm-agent-login-link]
  def check_agent_admin
    raise Pundit::NotAuthorizedError unless Current.account_user.administrator?
  end

  def account_user_attributes
    [:role, :availability, :auto_offline]
  end

  def allowed_agent_params
    [:name, :email, :role, :availability, :auto_offline]
  end

  def agent_params
    params.require(:agent).permit(allowed_agent_params)
  end

  def new_agent_params
    params.require(:agent).permit(:email, :name, :role, :availability, :auto_offline)
  end

  def agents
    @agents ||= Current.account.users.order_by_full_name.includes(:account_users, { avatar_attachment: [:blob] })
  end

  def bulk_create_agents(emails)
    email_limit_error = nil

    Current.account.with_lock do
      raise AgentBuilder::LimitExceededError if emails.count > available_agent_count

      emails.each do |email|
        create_agent_from_email(email)
      rescue CustomExceptions::Account::EmailLimitExceeded => e
        email_limit_error = e
      end
    end

    raise email_limit_error if email_limit_error
  end

  def create_agent_from_email(email)
    builder = AgentBuilder.new(
      email: email,
      name: email.split('@').first,
      inviter: current_user,
      account: Current.account
    )
    builder.perform
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.info "[Agent#bulk_create] ignoring email #{email}, errors: #{e.record.errors}"
  end

  def clear_onboarding_step
    Current.account.custom_attributes.delete('onboarding_step')
    Current.account.save!
  end

  def available_agent_count
    Current.account.usage_limits[:agents] - Current.account.account_users.count
  end

  def delete_user_record(agent)
    DeleteObjectJob.perform_later(agent) if agent.reload.account_users.blank?
  end
end

Api::V1::Accounts::AgentsController.prepend_mod_with('Api::V1::Accounts::AgentsController')
