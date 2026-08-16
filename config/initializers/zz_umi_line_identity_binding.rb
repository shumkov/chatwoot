# frozen_string_literal: true

Rails.application.routes.append do
  get '/line-connect', to: 'umi/line_connect#show'
  match '/line-connect/token', to: 'umi/line_connect#token', via: %i[post options]
  post '/line-connect/bind', to: 'umi/line_connect#bind'
end

Rails.autoloaders.main.ignore(Rails.root.join('umi/app/views'))

Rails.application.config.filter_parameters += %i[email token email_token id_token]

allowed_origins = ENV.fetch('UMI_LINE_ALLOWED_ORIGINS', '').split(',').map(&:strip).reject(&:empty?)
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins(*allowed_origins)
    resource '/line-connect/token', headers: :any, methods: %i[post options], max_age: 600
  end
end

if defined?(Rack::Attack)
  token_request = lambda do |request|
    request.post? && request.path == '/line-connect/token'
  end
  Rack::Attack.throttle('umi_line_token/ip', limit: 20, period: 1.hour) do |request|
    request.ip if token_request.call(request)
  end
  Rack::Attack.throttle('umi_line_token/email', limit: 3, period: 1.day) do |request|
    next unless token_request.call(request)

    action_dispatch_request = ActionDispatch::Request.new(request.env)
    email = action_dispatch_request.params['email'].to_s.strip.downcase
    request.body.rewind
    email.present? ? Digest::SHA256.hexdigest(email)[0, 16] : nil
  end
  Rack::Attack.throttle('umi_line_bind/ip', limit: 30, period: 1.hour) do |request|
    request.ip if request.post? && request.path == '/line-connect/bind'
  end
end
