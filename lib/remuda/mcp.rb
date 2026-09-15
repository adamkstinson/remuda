# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Remuda
  module Mcp
    def self.call(url, tool_name, arguments, token: nil)
      uri = URI(url)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{token}" if token && !token.empty?
      request.body = JSON.generate(
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: { name: tool_name, arguments: arguments }
      )

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(request)
      end

      raise "MCP HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      payload = JSON.parse(response.body)
      raise "MCP error: #{payload["error"]}" if payload["error"]

      payload["result"]
    end
  end
end
