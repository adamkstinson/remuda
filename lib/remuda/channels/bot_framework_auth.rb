# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "openssl"
require "uri"

module Remuda
  module Channels
    # Validates the bearer token the Bot Connector puts on every activity it
    # POSTs to a bot: an RS256 JWT signed by a key from the Bot Framework
    # OpenID metadata, issued by https://api.botframework.com, for this bot's
    # app id, whose serviceUrl claim matches the activity's. Keys are cached
    # and refetched when an unknown kid shows up (rotation). Stdlib only.
    class BotFrameworkAuth
      OPENID_URL = "https://login.botframework.com/v1/.well-known/openidconfiguration"
      ISSUER = "https://api.botframework.com"
      SKEW = 300
      KEYS_TTL = 24 * 3600
      REFRESH_FLOOR = 300

      class Invalid < StandardError; end

      def initialize(app_id:, openid_url: OPENID_URL, fetch: nil, clock: -> { Time.now })
        @app_id = app_id
        @openid_url = openid_url
        @fetch = fetch || method(:http_get_json)
        @clock = clock
        @keys = nil
        @fetched_at = nil
        @lock = Mutex.new
      end

      # Returns the token's claims, or raises Invalid.
      def verify!(authorization, service_url:, channel_id:)
        token = authorization.to_s[/\ABearer\s+(\S+)\z/, 1]
        raise Invalid, "no bearer token" if token.nil?

        parts = token.split(".")
        raise Invalid, "not a signed JWT" unless parts.size == 3

        header = decode_json(parts[0])
        claims = decode_json(parts[1])
        raise Invalid, "alg #{header["alg"].inspect} is not RS256" unless header["alg"] == "RS256"

        jwk = key_for(header["kid"])
        raise Invalid, "unknown signing key" if jwk.nil?
        raise Invalid, "bad signature" unless signature_ok?(jwk, parts)

        check_claims!(claims, service_url)
        check_endorsement!(jwk, channel_id)
        claims
      end

      private

      def check_claims!(claims, service_url)
        now = @clock.call.to_i
        raise Invalid, "wrong issuer" unless claims["iss"] == ISSUER
        raise Invalid, "wrong audience" unless Array(claims["aud"]).include?(@app_id)
        raise Invalid, "expired" unless claims["exp"].is_a?(Numeric) && now < claims["exp"] + SKEW
        raise Invalid, "not yet valid" if claims["nbf"].is_a?(Numeric) && now + SKEW < claims["nbf"]

        claimed = claims["serviceurl"] || claims["serviceUrl"]
        raise Invalid, "serviceUrl does not match the token" unless same_service_url?(claimed, service_url)
      end

      def same_service_url?(claimed, actual)
        !claimed.to_s.empty? && claimed.to_s.chomp("/") == actual.to_s.chomp("/")
      end

      def check_endorsement!(jwk, channel_id)
        endorsements = jwk["endorsements"]
        return unless endorsements.is_a?(Array)
        return if endorsements.include?(channel_id)

        raise Invalid, "signing key is not endorsed for #{channel_id.inspect}"
      end

      def signature_ok?(jwk, parts)
        signature = Base64.urlsafe_decode64(parts[2])
        public_key(jwk).verify("SHA256", signature, "#{parts[0]}.#{parts[1]}")
      rescue ArgumentError, OpenSSL::PKey::PKeyError
        false
      end

      def key_for(kid)
        @lock.synchronize do
          now = @clock.call.to_f
          refresh!(now) if @keys.nil? || now - @fetched_at > KEYS_TTL
          found = @keys[kid]
          if found.nil? && now - @fetched_at > REFRESH_FLOOR
            refresh!(now)
            found = @keys[kid]
          end
          found
        end
      end

      def refresh!(now)
        metadata = @fetch.call(@openid_url)
        jwks = @fetch.call(metadata.fetch("jwks_uri"))
        @keys = Array(jwks["keys"]).to_h { |key| [key["kid"], key] }
        @fetched_at = now
      rescue StandardError => e
        raise Invalid, "cannot load Bot Framework signing keys (#{e.class})" if @keys.nil?
      end

      def public_key(jwk)
        if jwk["x5c"].is_a?(Array) && !jwk["x5c"].empty?
          return OpenSSL::X509::Certificate.new(Base64.decode64(jwk["x5c"].first)).public_key
        end

        n = OpenSSL::BN.new(Base64.urlsafe_decode64(jwk.fetch("n")), 2)
        e = OpenSSL::BN.new(Base64.urlsafe_decode64(jwk.fetch("e")), 2)
        rsa = OpenSSL::ASN1::Sequence([OpenSSL::ASN1::Integer(n), OpenSSL::ASN1::Integer(e)])
        spki = OpenSSL::ASN1::Sequence([
          OpenSSL::ASN1::Sequence([OpenSSL::ASN1::ObjectId("rsaEncryption"), OpenSSL::ASN1::Null(nil)]),
          OpenSSL::ASN1::BitString(rsa.to_der)
        ])
        OpenSSL::PKey::RSA.new(spki.to_der)
      end

      def decode_json(part)
        value = JSON.parse(Base64.urlsafe_decode64(part))
        raise Invalid, "malformed token" unless value.is_a?(Hash)

        value
      rescue ArgumentError, JSON::ParserError
        raise Invalid, "malformed token"
      end

      def http_get_json(url)
        uri = URI(url)
        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https",
                                                           open_timeout: 10, read_timeout: 10) do |http|
          http.request(Net::HTTP::Get.new(uri))
        end
        raise "GET #{url}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      end
    end
  end
end
