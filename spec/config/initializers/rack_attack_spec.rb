# frozen_string_literal: true

require 'rails_helper'

describe Rack::Attack, type: :request do
  def app
    Rails.application
  end

  shared_examples 'throttled endpoint' do
    before do
      # Rack::Attack periods are not rolling, so avoid flaky tests by setting the time in a way
      # to avoid crossing period boundaries.

      # The code Rack::Attack uses to set periods is the following:
      # https://github.com/rack/rack-attack/blob/v6.6.1/lib/rack/attack/cache.rb#L64-L66
      # So we want to minimize `Time.now.to_i % period`

      travel_to Time.zone.at((Time.now.to_i / period.seconds).to_i * period.seconds)
    end

    context 'when the number of requests is lower than the limit' do
      it 'does not change the request status' do
        limit.times do
          request.call
          expect(response).to_not have_http_status(429)
        end
      end
    end

    context 'when the number of requests is higher than the limit' do
      it 'returns http too many requests after limit and returns to normal status after period' do
        (limit * 2).times do |i|
          request.call
          expect(response).to have_http_status(429) if i > limit
        end

        travel period

        request.call
        expect(response).to_not have_http_status(429)
      end
    end
  end

  let(:remote_ip) { '1.2.3.5' }

  describe 'throttle excessive sign-up requests by IP address' do
    context 'when accessed through the website' do
      let(:limit)  { 25 }
      let(:period) { 5.minutes }
      let(:request) { -> { post path, headers: { 'REMOTE_ADDR' => remote_ip } } }

      context 'with exact path' do
        let(:path) { '/auth' }

        it_behaves_like 'throttled endpoint'
      end

      context 'with path with format' do
        let(:path) { '/auth.html' }

        it_behaves_like 'throttled endpoint'
      end
    end

    context 'when accessed through the API' do
      let(:limit)  { 5 }
      let(:period) { 30.minutes }
      let(:request) { -> { post path, headers: { 'REMOTE_ADDR' => remote_ip } } }

      context 'with exact path' do
        let(:path) { '/api/v1/accounts' }

        it_behaves_like 'throttled endpoint'
      end

      context 'with path with format' do
        let(:path)  { '/api/v1/accounts.json' }

        it 'returns http not found' do
          request.call
          expect(response).to have_http_status(404)
        end
      end
    end
  end

  describe 'throttle excessive sign-in requests by IP address' do
    let(:limit)  { 25 }
    let(:period) { 5.minutes }
    let(:request) { -> { post path, headers: { 'REMOTE_ADDR' => remote_ip } } }

    context 'with exact path' do
      let(:path) { '/auth/sign_in' }

      it_behaves_like 'throttled endpoint'
    end

    context 'with path with format' do
      let(:path) { '/auth/sign_in.html' }

      it_behaves_like 'throttled endpoint'
    end
  end

  describe 'throttle excessive oauth application registration requests by IP address' do
    let(:throttle) { 'throttle_oauth_application_registrations/ip' }
    let(:limit)  { 5 }
    let(:period) { 10.minutes }
    let(:path)   { '/api/v1/apps' }
    let(:params) do
      {
        client_name: 'Throttle Test',
        redirect_uris: 'urn:ietf:wg:oauth:2.0:oob',
        scopes: 'read',
      }
    end

    let(:request) { -> { post path, params: params, headers: { 'REMOTE_ADDR' => remote_ip } } }

    it_behaves_like 'throttled endpoint'
  end

  describe 'throttle excessive password change requests by account' do
    let(:user) { Fabricate(:user, email: 'user@host.example') }
    let(:limit) { 10 }
    let(:period) { 10.minutes }
    let(:request) { -> { put path, headers: { 'REMOTE_ADDR' => remote_ip } } }
    let(:path) { '/auth' }

    before do
      sign_in user, scope: :user

      # Unfortunately, devise's `sign_in` helper causes the `session` to be
      # loaded in the next request regardless of whether it's actually accessed
      # by the client code.
      #
      # So, we make an extra query to clear issue a session cookie instead.
      #
      # A less resource-intensive way to deal with that would be to generate the
      # session cookie manually, but this seems pretty involved.
      get '/'
    end

    it_behaves_like 'throttled endpoint'
  end
end
# rubocop:enable all
