# frozen_string_literal: true

require "docker"
require "fileutils"
require "tmpdir"

module Remuda
  AgentResult = Struct.new(:output, :session_id, :usage, :ok, :exit_code, :image, keyword_init: true)

  module Sandbox
    def self.run(agent_dir, prompt)
      agent_dir = File.expand_path(agent_dir)

      Dir.mktmpdir("remuda-prompt") do |tmpdir|
        File.chmod(0o755, tmpdir)
        prompt_path = File.join(tmpdir, "prompt.txt")
        File.write(prompt_path, prompt.to_s)
        File.chmod(0o644, prompt_path)

        container = Docker::Container.create(
          "Image" => Image.tag,
          "Entrypoint" => ["pi"],
          "Cmd" => [
            "--mode", "json",
            "--print",
            "--approve",
            "--no-session",
            "--offline",
            "@/run/remuda/prompt.txt"
          ],
          "WorkingDir" => "/agent",
          "User" => "#{Process.uid}:#{Process.gid}",
          "Env" => ["PI_OFFLINE=1", "PI_TELEMETRY=0", "AGENT_PROMPT_FILE=/run/remuda/prompt.txt"],
          "HostConfig" => {
            "Binds" => binds(agent_dir, prompt_path),
            "CapDrop" => ["ALL"],
            "Tmpfs" => { "/tmp" => "rw,nosuid,size=64m" }
          }
        )

        container.start
        wait = container.wait(180)
        status = wait.fetch("StatusCode", 1).to_i
        text = decode_logs(container.logs(stdout: true, stderr: true))
        container.delete(force: true)

        AgentResult.new(
          output: text,
          session_id: nil,
          usage: nil,
          ok: status.zero?,
          exit_code: status,
          image: Image.tag
        )
      end
    end

    def self.binds(agent_dir, prompt_path)
      mounts = ["#{prompt_path}:/run/remuda/prompt.txt:ro"]
      %w[AGENTS.md mcp.json].each do |name|
        host = File.join(agent_dir, name)
        mounts << "#{host}:/agent/#{name}:ro" if File.file?(host)
      end
      %w[.pi files].each do |name|
        host = File.join(agent_dir, name)
        mounts << "#{host}:/agent/#{name}:rw" if File.directory?(host)
      end
      workflows = File.join(agent_dir, ".remuda", "workflows")
      mounts << "#{workflows}:/agent/.remuda/workflows:ro" if File.directory?(workflows)
      mounts
    end
    private_class_method :binds

    def self.decode_logs(raw)
      raw = raw.to_s
      return raw if raw.empty?
      return raw unless raw.bytesize >= 8 && raw.bytes[0].to_i <= 2

      out = +""
      offset = 0
      bytes = raw.b
      while offset + 8 <= bytes.bytesize
        size = bytes[offset + 4, 4].unpack1("N")
        out << bytes[offset + 8, size].to_s
        offset += 8 + size
      end
      out.encode("UTF-8", invalid: :replace, undef: :replace)
    end
    private_class_method :decode_logs
  end
end
