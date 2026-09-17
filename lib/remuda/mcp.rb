# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Remuda
  module Mcp
    def self.call(url, tool_name, arguments, token: nil, headers: {})
      rpc(url, "tools/call", { name: tool_name, arguments: arguments }, token: token, headers: headers)
    end

    def self.list(url, token: nil, headers: {})
      result = rpc(url, "tools/list", {}, token: token, headers: headers)
      Array(result && result["tools"])
    end

    def self.rpc(url, method, params, token: nil, headers: {})
      uri = URI(url)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{token}" if token && !token.empty?
      headers.each do |key, value|
        next if value.nil? || value.to_s.empty?

        request[key.to_s] = value.to_s
      end
      request.body = JSON.generate(
        jsonrpc: "2.0",
        id: 1,
        method: method,
        params: params
      )

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(request)
      end

      raise "MCP HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      payload = JSON.parse(response.body)
      raise "MCP error: #{payload["error"]}" if payload["error"]

      payload["result"]
    end
    private_class_method :rpc
  end
end
