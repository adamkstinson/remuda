# frozen_string_literal: true

require "json"

module Remuda
  class CLI
    def self.start(argv)
      new(argv).run
    end

    def initialize(argv)
      @argv = argv.dup
    end

    def run
      cmd = @argv.shift
      case cmd
      when "run"
        run_workflow
      when "tick"
        tick
      when "new"
        new_agent
      when "console"
        console
      when "tools"
        show_tools
      when "version", "--version", "-v"
        $stdout.puts VERSION
      when "help", "--help", "-h"
        help
      when nil
        Sandbox.attach(Directory.find(nil))
      else
        raise ArgumentError, "unknown command: #{cmd}"
      end
    end

    private

    def run_workflow
      path, workflow = parse_path_and_name
      raise ArgumentError, "usage: remuda run [PATH] WORKFLOW" if workflow.nil? || workflow.empty?

      Runner.new(Directory.find(path)).run(workflow, trigger: "manual")
    end

    def tick
      path = @argv.shift
      Scheduler.tick(Directory.find(path))
    end

    def new_agent
      path = @argv.shift
      Generator.new_agent(path || Dir.pwd)
    end

    def console
      dir = Directory.find(@argv.shift)
      Db.connect(dir)
      Current.agent_dir = dir
      %i[WorkflowRun WorkflowStep Schedule].each do |name|
        Object.const_set(name, Remuda.const_get(name)) unless Object.const_defined?(name, false)
      end
      ARGV.clear
      require "irb"
      IRB.start
    end

    def show_tools
      path, name = parse_tools_argv
      dir = Directory.find(path)
      catalog = Remuda.tools(dir)
      if name && !name.empty?
        catalog = catalog.select do |t|
          t[:name] == name || "#{t[:server]}.#{t[:name]}" == name
        end
        raise ArgumentError, "unknown tool: #{name}" if catalog.empty?
      end

      catalog.each do |tool|
        $stdout.puts "#{tool[:server]}.#{tool[:name]}"
        $stdout.puts "  #{tool[:description]}" if tool[:description] && !tool[:description].empty?
        next unless name && tool[:input_schema]

        $stdout.puts
        $stdout.puts JSON.pretty_generate(tool[:input_schema])
      end
    end

    def parse_tools_argv
      first = @argv.shift
      second = @argv.shift
      return [nil, nil] if first.nil?
      return [first, second] if second
      return [first, nil] if Directory.agent?(File.expand_path(first))

      [nil, first]
    end

    def parse_path_and_name
      first = @argv.shift
      second = @argv.shift
      second ? [first, second] : [nil, first]
    end

    def help
      $stdout.puts <<~HELP
        remuda new [PATH]            scaffold an agent directory (skip existing files)
        remuda run [PATH] WORKFLOW   run a workflow through the Runner
        remuda tick [PATH]           fire due schedules through the same Runner
        remuda tools [PATH] [NAME]   list MCP tools, or show one schema
        remuda version
        remuda help
      HELP
    end
  end
end
