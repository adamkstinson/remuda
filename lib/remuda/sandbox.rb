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

    def self.run(agent_dir, prompt, provider: nil, model: nil)
      agent_dir = File.expand_path(agent_dir)
      configure_wait_timeout!

      Dir.mktmpdir("remuda-sandbox") do |tmpdir|
        File.chmod(0o700, tmpdir)
        prompt_path = File.join(tmpdir, "prompt.txt")
        File.write(prompt_path, prompt.to_s)
        File.chmod(0o644, prompt_path)
        ensure_pi_agent_dir(agent_dir)

        wait = nil
        text = ""
        McpForwarder.open(agent_dir, tmpdir) do |mcp_path, _forwarder|
          container = Docker::Container.create(
            batch_spec(agent_dir, prompt_path: prompt_path, mcp_path: mcp_path, provider: provider, model: model)
          )
          begin
            container.start
            wait = container.wait(WAIT_SECONDS)
            text = decode_logs(container.logs(stdout: true, stderr: true))
          ensure
            container.delete(force: true)
          end
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

    # Without provider: / model:, Pi picks its own default from the agent's
    # settings.json. Remuda does not declare a second one.
    def self.batch_spec(agent_dir, prompt_path:, mcp_path: nil, provider: nil, model: nil)
      agent_dir = File.expand_path(agent_dir)
      ensure_pi_agent_dir(agent_dir)
      cmd = [
        "--mode", "json",
        "--print",
        "--approve"
      ]
      cmd.push("--provider", provider.to_s) unless provider.to_s.empty?
      cmd.push("--model", model.to_s) unless model.to_s.empty?
      cmd << "@/run/remuda/prompt.txt"
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
            mcp_path: mcp_path,
            workflows_mode: "ro"
          ),
          "CapDrop" => ["ALL"],
          "Tmpfs" => tmpfs(agent_dir),
          "ExtraHosts" => extra_hosts
        }
      }
    end

    def self.interactive_spec(agent_dir, mcp_path: nil)
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
          "Binds" => binds(agent_dir, mcp_path: mcp_path, workflows_mode: "rw"),
          "CapDrop" => ["ALL"],
          "Tmpfs" => tmpfs(agent_dir),
          "ExtraHosts" => extra_hosts
        }
      }
    end

    # Runs docker as a child, not exec, so the MCP forwarder can live for
    # the length of the session.
    def self.attach(agent_dir)
      agent_dir = File.expand_path(agent_dir)
      Dir.mktmpdir("remuda-sandbox") do |tmpdir|
        File.chmod(0o700, tmpdir)
        McpForwarder.open(agent_dir, tmpdir) do |mcp_path, _forwarder|
          system(*attach_args(agent_dir, mcp_path: mcp_path))
        end
      end
      $?&.exitstatus
    end

    def self.attach_args(agent_dir, mcp_path: nil)
      agent_dir = File.expand_path(agent_dir)
      ensure_pi_agent_dir(agent_dir)
      spec = interactive_spec(agent_dir, mcp_path: mcp_path)
      args = [
        "docker", "run", "--rm", "-it",
        "--user", spec["User"],
        "--workdir", "/agent",
        "--entrypoint", "pi"
      ]
      spec.dig("HostConfig", "Tmpfs").each do |path, flags|
        args << "--tmpfs" << "#{path}:#{flags}"
      end
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

    # .remuda/ is masked by an empty root-owned tmpfs (db, bin, Gemfile stay
    # on the host); workflows/ is bind-mounted back on top of it.
    def self.tmpfs(agent_dir)
      mounts = { "/tmp" => tmpfs_flags }
      if File.directory?(File.join(agent_dir, ".remuda"))
        mounts["/agent/.remuda"] = "rw,nosuid,nodev,noexec,size=64k,mode=0755"
      end
      mounts
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

    # Only mask what exists: Docker creates a missing mount target, and in a
    # bind-mounted directory that is a root-owned file on the host.
    def self.binds(agent_dir, prompt_path: nil, mcp_path: nil, workflows_mode: "rw")
      agent_dir = File.expand_path(agent_dir)
      mounts = ["#{agent_dir}:/agent:rw"]
      mounts << "/dev/null:/agent/.env:ro" if File.exist?(File.join(agent_dir, ".env"))
      workflows = File.join(agent_dir, ".remuda", "workflows")
      mounts << "#{workflows}:/agent/.remuda/workflows:#{workflows_mode}" if File.directory?(workflows)
      mounts << "#{prompt_path}:/run/remuda/prompt.txt:ro" if prompt_path
      mounts << "#{mcp_path}:/agent/mcp.json:ro" if mcp_path
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
