# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "tmpdir"
require "remuda"

class McpOAuthTest < Minitest::Test
  KEY = "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc=" # 32 bytes of 0x07
  ACCOUNT = "sha256-576ba7c2e4abb7184ca409154dbbbd5306c1a80747fbce4148ea6271fd21e776" # "gmail"
  # Written by pi-mcp-adapter 4.0.0's encrypted-file store (node crypto), key KEY.
  NODE_ENVELOPE = {
    "version" => 1, "algorithm" => "aes-256-gcm", "iv" => "AwMDAwMDAwMDAwMD",
    "ciphertext" => "XtzXbDFNMDFYejh+ijScaZ5PtIDf8PpSFfzp3oeAbdnSxBhR6NmJYrztLXfovY8RSE92qqu4HxlDTEuOTEnuGpKQU1qDhBFpOY/F4qfWsBHHnvhFOFd6GdRh5KpfIkJurKde0+UNRiRe910rCY90wfThIAtdruVqwP/FtE8vcone25mVRHSTQvEjKcUAef4N8Ra77aD2yndpgyyHtWb/vQ9F4n0pVqxfOKTF2QDwmFpf2darFKMbs5O0xun1aoMfGGqsxiY=",
    "tag" => "8MEOO07viwtule1Dr1utFg=="
  }.freeze
  SPEC = { "url" => "https://gmailmcp.example.com/mcp/v1", "auth" => "oauth" }.freeze

  def setup
    @dir = Dir.mktmpdir
    File.write(File.join(@dir, ".env"), "PI_MCP_ADAPTER_OAUTH_FILE_KEY=#{KEY}\n")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def stub_oauth(name, impl)
    original = Remuda::McpOAuth.method(name)
    Remuda::McpOAuth.define_singleton_method(name) { |*args, **kw| impl.call(*args, **kw) }
    yield
  ensure
    Remuda::McpOAuth.define_singleton_method(name, original)
  end

  def store_path(name = "gmail")
    Remuda::McpOAuth.path(@dir, name)
  end

  def write_node_fixture
    FileUtils.mkdir_p(File.dirname(store_path))
    File.write(store_path, JSON.generate(NODE_ENVELOPE))
    File.chmod(0o600, store_path)
  end

  def test_account_and_path_match_the_adapter
    assert_equal ACCOUNT, Remuda::McpOAuth.account("gmail")
    assert_equal File.join(@dir, ".pi/agent/mcp-oauth-encrypted", ACCOUNT, "credentials.json"), store_path
  end

  def test_reads_an_entry_the_adapter_wrote
    write_node_fixture
    entry = Remuda::McpOAuth.read(@dir, "gmail")
    assert_equal "node-access", entry.dig("tokens", "accessToken")
    assert_equal "cid", entry.dig("clientInfo", "clientId")
  end

  def test_write_round_trips_in_the_adapter_envelope_with_private_modes
    entry = { "tokens" => { "accessToken" => "a", "expiresAt" => 1 } }
    Remuda::McpOAuth.write(@dir, "gmail", entry)
    envelope = JSON.parse(File.read(store_path))
    assert_equal 1, envelope["version"]
    assert_equal "aes-256-gcm", envelope["algorithm"]
    refute_includes File.read(store_path), "accessToken"
    assert_equal 0o600, File.stat(store_path).mode & 0o777
    assert_equal 0o700, File.stat(File.dirname(store_path)).mode & 0o777
    assert_equal entry, Remuda::McpOAuth.read(@dir, "gmail")
  end

  def test_a_fresh_token_is_used_without_refreshing
    write_node_fixture
    stub_oauth(:post_form, ->(*) { flunk "must not refresh" }) do
      assert_equal({ "Authorization" => "Bearer node-access" }, Remuda::McpOAuth.headers(@dir, "gmail", SPEC))
    end
  end

  def test_an_expiring_token_is_refreshed_and_written_back
    Remuda::McpOAuth.write(@dir, "gmail", {
      "tokens" => { "accessToken" => "old", "refreshToken" => "r1", "expiresAt" => Time.now.to_i + 30, "scope" => "s" },
      "clientInfo" => { "clientId" => "cid", "clientSecret" => "csec" },
      "serverUrl" => SPEC["url"]
    })
    posted = nil
    endpoint = ->(_url, _spec) { "https://oauth.example.com/token" }
    post = lambda do |url, form|
      posted = [url, form]
      { "access_token" => "new", "expires_in" => 3599, "token_type" => "Bearer" }
    end
    stub_oauth(:token_endpoint, endpoint) do
      stub_oauth(:post_form, post) do
        assert_equal({ "Authorization" => "Bearer new" }, Remuda::McpOAuth.headers(@dir, "gmail", SPEC))
      end
    end
    assert_equal "https://oauth.example.com/token", posted[0]
    assert_equal({ "grant_type" => "refresh_token", "refresh_token" => "r1",
                   "client_id" => "cid", "client_secret" => "csec" }, posted[1])
    tokens = Remuda::McpOAuth.read(@dir, "gmail")["tokens"]
    assert_equal "new", tokens["accessToken"]
    assert_equal "r1", tokens["refreshToken"], "a refresh without a new refresh token keeps the old one"
    assert_in_delta Time.now.to_i + 3599, tokens["expiresAt"], 5
    assert_equal "s", tokens["scope"]
  end

  def test_a_config_registered_client_refreshes_with_the_config_secret
    Remuda::McpOAuth.write(@dir, "gmail", {
      "tokens" => { "accessToken" => "old", "refreshToken" => "r1", "expiresAt" => 1 },
      "clientInfo" => { "clientId" => "cfg", "configPreRegistered" => true }
    })
    spec = SPEC.merge("oauth" => { "clientId" => "cfg", "clientSecret" => "cfg-secret" })
    form = nil
    stub_oauth(:token_endpoint, ->(*) { "https://t" }) do
      stub_oauth(:post_form, ->(_u, f) { form = f; { "access_token" => "n", "expires_in" => 60 } }) do
        Remuda::McpOAuth.headers(@dir, "gmail", spec)
      end
    end
    assert_equal "cfg", form["client_id"]
    assert_equal "cfg-secret", form["client_secret"]
  end

  def test_config_client_values_fill_placeholders_from_env_like_the_adapter
    File.write(File.join(@dir, ".env"), "PI_MCP_ADAPTER_OAUTH_FILE_KEY=#{KEY}\nCLIENT_SECRET=from-env\n")
    Remuda::McpOAuth.write(@dir, "gmail", {
      "tokens" => { "accessToken" => "old", "refreshToken" => "r1", "expiresAt" => 1 },
      "clientInfo" => { "clientId" => "cfg", "configPreRegistered" => true }
    })
    spec = SPEC.merge("oauth" => { "clientId" => "cfg", "clientSecret" => "${CLIENT_SECRET}" })
    form = nil
    stub_oauth(:token_endpoint, ->(*) { "https://t" }) do
      stub_oauth(:post_form, ->(_u, f) { form = f; { "access_token" => "n", "expires_in" => 60 } }) do
        Remuda::McpOAuth.headers(@dir, "gmail", spec)
      end
    end
    assert_equal "from-env", form["client_secret"]
  end

  def test_missing_key_fails_closed_and_names_the_variable
    write_node_fixture
    File.write(File.join(@dir, ".env"), "")
    error = assert_raises(Remuda::McpOAuth::Unavailable) { Remuda::McpOAuth.headers(@dir, "gmail", SPEC) }
    assert_includes error.message, "PI_MCP_ADAPTER_OAUTH_FILE_KEY"
  end

  def test_missing_credentials_fail_closed_and_name_the_connect_command
    error = assert_raises(Remuda::McpOAuth::Unavailable) { Remuda::McpOAuth.headers(@dir, "gmail", SPEC) }
    assert_includes error.message, "/mcp-auth gmail"
  end

  def test_a_wrong_key_fails_closed
    write_node_fixture
    File.write(File.join(@dir, ".env"), "PI_MCP_ADAPTER_OAUTH_FILE_KEY=#{["x" * 32].pack("m0")}\n")
    assert_raises(Remuda::McpOAuth::Unavailable) { Remuda::McpOAuth.headers(@dir, "gmail", SPEC) }
  end

  def test_oauth_servers_are_explicit_or_stored_without_headers
    assert Remuda::McpOAuth.oauth?(@dir, "gmail", SPEC)
    refute Remuda::McpOAuth.oauth?(@dir, "gmail", { "url" => "https://x" })
    write_node_fixture
    assert Remuda::McpOAuth.oauth?(@dir, "gmail", { "url" => "https://x" })
    refute Remuda::McpOAuth.oauth?(@dir, "gmail", { "url" => "https://x", "auth" => false })
    refute Remuda::McpOAuth.oauth?(@dir, "gmail", { "url" => "https://x", "headers" => { "A" => "b" } })
  end
end
