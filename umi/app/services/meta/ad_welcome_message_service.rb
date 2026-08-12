# frozen_string_literal: true

# Reads a Click-to-Messenger ad's welcome message — the greeting Meta shows
# before the customer types, and the menu options with the answer configured for
# each — off the ad's creative.
#
# It works with the page access token already stored on the channel, which Meta
# documents as impossible: a Page token is not supposed to read Ads API nodes.
# Ours carries ads_read and ads_management in its granted scopes, so it does.
# That is undocumented and can be revoked without notice, which is why every
# failure here raises Unavailable and the caller renders a visible note rather
# than an empty one.
class Umi::Meta::AdWelcomeMessageService
  Unavailable = Class.new(StandardError)

  Welcome = Struct.new(:ad_id, :ad_name, :campaign_name, :adset_name, :updated_time,
                       :greeting, :action_type, :items, keyword_init: true)

  # Koala sends an unversioned URL when no version is given, and the Ads API
  # refuses those outright with "(#2635) You are calling a deprecated version of
  # the Ads API". Every other Koala call in this app is a Graph Page call, which
  # still tolerates unversioned URLs — this is the only Ads API caller, so it is
  # the only place the version has to be stated.
  #
  # v21.0 through v25.0 were checked against the live ad and return identical
  # payloads, so a forced version bump is a constant change rather than a
  # rewrite. The newest is pinned for the longest support window.
  GRAPH_API_VERSION = 'v25.0'
  # campaign and adset names ride this same request — Meta's webhook carries only
  # ad_id and ad_title, so the two levels above the ad are otherwise invisible in
  # Chatwoot. Expanding them here costs no extra round trip.
  FIELDS = 'id,name,updated_time,campaign{id,name},adset{id,name},' \
           'creative{id,page_welcome_message,object_story_spec,asset_feed_spec}'

  WELCOME_KEY = 'page_welcome_message'

  def initialize(access_token)
    @access_token = access_token
  end

  def fetch(ad_id)
    ad = get_ad(ad_id)
    payload = parse(scan_for_welcome(ad['creative']))
    build(ad, payload)
  end

  private

  def get_ad(ad_id)
    # api_version must be a symbol key: Koala reads raw_options[:api_version]
    # and a string key falls back to Koala.config.api_version, which nothing in
    # this app sets — reproducing the #2635 rejection at runtime.
    api.get_object(ad_id, { fields: FIELDS }, { api_version: GRAPH_API_VERSION })
  rescue Koala::Facebook::APIError => e
    raise Unavailable, "graph error #{e.fb_error_code} #{e.fb_error_type}"
  rescue StandardError => e
    # Never e.message: a connection or timeout error carries the full request
    # URI, access token included, and this string reaches an agent-visible note.
    raise Unavailable, e.class.name
  end

  # Meta documents creative.page_welcome_message, but that field comes back nil;
  # the payload actually sits inside object_story_spec under whichever *_data
  # key matches the ad's media (video_data for the current UMI ads, link_data,
  # photo_data, text_data or template_data for others). Reading a fixed path
  # returns nil, which is indistinguishable from "this ad has no welcome
  # message" — so search for the key instead of guessing where Meta put it.
  # Bounded to the creative subtree so nothing unrelated can match.
  def scan_for_welcome(node)
    case node
    when Hash then node[WELCOME_KEY].presence || scan_children(node.values)
    when Array then scan_children(node)
    end
  end

  def scan_children(values)
    values.lazy.filter_map { |value| scan_for_welcome(value) }.first
  end

  def parse(raw)
    raise Unavailable, 'no page_welcome_message on creative' if raw.blank?
    return raw.deep_stringify_keys if raw.is_a?(Hash)

    JSON.parse(raw)
  rescue JSON::ParserError
    raise Unavailable, 'page_welcome_message is not valid JSON'
  end

  def build(ad_node, payload)
    format = format_block(payload)
    message = format['message'].to_h
    action_type = format['customer_action_type']
    items = items_for(action_type, message)
    greeting = message['text'].presence

    raise Unavailable, 'welcome message carries no greeting or options' if greeting.blank? && items.empty?

    Welcome.new(
      ad_id: ad_node['id'], ad_name: ad_node['name'],
      # Read independently of the welcome message: if Meta omits either level, or
      # the token cannot see it, the note still carries the part that matters.
      campaign_name: ad_node.dig('campaign', 'name').presence,
      adset_name: ad_node.dig('adset', 'name').presence,
      updated_time: ad_node['updated_time'],
      greeting: greeting, action_type: action_type, items: items
    )
  end

  # All three blocks are always present, and only the one named by media_type is
  # what the customer saw. The others hold Meta's defaults — on the current ad,
  # an English "I'd like to learn more" nobody has ever been shown.
  def format_block(payload)
    block = payload["#{payload['media_type']}_format"] || payload['text_format']
    raise Unavailable, 'welcome message has no usable format block' if block.blank?

    block
  end

  # ice_breakers carry a title and the answer configured for it; quick_replies
  # are titles alone.
  def items_for(action_type, message)
    key = action_type == 'ice_breakers' ? 'ice_breakers' : 'quick_replies'
    Array(message[key]).filter_map do |item|
      title = item['title'].presence
      next if title.blank?

      { title: title, response: item['response'].presence }
    end
  end

  def api
    @api ||= Koala::Facebook::API.new(@access_token)
  end
end
