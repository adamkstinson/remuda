# frozen_string_literal: true

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
        remuda version
        remuda help
      HELP
    end
  end
end
