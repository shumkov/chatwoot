# frozen_string_literal: true

# Asks Meta for the public Instagram profile behind a handle, through the
# business account's own Instagram user.
#
# This is the only route to the customers the messaging profile API refuses
# with error 230 (no consent to read their profile). Business Discovery does
# not consult that consent wall at all: it answers for any Business or Creator
# account, and returns the follower count, real name, picture, website and bio
# that the refused profile call could not. Personal accounts stay invisible —
# Meta answers error 110 for them, and no permission changes that.
#
# Needs no permission the page token does not already hold.
class Umi::Fbig::BusinessDiscoveryService
  FIELDS = %w[id username name profile_picture_url followers_count website biography].freeze
  # Instagram's own handle rule. Enforced before interpolation, not for
  # tidiness: the handle lands inside a Graph field expression, and it can
  # reach us from a contact name an agent typed.
  HANDLE = /\A[A-Za-z0-9._]{1,30}\z/
  # The same rule for Postgres, which does not understand \A and \z.
  HANDLE_SQL = '^[A-Za-z0-9._]{1,30}$'
  # Meta's "cannot find user" — the account is personal, renamed or gone.
  NOT_FOUND_CODE = 110
  API_VERSION = 'v25.0'

  Result = Struct.new(:profile, :status, keyword_init: true) do
    def found?
      status == :found
    end

    # Answered definitively about this handle: either a profile, or Meta
    # saying no such discoverable account. Both are worth remembering, so we
    # stop paying for the same answer every night.
    def conclusive?
      found? || status == :not_discoverable
    end
  end

  def initialize(channel)
    @channel = channel
  end

  def lookup(handle)
    handle = normalize(handle)
    return Result.new(status: :invalid_handle) if handle.nil?
    return Result.new(status: :unconfigured) if instagram_user_id.blank?

    profile = request(handle)
    profile.present? ? Result.new(profile: profile, status: :found) : Result.new(status: :empty)
  rescue Koala::Facebook::AuthenticationError
    # A 401 is not about this handle. Let the caller stand the run down.
    raise
  rescue Koala::Facebook::ClientError => e
    return Result.new(status: :not_discoverable) if e.fb_error_code.to_i == NOT_FOUND_CODE

    Umi::FbigTrace.log(:business_discovery_failed, handle: handle, code: e.fb_error_code)
    Result.new(status: :failed)
  rescue StandardError => e
    Umi::FbigTrace.log(:business_discovery_failed, handle: handle, reason: e.class.name)
    Result.new(status: :failed)
  end

  private

  def normalize(handle)
    handle = handle.to_s.strip.delete_prefix('@')
    handle.match?(HANDLE) ? handle : nil
  end

  def instagram_user_id
    @instagram_user_id ||= @channel.try(:instagram_id)
  end

  # Both hashes are built per call. Koala mutates the options hash it is given,
  # so a shared or frozen constant raises FrozenError on first use. api_version
  # must be a symbol key — a string key is silently ignored and the call falls
  # back to a default nothing sets.
  def request(handle)
    response = api.get_object(
      instagram_user_id,
      { fields: "business_discovery.username(#{handle}){#{FIELDS.join(',')}}" },
      { api_version: API_VERSION }
    )
    response&.dig('business_discovery')
  end

  def api
    @api ||= Koala::Facebook::API.new(@channel.page_access_token)
  end
end
