# frozen_string_literal: true

require "docker"
require "fileutils"
require "tmpdir"

module Remuda
  AgentResult = Struct.new(:output, :session_id, :usage, :ok, :exit_code, :image, keyword_init: true)

  module Sandbox
    def self.run(agent_dir, prompt)
      agent_dir = File.expand_path(agent_dir)

      Dir.mktmpdir("remuda-sandbox") do |tmpdir|
        File.chmod(0o700, tmpdir)
        prompt_path = File.join(tmpdir, "prompt.txt")
        File.write(prompt_path, prompt.to_s)
        File.chmod(0o644, prompt_path)
        ensure_pi_agent_dir(agent_dir)

        container = Docker::Container.create(
          batch_spec(agent_dir, prompt_path: prompt_path)
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

    def self.batch_spec(agent_dir, prompt_path:)
      agent_dir = File.expand_path(agent_dir)
      cmd = [
        "--mode", "json",
        "--print",
        "--approve",
        "--no-session",
        "@/run/remuda/prompt.txt"
      ]
      {
        "Image" => Image.tag,
        "Entrypoint" => ["pi"],
        "Cmd" => cmd,
        "WorkingDir" => "/agent",
        "User" => "#{Process.uid}:#{Process.gid}",
        "Env" => sandbox_env("AGENT_PROMPT_FILE=/run/remuda/prompt.txt"),
        "HostConfig" => {
          "Binds" => binds(
            agent_dir,
            prompt_path: prompt_path,
            workflows_mode: "ro"
          ),
          "CapDrop" => ["ALL"],
          "Tmpfs" => tmpfs,
          "ExtraHosts" => extra_hosts
        }
      }
    end

    def self.interactive_spec(agent_dir)
      agent_dir = File.expand_path(agent_dir)
      {
        "Image" => Image.tag,
        "Entrypoint" => ["pi"],
        "Tty" => true,
        "OpenStdin" => true,
        "WorkingDir" => "/agent",
        "User" => "#{Process.uid}:#{Process.gid}",
        "Env" => sandbox_env,
        "HostConfig" => {
          "Binds" => binds(agent_dir, workflows_mode: "rw"),
          "CapDrop" => ["ALL"],
          "Tmpfs" => tmpfs,
          "ExtraHosts" => extra_hosts
        }
      }
    end

    def self.attach(agent_dir)
      exec(*attach_args(agent_dir))
    end

    def self.attach_args(agent_dir)
      agent_dir = File.expand_path(agent_dir)
      ensure_pi_agent_dir(agent_dir)
      spec = interactive_spec(agent_dir)
      args = [
        "docker", "run", "--rm", "-it",
        "--user", spec["User"],
        "--workdir", "/agent",
        "--entrypoint", "pi",
        "--tmpfs", "/tmp:#{tmpfs_flags}",
        "--add-host", extra_hosts.first
      ]
      Array(spec["Env"]).each do |env|
        args << "-e" << env
      end
      Array(spec.dig("HostConfig", "Binds")).each do |bind|
        args << "-v" << bind
      end
      args << spec["Image"]
      args
    end

    def self.sandbox_env(*extra)
      [
        "HOME=/tmp/home",
        "PI_CODING_AGENT_DIR=/agent/.pi/agent",
        "PI_TELEMETRY=0",
        *extra
      ]
    end
    private_class_method :sandbox_env

    def self.tmpfs
      { "/tmp" => tmpfs_flags }
    end
    private_class_method :tmpfs

    def self.extra_hosts
      ["host.docker.internal:host-gateway"]
    end
    private_class_method :extra_hosts

    def self.tmpfs_flags
      "rw,nosuid,size=64m,uid=#{Process.uid},gid=#{Process.gid}"
    end
    private_class_method :tmpfs_flags

    def self.ensure_pi_agent_dir(agent_dir)
      dir = File.join(File.expand_path(agent_dir), ".pi", "agent")
      FileUtils.mkdir_p(File.join(dir, "sessions"))
      dir
    end
    private_class_method :ensure_pi_agent_dir

    def self.binds(agent_dir, prompt_path: nil, workflows_mode: "ro")
      mounts = []
      mounts << "#{prompt_path}:/run/remuda/prompt.txt:ro" if prompt_path
      %w[AGENTS.md mcp.json].each do |name|
        host = File.join(agent_dir, name)
        mounts << "#{host}:/agent/#{name}:ro" if File.file?(host)
      end
      %w[.pi files].each do |name|
        host = File.join(agent_dir, name)
        mounts << "#{host}:/agent/#{name}:rw" if File.directory?(host)
      end
      workflows = File.join(agent_dir, ".remuda", "workflows")
      if File.directory?(workflows)
        mounts << "#{workflows}:/agent/.remuda/workflows:#{workflows_mode}"
      end
      mounts.reject { |bind| env_bind?(bind) }
    end
    private_class_method :binds

    def self.env_bind?(bind)
      host = bind.split(":", 2).first.to_s
      File.basename(host) == ".env"
    end
    private_class_method :env_bind?

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
