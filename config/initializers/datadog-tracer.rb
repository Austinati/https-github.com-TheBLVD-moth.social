# frozen_string_literal: true

require 'ddtrace'

if Rails.env.production? || Rails.env.staging?
  Datadog.configure do |c|
    if Rails.configuration.hosts[0].include? 'staging'
      c.env = 'staging'
    else
      c.profiling.enabled = true
      c.env = Rails.env
    end
    c.service = 'moth.social'
    c.tracing.instrument :httprb, service_name: 'moth.social'
    c.tracing.instrument :faraday, service_name: 'moth.social'
    c.tracing.instrument :active_support, service_name: 'moth.social'
    c.tracing.instrument :http, service_name: 'moth.social'
    c.tracing.instrument :rack, service_name: 'moth.social', headers: { response: %w(Content-Type X-Request-ID X-RateLimit-Remaining) }
  end
end
