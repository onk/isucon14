# frozen_string_literal: true

require 'net/http'
require 'uri'

module Isuride
  class PaymentGateway
    class UnexpectedStatusCode < StandardError
    end

    class ErroredUpstream < StandardError
    end

    def initialize(payment_gateway_url, token)
      @payment_gateway_url = payment_gateway_url
      @token = token
    end

    def request_post_payment(param, &retrieve_rides_order_by_created_at_asc)
      b = JSON.dump(param)

      # 失敗したらとりあえずリトライ
      # FIXME: 社内決済マイクロサービスのインフラに異常が発生していて、同時にたくさんリクエストすると変なことになる可能性あり
      retries = 0
      idenpotency_key = ULID.generate

      uri = URI.parse("#{@payment_gateway_url}/payments")
      req = Net::HTTP::Post.new(uri.request_uri)
      req.body = b
      req['Content-Type'] = 'application/json'
      req['Authorization'] = "Bearer #{@token}"
      req['Idempotency-Key'] = idenpotency_key

      _request_post_payment(req)
    end

    def _request_post_payment(req, retry_count = 0)
      uri = URI.parse("#{@payment_gateway_url}/payments")

      raise if retry_count > 5
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
        res = http.request(req)
        if res.code != '204'
          sleep 0.1
         _request_post_payment(req, retry_count + 1)
        end
      end
    end
  end
end
