require 'rails_helper'

describe Umi::Meta::AdContextNotePresenter do
  let(:welcome) do
    Umi::Meta::AdWelcomeMessageService::Welcome.new(
      ad_id: '1', ad_name: 'Video_2',
      campaign_name: '05082026_Conversation_Messages Engagement', adset_name: 'Thai_Board',
      updated_time: '2026-08-05T23:32:29+0700',
      greeting: 'สวัสดีค่ะ {{user_full_name}}', action_type: 'ice_breakers',
      items: [{ title: 'Option one', response: 'Same answer' },
              { title: 'Option two', response: 'Same answer' },
              { title: 'Option three', response: 'Same answer' }]
    )
  end

  it 'marks which option the customer tapped and lists the rest' do
    body = described_class.new(welcome, tapped_title: 'Option two').body

    expect(body).to include('option 2 of 3', '*Option two*')
    expect(body).to include('The other options were: *Option one*, *Option three*')
  end

  it 'falls back to listing the options when the tap cannot be matched' do
    body = described_class.new(welcome, tapped_title: 'something the customer typed').body

    expect(body).to include('offered 3 options')
    expect(body).not_to include('option 0 of 3')
  end

  # Every option on the live ad answers identically, so repeating it per option
  # would be three copies of the same 300 characters — and the fact worth
  # showing is that the answer does not address the question asked.
  it 'states one answer once when the ad answers every option the same way' do
    body = described_class.new(welcome, tapped_title: 'Option one').body

    expect(body).to include('answer **all 3 options identically**')
    expect(body.scan('Same answer').size).to eq(1)
  end

  it 'lists answers per option when they actually differ' do
    welcome.items = [{ title: 'A', response: 'Answer A' }, { title: 'B', response: 'Answer B' }]

    body = described_class.new(welcome, tapped_title: 'A').body

    expect(body).to include('Answer A', 'Answer B')
  end

  it 'does not claim Meta sent anything, because 23% of taps get no reply' do
    body = described_class.new(welcome, tapped_title: 'Option one').body

    expect(body).to include('is configured to answer')
    expect(body).not_to match(/Meta sent|was told|has already been told/)
  end

  describe 'the campaign hierarchy' do
    # Meta's webhook carries only ad_id and ad_title, so campaign and ad set are
    # otherwise invisible in Chatwoot at any level.
    it 'names all three levels on one line' do
      line = described_class.new(welcome, tapped_title: 'Option one').body.lines
                            .find { |l| l.include?('Campaign:') }

      expect(line).to include('05082026_Conversation_Messages Engagement', 'Thai_Board', 'Video_2')
      expect(line.chomp.lines.size).to eq(1)
    end

    # The agent reads this mid-conversation. The greeting and the buttons are
    # what they came for; three names must not sit on top of them.
    it 'keeps the hierarchy below the greeting and the answer' do
      body = described_class.new(welcome, tapped_title: 'Option one').body

      expect(body.index('Campaign:')).to be > body.index('greeted with')
      expect(body.index('Campaign:')).to be > body.index('Same answer')
    end

    # The welcome message is the value; the hierarchy is context. Losing the
    # second must not cost the first.
    it 'still renders everything else when Meta returns no campaign or ad set' do
      welcome.campaign_name = nil
      welcome.adset_name = nil

      body = described_class.new(welcome, tapped_title: 'Option one').body

      expect(body).to include('greeted with', 'Same answer', 'option 1 of 3')
      expect(body).not_to include('Campaign:', 'Ad set:')
    end

    it 'shows whichever level did come back' do
      welcome.campaign_name = nil

      body = described_class.new(welcome, tapped_title: 'Option one').body

      expect(body).to include('Ad set: *Thai_Board*')
      expect(body).not_to include('Campaign:')
    end

    # An ad name on its own is already in the conversation sidebar.
    it 'drops the line entirely rather than printing the ad name alone' do
      welcome.campaign_name = nil
      welcome.adset_name = nil

      expect(described_class.new(welcome, tapped_title: 'Option one').body).not_to include('Video_2')
    end
  end

  # Liquid is skipped for these notes, but Chatwoot's Liquid pass rewrites
  # backtick spans into raw blocks that do not nest — so a backtick here would
  # become a trap for whoever removes the exemption without knowing why.
  it 'emits no backticks' do
    expect(described_class.new(welcome, tapped_title: 'Option one').body).not_to include('`')
    expect(described_class.failure_body('graph error 100 OAuthException')).not_to include('`')
  end

  it 'names no ad copy in the failure note' do
    body = described_class.failure_body('graph error 100 OAuthException')

    expect(body).to include('Ad context unavailable', 'graph error 100 OAuthException')
    expect(body).not_to include('สวัสดีค่ะ')
  end

  it 'renders without an answer block when the ad offers quick replies only' do
    welcome.items = [{ title: 'Learn more', response: nil }]

    body = described_class.new(welcome, tapped_title: 'Learn more').body

    expect(body).to include('option 1 of 1')
    expect(body).not_to include('configured to answer')
  end
end
