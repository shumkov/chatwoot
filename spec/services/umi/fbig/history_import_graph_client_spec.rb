require 'rails_helper'

describe Umi::Fbig::HistoryImportGraphClient do
  let(:channel) { instance_double(Channel::FacebookPage, page_id: 'page-1', page_access_token: 'token') }
  let(:api) { double }
  let(:sleeper) { class_double(Kernel, sleep: nil) }
  let(:random) { class_double(Random, rand: 0.5) }
  let(:client) do
    described_class.new(channel, delay_ms: 0, max_conversation_pages: 2, max_message_pages: 2,
                                 sleeper: sleeper, random: random)
  end
  let(:page_class) do
    Class.new(Array) do
      attr_accessor :paging, :next_page_result

      def next_page
        next_page_result
      end
    end
  end

  before do
    allow(Koala::Facebook::API).to receive(:new).and_return(api)
  end

  def page(items, next_url: nil)
    page_class.new(items).tap do |result|
      result.paging = next_url ? { 'next' => next_url } : {}
    end
  end

  it 'exhausts conversation pages with participants in the field set' do
    first = page([{ 'id' => 'thread-1' }], next_url: 'https://graph.facebook.com/next?after=secret')
    second = page([{ 'id' => 'thread-2' }])
    first.next_page_result = second
    allow(api).to receive(:get_connections)
      .with('page-1', 'conversations',
            { platform: 'messenger', fields: 'id,updated_time,participants', limit: 50 })
      .and_return(first)

    yielded = []
    pages = client.each_thread('messenger') { |thread| yielded << thread['id'] }

    expect(yielded).to eq(%w[thread-1 thread-2])
    expect(pages).to eq(2)
  end

  it 'returns every message and the number of pages read' do
    first = page([{ 'id' => 'mid-1' }], next_url: 'https://graph.facebook.com/next?after=one')
    second = page([{ 'id' => 'mid-2' }])
    first.next_page_result = second
    allow(api).to receive(:get_connections)
      .with('thread-1', 'messages', { fields: 'id,created_time,from', limit: 50 })
      .and_return(first)

    result = client.messages('thread-1')

    expect(result.items.pluck('id')).to eq(%w[mid-1 mid-2])
    expect(result.pages).to eq(2)
  end

  it 'fails loudly without exposing a repeated cursor' do
    first = page([], next_url: 'https://graph.facebook.com/next?after=secret')
    second = page([], next_url: 'https://graph.facebook.com/next?after=secret')
    first.next_page_result = second
    allow(api).to receive(:get_connections).and_return(first)

    expect { client.messages('thread-1') }.to raise_error(described_class::PaginationError) do |error|
      expect(error.message).to include('repeated message cursor')
      expect(error.message).not_to include('secret')
    end
  end

  it 'fails loudly when unread pages exceed the ceiling' do
    first = page([], next_url: 'https://graph.facebook.com/next?after=one')
    second = page([], next_url: 'https://graph.facebook.com/next?after=two')
    first.next_page_result = second
    allow(api).to receive(:get_connections).and_return(first)

    expect { client.messages('thread-1') }
      .to raise_error(described_class::PaginationError, /message page ceiling reached/)
  end

  it 'retries server failures with bounded backoff' do
    attempts = 0
    allow(api).to receive(:get_object) do
      attempts += 1
      raise Koala::Facebook::ServerError.new(500, '') if attempts < 3

      { 'id' => 'mid-1' }
    end

    expect(client.detail('mid-1')).to eq('id' => 'mid-1')
    expect(api).to have_received(:get_object).exactly(3).times
    expect(random).to have_received(:rand).twice
  end

  it 'uses four sanitized profile attempts and renews before every bounded rate wait slice' do
    renewer = instance_double(Proc, call: true)
    rate_client = described_class.new(
      channel,
      delay_ms: 0,
      max_conversation_pages: 2,
      max_message_pages: 2,
      sleeper: sleeper,
      random: random,
      max_rate_limit_wait_seconds: 2_000,
      renewer: renewer
    )
    allow(Umi::Fbig::SanitizedKoalaApi).to receive(:new).and_return(api)
    attempts = 0
    allow(api).to receive(:get_object) do
      attempts += 1
      case attempts
      when 1
        raise Koala::Facebook::ClientError.new(429, '', { 'code' => 613 })
      when 2
        raise Koala::Facebook::ServerError.new(503, '', {})
      when 3
        raise Faraday::TimeoutError
      end

      { 'id' => 'facebook-user-1', 'first_name' => 'First' }
    end

    result = rate_client.profile('messenger', 'facebook-user-1')

    expect(result.attributes).to eq('id' => 'facebook-user-1', 'first_name' => 'First')
    expect(api).to have_received(:get_object).exactly(4).times
    expect(renewer).to have_received(:call).once
    expect(sleeper).to have_received(:sleep).with(60).once
    expect(sleeper).to have_received(:sleep).with(1.0).once
    expect(sleeper).to have_received(:sleep).with(2.0).once
    expect(rate_client.stats).to include(
      profile_logical_lookups: 1,
      profile_http_attempts: 4,
      rate_limit_retries: 1,
      rate_limit_wait_seconds: 60
    )
  end

  it 'keeps pure transport failures to two retries under the profile rate controller' do
    renewer = instance_double(Proc, call: true)
    rate_client = described_class.new(
      channel,
      delay_ms: 0,
      max_conversation_pages: 2,
      max_message_pages: 2,
      sleeper: sleeper,
      random: random,
      max_rate_limit_wait_seconds: 2_000,
      renewer: renewer
    )
    allow(Umi::Fbig::SanitizedKoalaApi).to receive(:new).and_return(api)
    allow(api).to receive(:get_object).and_raise(Koala::Facebook::ServerError.new(503, '', {}))

    expect { rate_client.profile('messenger', 'facebook-user-1') }
      .to raise_error(described_class::RequestError) do |error|
        expect(error.reason).to eq(:retry_exhausted)
      end
    expect(api).to have_received(:get_object).exactly(3).times
    expect(sleeper).to have_received(:sleep).with(0.5).once
    expect(sleeper).to have_received(:sleep).with(1.0).once
    expect(rate_client.stats).to include(rate_limit_retries: 0, rate_limit_wait_seconds: 0)
  end

  it 'does not retry authentication failures' do
    allow(api).to receive(:get_object)
      .and_raise(Koala::Facebook::AuthenticationError.new(401, 'bad token'))

    expect { client.detail('mid-1') }.to raise_error(described_class::AuthenticationError)
    expect(api).to have_received(:get_object).once
  end

  it 'classifies exhausted rate-limit retries without exposing the response' do
    allow(api).to receive(:get_object)
      .and_raise(Koala::Facebook::ClientError.new(429, 'secret response', { 'code' => 613, 'message' => 'secret' }))

    expect { client.detail('mid-1') }.to raise_error(described_class::RequestError) do |error|
      expect(error.reason).to eq(:rate_limit)
      expect(error.message).not_to include('secret')
    end
    expect(api).to have_received(:get_object).exactly(3).times
  end

  it 'classifies malformed usage metadata without exposing the response' do
    allow(api).to receive(:get_object)
      .and_raise(Umi::Fbig::SanitizedKoalaApi::UsageMetadataError)

    expect { client.profile('messenger', 'facebook-user-1') }
      .to raise_error(described_class::RequestError) do |error|
        expect(error.reason).to eq(:invalid_usage_metadata)
        expect(error.message).not_to include('Meta usage metadata')
      end
    expect(api).to have_received(:get_object).once
  end

  it 'returns nil for permanently unavailable detail' do
    allow(api).to receive(:get_object)
      .and_raise(Koala::Facebook::ClientError.new(400, '', { 'code' => 100, 'message' => 'unavailable' }))

    expect(client.detail('mid-1')).to be_nil
  end

  describe '#profile' do
    it 'normalizes a complete Instagram profile through the configured Koala client' do
      allow(api).to receive(:get_object)
        .with(
          'instagram-user-1',
          {
            fields: 'id,name,username,profile_pic,follower_count,is_user_follow_business,' \
                    'is_business_follow_user,is_verified_user'
          }
        )
        .and_return(
          {
            'id' => 'instagram-user-1',
            'name' => 'Profile Name',
            'username' => 'profile_name',
            'profile_pic' => 'https://example.invalid/avatar.jpg',
            'follower_count' => 123,
            'is_user_follow_business' => true,
            'is_business_follow_user' => false,
            'is_verified_user' => true,
            'not_requested' => 'must not escape'
          }
        )

      result = client.profile('instagram', 'instagram-user-1')

      expect(Koala::Facebook::API).to have_received(:new).with('token').once
      expect(result.attributes).to eq(
        'id' => 'instagram-user-1',
        'name' => 'Profile Name',
        'username' => 'profile_name',
        'profile_pic' => 'https://example.invalid/avatar.jpg',
        'follower_count' => 123,
        'is_user_follow_business' => true,
        'is_business_follow_user' => false,
        'is_verified_user' => true
      )
      expect(result.unavailable_reason).to be_nil
    end

    it 'keeps only returned allowlisted Instagram fields for a partial profile' do
      allow(api).to receive(:get_object)
        .and_return('id' => 'instagram-user-1', 'username' => 'profile_name', 'ignored' => 'value')

      result = client.profile('instagram', 'instagram-user-1')

      expect(result.attributes).to eq('id' => 'instagram-user-1', 'username' => 'profile_name')
      expect(result.unavailable_reason).to be_nil
    end

    it 'normalizes Messenger profile fields without inventing a display name' do
      allow(api).to receive(:get_object)
        .with('facebook-user-1', { fields: 'id,first_name,last_name,profile_pic' })
        .and_return(
          'id' => 'facebook-user-1',
          'first_name' => 'First',
          'last_name' => 'Last',
          'profile_pic' => 'https://example.invalid/avatar.jpg',
          'name' => 'Must not escape'
        )

      result = client.profile('messenger', 'facebook-user-1')

      expect(result.attributes).to eq(
        'id' => 'facebook-user-1',
        'first_name' => 'First',
        'last_name' => 'Last',
        'profile_pic' => 'https://example.invalid/avatar.jpg'
      )
    end

    it 'rejects an unknown platform before making a Graph request' do
      expect(api).not_to receive(:get_object)
      expect { client.profile('whatsapp', 'user-1') }.to raise_error(described_class::ProfileError) do |error|
        expect(error.reason).to eq(:unsupported_platform)
      end
    end

    it 'rejects a profile response without an id' do
      allow(api).to receive(:get_object).and_return('name' => 'Profile Name')

      expect { client.profile('instagram', 'instagram-user-1') }.to raise_error(described_class::ProfileError) do |error|
        expect(error.reason).to eq(:missing_id)
      end
    end

    it 'rejects a profile response for a different participant' do
      allow(api).to receive(:get_object)
        .and_return('id' => 'different-user', 'name' => 'Profile Name')

      expect { client.profile('instagram', 'instagram-user-1') }.to raise_error(described_class::ProfileError) do |error|
        expect(error.reason).to eq(:identity_mismatch)
        expect(error.message).not_to include('instagram-user-1', 'different-user', 'Profile Name')
      end
    end

    [
      [100, 33],
      [100, 2_018_218],
      [10, nil],
      [230, nil],
      [9010, nil]
    ].each do |code, subcode|
      it "returns aggregate unavailability for the known per-user error #{code}/#{subcode || 'none'}" do
        error_info = {
          'type' => 'GraphMethodException',
          'code' => code,
          'message' => 'secret profile response'
        }
        error_info['error_subcode'] = subcode if subcode
        allow(api).to receive(:get_object)
          .and_raise(Koala::Facebook::ClientError.new(400, 'secret body', error_info))

        result = client.profile('instagram', 'instagram-user-1')

        expect(result.attributes).to be_nil
        expect(result.unavailable_reason).to eq(:profile_unavailable)
      end
    end

    it 'raises a typed contract error for unsupported fields reported as code 100' do
      allow(api).to receive(:get_object)
        .and_raise(
          Koala::Facebook::ClientError.new(
            400,
            'secret body',
            {
              'type' => 'GraphMethodException',
              'code' => 100,
              'message' => 'Tried accessing a nonexisting field'
            }
          )
        )

      expect { client.profile('instagram', 'instagram-user-1') }.to raise_error(described_class::ProfileError) do |error|
        expect(error.reason).to eq(:contract_error)
        expect(error.message).not_to include('nonexisting', 'secret')
      end
      expect(api).to have_received(:get_object).once
    end

    it 'raises a typed contract error for an unknown non-retryable client error' do
      allow(api).to receive(:get_object)
        .and_raise(
          Koala::Facebook::ClientError.new(
            400,
            'secret body',
            { 'type' => 'OAuthException', 'code' => 200, 'message' => 'secret permission response' }
          )
        )

      expect { client.profile('messenger', 'facebook-user-1') }.to raise_error(described_class::ProfileError) do |error|
        expect(error.reason).to eq(:contract_error)
        expect(error.message).not_to include('permission', 'secret')
      end
      expect(api).to have_received(:get_object).once
    end

    it 'keeps a code 190 authentication failure fatal and does not retry it' do
      allow(api).to receive(:get_object)
        .and_raise(
          Koala::Facebook::ClientError.new(
            400,
            'secret body',
            { 'type' => 'OAuthException', 'code' => 190, 'message' => 'secret token response' }
          )
        )

      expect { client.profile('messenger', 'facebook-user-1') }
        .to raise_error(described_class::AuthenticationError)
      expect(api).to have_received(:get_object).once
    end

    it 'retries a server error before returning a normalized profile' do
      attempts = 0
      allow(api).to receive(:get_object) do
        attempts += 1
        raise Koala::Facebook::ServerError.new(500, 'secret response') if attempts < 3

        { 'id' => 'facebook-user-1', 'first_name' => 'First' }
      end

      result = client.profile('messenger', 'facebook-user-1')

      expect(result.attributes).to eq('id' => 'facebook-user-1', 'first_name' => 'First')
      expect(api).to have_received(:get_object).exactly(3).times
    end

    it 'classifies exhausted profile rate-limit retries' do
      allow(api).to receive(:get_object)
        .and_raise(
          Koala::Facebook::ClientError.new(
            429,
            'secret body',
            { 'type' => 'OAuthException', 'code' => 613, 'message' => 'secret rate response' }
          )
        )

      expect { client.profile('messenger', 'facebook-user-1') }.to raise_error(described_class::RequestError) do |error|
        expect(error.reason).to eq(:rate_limit)
        expect(error.message).not_to include('secret')
      end
      expect(api).to have_received(:get_object).exactly(3).times
    end

    it 'retries a network timeout before returning a normalized profile' do
      attempts = 0
      allow(api).to receive(:get_object) do
        attempts += 1
        raise Faraday::TimeoutError, 'secret network response' if attempts < 3

        { 'id' => 'facebook-user-1', 'last_name' => 'Last' }
      end

      result = client.profile('messenger', 'facebook-user-1')

      expect(result.attributes).to eq('id' => 'facebook-user-1', 'last_name' => 'Last')
      expect(api).to have_received(:get_object).exactly(3).times
    end
  end
end
