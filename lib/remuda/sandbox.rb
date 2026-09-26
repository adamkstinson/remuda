# frozen_string_literal: true

require "docker"
require "fileutils"
require "tmpdir"

module Remuda
  AgentResult = Struct.new(:output, :session_id, :usage, :ok, :exit_code, :image, keyword_init: true)

  module Sandbox
    # Mattermost and ticks call Remuda.agent. docker-api/Excon default is 60s;
    # wait() must pass a matching read_timeout or the HTTP client drops first.
    WAIT_SECONDS = 3600

    def self.run(agent_dir, prompt)
      agent_dir = File.expand_path(agent_dir)
      configure_wait_timeout!

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
        wait = nil
        text = ""
        begin
          wait = container.wait(WAIT_SECONDS)
          text = decode_logs(container.logs(stdout: true, stderr: true))
        ensure
          container.delete(force: true)
        end
        status = (wait || {}).fetch("StatusCode", 1).to_i
        parsed = PiJsonl.parse(text)

        AgentResult.new(
          output: parsed[:output],
          session_id: parsed[:session_id],
          usage: parsed[:usage],
          ok: status.zero?,
          exit_code: status,
          image: Image.for(agent_dir)
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
        "Image" => Image.for(agent_dir),
        "Entrypoint" => ["pi"],
        "Cmd" => cmd,
        "WorkingDir" => "/agent",
        "User" => "#{Process.uid}:#{Process.gid}",
        "Env" => sandbox_env(agent_dir, "AGENT_PROMPT_FILE=/run/remuda/prompt.txt"),
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
        "Image" => Image.for(agent_dir),
        "Entrypoint" => ["pi"],
        "Tty" => true,
        "OpenStdin" => true,
        "WorkingDir" => "/agent",
        "User" => "#{Process.uid}:#{Process.gid}",
        "Env" => sandbox_env(agent_dir),
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
        "--tmpfs", "/tmp:#{tmpfs_flags}"
      ]
      extra_hosts.each do |pair|
        args << "--add-host" << pair
      end
      Array(spec["Env"]).each do |env|
        args << "-e" << env
      end
      Array(spec.dig("HostConfig", "Binds")).each do |bind|
        args << "-v" << bind
      end
      args << spec["Image"]
      args
    end

    def self.sandbox_env(agent_dir, *extra)
      [
        "HOME=/tmp/home",
        "PI_CODING_AGENT_DIR=/agent/.pi/agent",
        "PI_TELEMETRY=0",
        *github_env(agent_dir),
        *extra
      ]
    end
    private_class_method :sandbox_env

    def self.github_env(agent_dir)
      vars = Directory.env_vars(agent_dir)
      token = vars["GH_TOKEN"] || vars["GITHUB_TOKEN"]
      return [] if token.nil? || token.empty?

      ["GH_TOKEN=#{token}", "GITHUB_TOKEN=#{token}"]
    end
    private_class_method :github_env

    def self.configure_wait_timeout!
      Docker.options = Docker.options.merge(
        read_timeout: WAIT_SECONDS,
        write_timeout: WAIT_SECONDS
      )
    end
    private_class_method :configure_wait_timeout!

    def self.tmpfs
      { "/tmp" => tmpfs_flags }
    end
    private_class_method :tmpfs

    def self.extra_hosts
      hosts = ["host.docker.internal:host-gateway"]
      ENV["REMUDA_EXTRA_HOSTS"].to_s.split(",").each do |pair|
        pair = pair.strip
        hosts << pair unless pair.empty?
      end
      hosts
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

    def self.binds(agent_dir, prompt_path: nil, workflows_mode: "rw")
      mounts = ["#{File.expand_path(agent_dir)}:/agent:rw"]
      mounts << "#{prompt_path}:/run/remuda/prompt.txt:ro" if prompt_path
      mounts
    end
    private_class_method :binds

    def self.decode_logs(raw)
      raw = raw.to_s.b
      return raw.force_encoding("UTF-8") if raw.empty?
      return raw.force_encoding("UTF-8") unless raw.bytesize >= 8 && raw.getbyte(0).to_i <= 2

      out = +"".b
      offset = 0
      while offset + 8 <= raw.bytesize
        size = raw[offset + 4, 4].unpack1("N")
        break if size.nil? || offset + 8 + size > raw.bytesize

        out << raw[offset + 8, size]
        offset += 8 + size
      end
      out.force_encoding("UTF-8")
      out.valid_encoding? ? out : out.encode("UTF-8", invalid: :replace, undef: :replace)
    end
    private_class_method :decode_logs
  end
end
