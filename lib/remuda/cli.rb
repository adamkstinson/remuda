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
      when "schedule"
        schedule_workflow
      when "unschedule"
        unschedule_workflow
      when "schedules"
        list_schedules
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
        next unless name

        $stdout.puts tool[:description] if tool[:description] && !tool[:description].empty?
        next unless tool[:input_schema]

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

    def schedule_workflow
      positional, flags = take_flags
      path, workflow = path_and_name_from(positional)
      raise ArgumentError, "usage: remuda schedule [PATH] WORKFLOW --cron EXPR" if workflow.nil? || workflow.empty?
      raise ArgumentError, "usage: remuda schedule [PATH] WORKFLOW --cron EXPR" if flags[:cron].nil? || flags[:cron].empty?

      dir = Directory.find(path)
      row = Scheduler.upsert(
        dir,
        workflow: workflow,
        cron: flags[:cron],
        timezone: flags[:timezone] || "UTC"
      )
      $stdout.puts schedule_line(row, prefix: "scheduled ")
      $stdout.puts Scheduler.crontab_line(dir)
    end

    def unschedule_workflow
      path, workflow = parse_path_and_name
      raise ArgumentError, "usage: remuda unschedule [PATH] WORKFLOW" if workflow.nil? || workflow.empty?

      dir = Directory.find(path)
      Scheduler.remove(dir, workflow: workflow)
      $stdout.puts "unscheduled #{workflow}"
    end

    def list_schedules
      dir = Directory.find(@argv.shift)
      rows = Scheduler.list(dir)
      if rows.empty?
        $stdout.puts "no schedules"
      else
        rows.each do |row|
          $stdout.puts schedule_line(row, paused: row.paused)
        end
      end
      $stdout.puts Scheduler.crontab_line(dir)
    end

    def take_flags
      flags = {}
      positional = []
      until @argv.empty?
        arg = @argv.shift
        case arg
        when "--cron"
          flags[:cron] = @argv.shift
        when "--timezone"
          flags[:timezone] = @argv.shift
        when /\A--/
          raise ArgumentError, "unknown flag: #{arg}"
        else
          positional << arg
        end
      end
      [positional, flags]
    end

    def schedule_line(row, prefix: "", paused: false)
      zone = row.timezone
      next_at = Clock.format(row.next_occurrence, zone)
      last_at = row.last_occurrence ? " last=#{Clock.format(row.last_occurrence, zone)}" : ""
      paused_label = paused ? " paused" : ""
      "#{prefix}#{row.workflow} #{row.cron} #{zone} next=#{next_at}#{last_at}#{paused_label}"
    end

    def path_and_name_from(positional)
      case positional.size
      when 2 then positional
      when 1 then [nil, positional[0]]
      else [nil, nil]
      end
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
        remuda schedule [PATH] WORKFLOW --cron EXPR
                                     insert or replace a schedules row; print crontab line
        remuda unschedule [PATH] WORKFLOW
                                     delete that workflow's schedules row
        remuda schedules [PATH]      list schedules and the crontab line
        remuda tools [PATH] [NAME]   list MCP tool names, or show one tool
        remuda version
        remuda help
      HELP
    end
  end
end
