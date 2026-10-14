# frozen_string_literal: true

# End-to-end check that Pi resumes the session Remuda asks for: two
# Sandbox.run calls with the same session_id are one growing conversation.
# Needs Docker and the image built from image/. Not part of `rake test`.
#
#   docker build -t remuda-pi:latest image/
#   ruby -Ilib test/integration/session_resume.rb
#
# A fake OpenAI-compatible model runs on the host and records every request.
# The first turn plants a codeword; the resumed turn's request must carry it.
require "remuda"
require "fileutils"
require "tmpdir"
require "socket"
require "json"

LOG = []
REQUESTS = []
SID = "12345678-1234-1234-1234-123456789abc"
IMAGE = ENV.fetch("IMAGE", "remuda-pi:latest")
HOST_NETWORK = ENV["REMUDA_CHECK_NETWORK"] == "host"
MODEL_BIND = HOST_NETWORK ? "127.0.0.1" : Remuda::McpForwarder.bind_address
MODEL_HOST = HOST_NETWORK ? "127.0.0.1" : "host.docker.internal"

def http_server(bind, &handler)
  srv = TCPServer.new(bind, 0)
  Thread.new do
    loop do
      c = srv.accept
      Thread.new(c) do |s|
        line = s.gets.to_s
        h = {}
        while (l = s.gets) && l != "\r\n"; k, v = l.split(":", 2); h[k.downcase.strip] = v.to_s.strip; end
        body = h["content-length"] ? s.read(h["content-length"].to_i) : ""
        handler.call(s, line.split[0], line.split[1], h, body)
      rescue => e
        warn "server err #{e.class} #{e.message}"
      ensure
        s.close rescue nil
      end
    end
  end
  srv
end

# Fake OpenAI-compatible model
model = http_server(MODEL_BIND) do |s, method, path, h, body|
  req = JSON.parse(body) rescue {}
  LOG << "LLM #{path}"
  REQUESTS << Array(req["messages"])
  chunk = ->(delta, fin = nil) { "data: #{JSON.generate(id: "c", object: "chat.completion.chunk", created: 0, model: "fake", choices: [{ index: 0, delta: delta, finish_reason: fin }])}\n\n" }
  sse = chunk.({ role: "assistant", content: "ok" }) + chunk.({}, "stop")
  sse += "data: [DONE]\n\n"
  s.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n#{sse}")
end

dir = Dir.mktmpdir("remuda-session-check")
at_exit { FileUtils.rm_rf(dir) }
FileUtils.mkdir_p(["#{dir}/.remuda/workflows", "#{dir}/.pi/agent"])
File.write("#{dir}/AGENTS.md", "Test agent.\n")
FileUtils.mkdir_p("#{dir}/files")
File.write("#{dir}/.remuda/image", "#{IMAGE}\n")
File.write("#{dir}/.pi/agent/models.json", JSON.pretty_generate(
  "providers" => { "fake" => { "baseUrl" => "http://#{MODEL_HOST}:#{model.addr[1]}/v1", "api" => "openai-completions", "apiKey" => "x",
    "compat" => { "supportsDeveloperRole" => false, "supportsReasoningEffort" => false },
    "models" => [{ "id" => "fake-model" }] } }))
File.write("#{dir}/.pi/agent/settings.json", JSON.pretty_generate("defaultProvider" => "fake", "defaultModel" => "fake-model"))

if HOST_NETWORK
  class << Remuda::Sandbox
    alias_method :check_batch_spec, :batch_spec
    def batch_spec(*args, **kwargs)
      check_batch_spec(*args, **kwargs).tap { |spec| spec["HostConfig"]["NetworkMode"] = "host" }
    end
  end
end

first_run = Remuda::Sandbox.run(dir, "Remember: the codeword is pineapple.", session_id: SID)
puts "first: exit=#{first_run.exit_code} session=#{first_run.session_id} output=#{first_run.output}"
second_run = Remuda::Sandbox.run(dir, "What is the codeword?", session_id: SID)
puts "second: exit=#{second_run.exit_code} session=#{second_run.session_id} output=#{second_run.output}"

resumed = REQUESTS.last.to_s.include?("pineapple")
checks = { "first run exits clean" => first_run.ok,
           "first run reports the requested session id" => first_run.session_id == SID,
           "second run exits clean" => second_run.ok,
           "second run reports the same session id" => second_run.session_id == SID,
           "resumed request carries the first turn" => resumed }
checks.each { |name, ok| puts "#{ok ? "ok  " : "FAIL"} #{name}" }
exit(checks.values.all? ? 0 : 1)
