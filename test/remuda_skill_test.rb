# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "yaml"
require "remuda"

# Every scaffolded agent gets a skill that teaches an agent to use Remuda.
class RemudaSkillTest < Minitest::Test
  def test_remuda_new_writes_the_remuda_skill
    Dir.mktmpdir("remuda-new") do |dir|
      Remuda::Generator.new_agent(dir)
      path = File.join(dir, ".pi", "skills", "remuda", "SKILL.md")
      assert File.file?(path), "expected .pi/skills/remuda/SKILL.md"

      text = File.read(path)
      front = YAML.safe_load(text[/\A---\n(.*?)\n---\n/m, 1])
      assert_equal "remuda", front["name"], "name must match the skill's directory"
      assert_operator front["description"].to_s.length, :>, 40
      assert_operator front["description"].to_s.length, :<=, 1024
    end
  end

  # Break this catches: the skill naming a command or API the gem does not have.
  def test_the_skill_only_names_commands_the_cli_has
    text = File.read(File.expand_path("../lib/remuda/templates/agent/.pi/skills/remuda/SKILL.md", __dir__))
    commands = text.scan(/^\s*remuda ([a-z][a-z:-]*)/).flatten.uniq
    known = %w[new run tick schedule unschedule schedules tools console version help]
    assert_empty commands - known, "skill names unknown commands"
    %w[Remuda.tool Remuda.tools Remuda.agent Remuda.channels].each do |api|
      assert_includes text, api
    end
  end
end
