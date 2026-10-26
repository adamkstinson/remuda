# frozen_string_literal: true

require "docker"
require "fileutils"
require "tmpdir"

module Remuda
  # stderr, last_event and pi_error are kept for a failed run's step (AgentFailure).
  AgentResult = Struct.new(:output, :session_id, :usage, :ok, :exit_code, :image, :stderr, :last_event, :pi_error,
                           keyword_init: true)

  module Sandbox
    # Mattermost and ticks call Remuda.agent. docker-api/Excon default is 60s;
    # wait() must pass a matching read_timeout or the HTTP client drops first.
    WAIT_SECONDS = 3600

    # Talking to dockerd over the unix socket occasionally drops a response
    # mid-flight (seen in production as Docker::Error::TimeoutError and a bare
    # JSON::ParserError on an empty body) when the fleet has many containers
    # starting/stopping at once. None of these mean the request was bad; a
    # fresh attempt against the same socket succeeds. Retried here, not left
    # to bubble up as a channel-reply failure with no recovery.
    RETRYABLE_ERRORS = [
      JSON::ParserError,
      Docker::Error::TimeoutError,
      Docker::Error::ServerError,
      Docker::Error::IOError,
      Errno::ECONNRESET,
      Errno::EPIPE,
      EOFError,
      IOError
    ].freeze
    MAX_ATTEMPTS = 3
    RETRY_BACKOFF_SECONDS = 2

    def self.run(agent_dir, prompt, provider: nil, model: nil, session_id: nil, tools: nil, exclude_tools: nil, policy: nil)
      agent_dir = File.expand_path(agent_dir)
      policy = policy_for(agent_dir, policy || ToolPolicy.new(tools: tools, exclude_tools: exclude_tools))
      configure_wait_timeout!

      run_once(agent_dir, prompt, provider: provider, model: model, session_id: session_id, policy: policy)
    end

    def self.run_once(agent_dir, prompt, provider:, model:, session_id:, policy:)
      Dir.mktmpdir("remuda-sandbox") do |tmpdir|
        File.chmod(0o700, tmpdir)
        prompt_path = File.join(tmpdir, "prompt.txt")
        File.write(prompt_path, prompt.to_s)
        File.chmod(0o644, prompt_path)
        ensure_pi_agent_dir(agent_dir)
        PiAuth.sync!(agent_dir)

        wait = nil
        text = ""
        stderr = ""
        local = ChannelsMcp.routes(agent_dir, run: Current.run, pins: policy.pins)
        McpForwarder.open(agent_dir, tmpdir, local: local) do |mcp_path, _forwarder|
          container = create_and_start(
            batch_spec(agent_dir, prompt_path: prompt_path, mcp_path: mcp_path, provider: provider, model: model,
                                  session_id: session_id, policy: policy)
          )
          begin
            wait = container.wait(WAIT_SECONDS)
            text = decode_logs(container.logs(stdout: true, stderr: true))
            stderr = decode_logs(container.logs(stderr: true)) unless wait.fetch("StatusCode", 1).to_i.zero?
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
          image: Image.for(agent_dir),
          stderr: stderr,
          last_event: parsed[:last_event],
          pi_error: parsed[:error]
        )
      end
    end
    private_class_method :run_once

    # Only getting the container running is retried. After start the agent may
    # already have acted (posted, commented, committed), so a later error is
    # raised: running it again would repeat those actions.
    def self.create_and_start(spec)
      attempts = 0
      begin
        attempts += 1
        container = Docker::Container.create(spec)
        begin
          container.start
        rescue StandardError
          container.delete(force: true) rescue nil
          raise
        end
        container
      rescue *RETRYABLE_ERRORS => e
        raise if attempts >= MAX_ATTEMPTS

        warn "remuda sandbox: #{e.class} starting the container (attempt #{attempts}/#{MAX_ATTEMPTS}), retrying: #{e.message}"
        sleep(RETRY_BACKOFF_SECONDS * attempts)
        retry
      end
    end
    private_class_method :create_and_start

    # Without provider: / model:, Pi picks its own default from the agent's
    # settings.json. Remuda does not declare a second one. session_id: resumes
    # an existing Pi session and creates it if missing (Pi --session-id).
    def self.batch_spec(agent_dir, prompt_path:, mcp_path: nil, provider: nil, model: nil, session_id: nil,
                        tools: nil, exclude_tools: nil, policy: nil)
      agent_dir = File.expand_path(agent_dir)
      ensure_pi_agent_dir(agent_dir)
      policy ||= ToolPolicy.new(tools: tools, exclude_tools: exclude_tools)
      cmd = [
        "--mode", "json",
        "--print",
        "--approve"
      ]
      cmd.push("--provider", provider.to_s) unless provider.to_s.empty?
      cmd.push("--model", model.to_s) unless model.to_s.empty?
      unless session_id.to_s.empty?
        raise ArgumentError, "invalid session_id: #{session_id.inspect}" unless valid_session_id?(session_id.to_s)

        cmd.push("--session-id", session_id.to_s)
      end
      cmd.concat(policy.pi_args)
      cmd << "@/run/remuda/prompt.txt"
      {
        "Image" => Image.for(agent_dir),
        "Entrypoint" => ["pi"],
        "Cmd" => cmd,
        "WorkingDir" => "/agent",
        "User" => "#{Process.uid}:#{Process.gid}",
        "Env" => sandbox_env(agent_dir, "AGENT_PROMPT_FILE=/run/remuda/prompt.txt",
                                      mcp_config: mcp_target(agent_dir, mcp_path)),
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
        "Env" => sandbox_env(agent_dir, mcp_config: mcp_target(agent_dir, mcp_path)),
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
      ensure_pi_agent_dir(agent_dir)
      PiAuth.sync!(agent_dir)
      Dir.mktmpdir("remuda-sandbox") do |tmpdir|
        File.chmod(0o700, tmpdir)
        McpForwarder.open(agent_dir, tmpdir, local: ChannelsMcp.routes(agent_dir)) do |mcp_path, _forwarder|
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

    def self.sandbox_env(agent_dir, *extra, mcp_config: nil)
      [
        "HOME=/tmp/home",
        "PI_CODING_AGENT_DIR=/agent/.pi/agent",
        "PI_TELEMETRY=0",
        *github_env(agent_dir),
        *oauth_env(agent_dir),
        *mcp_env(mcp_config),
        *extra
      ]
    end
    private_class_method :sandbox_env

    # The Pi profile reads this instead of a hardcoded path, so it points at
    # whichever copy the runner mounted for this run, or at nothing.
    def self.mcp_env(mcp_config)
      mcp_config ? ["REMUDA_MCP_CONFIG=#{mcp_config}"] : []
    end
    private_class_method :mcp_env

    def self.github_env(agent_dir)
      vars = Directory.env_vars(agent_dir)
      token = vars["GH_TOKEN"] || vars["GITHUB_TOKEN"]
      return [] if token.nil? || token.empty?

      # gh reads the token itself; git over https needs to be told to ask gh.
      # GIT_CONFIG_* is git's env-only config, so nothing is written to disk.
      [
        "GH_TOKEN=#{token}", "GITHUB_TOKEN=#{token}",
        "GIT_CONFIG_COUNT=1",
        "GIT_CONFIG_KEY_0=credential.https://github.com.helper",
        "GIT_CONFIG_VALUE_0=!gh auth git-credential"
      ]
    end
    private_class_method :github_env

    # pi-mcp-adapter's encrypted-file OAuth store reads its key only from this
    # env var. The token files live under /agent/.pi/agent/mcp-oauth-encrypted,
    # which is already mounted; nothing else is needed for OAuth MCP in the box.
    OAUTH_FILE_KEY = "PI_MCP_ADAPTER_OAUTH_FILE_KEY"

    def self.oauth_env(agent_dir)
      value = Directory.env_vars(agent_dir)[OAUTH_FILE_KEY]
      return [] if value.nil? || value.empty?

      ["#{OAUTH_FILE_KEY}=#{value}"]
    end
    private_class_method :oauth_env

    # Pi session ids are UUIDs; anything else must not reach a command line.
    def self.valid_session_id?(value)
      value.match?(/\A[0-9a-f-]{8,}\z/i)
    end
    private_class_method :valid_session_id?

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

    # The policy is built and validated before the container starts. A pin on
    # a tool this host does not answer is an ArgumentError, not a no-op.
    def self.policy_for(agent_dir, policy)
      servers = Channels.bound?(agent_dir) ? [ChannelsMcp::SERVER] : []
      policy.validate!(local_servers: servers)
    end
    private_class_method :policy_for

    # Only mask what exists: Docker creates a missing mount target, and in a
    # bind-mounted directory that is a root-owned file on the host. The run
    # copy goes over the agent's own .mcp.json when it has one (pi's project
    # path, so box and pi read one file), and beside the prompt otherwise.
    def self.binds(agent_dir, prompt_path: nil, mcp_path: nil, workflows_mode: "rw")
      agent_dir = File.expand_path(agent_dir)
      mounts = ["#{agent_dir}:/agent:rw"]
      mounts << "/dev/null:/agent/.env:ro" if File.exist?(File.join(agent_dir, ".env"))
      workflows = File.join(agent_dir, ".remuda", "workflows")
      mounts << "#{workflows}:/agent/.remuda/workflows:#{workflows_mode}" if File.directory?(workflows)
      mounts << "#{prompt_path}:/run/remuda/prompt.txt:ro" if prompt_path
      target = mcp_target(agent_dir, mcp_path)
      mounts << "#{mcp_path}:#{target}:ro" if target
      mounts.concat(Mounts.for(agent_dir))
    end
    private_class_method :binds

    def self.mcp_target(agent_dir, mcp_path)
      return nil if mcp_path.nil? || mcp_path.to_s.empty?

      if File.file?(File.join(File.expand_path(agent_dir), Mcp::CONFIG))
        Mcp::AGENT_CONFIG
      else
        Mcp::RUN_CONFIG
      end
    end
    private_class_method :mcp_target

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
