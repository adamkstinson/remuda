# poll-and-execute — the coding agent's tick.
#
# Reads GitHub, merges pull requests that are approved and green, then picks
# the one situation that most needs the agent, checks out its branch in this
# repository, and starts the agent on it. When nothing needs the agent, nothing
# starts.
#
# This repository is the agent directory. The tick switches branches in the
# clone it runs from, so schedule it only in a clone kept for the agent.
#
#   DRY_RUN=1 ruby .remuda/workflows/poll-and-execute.rb   # print decisions, change nothing
#
# Handing work over: Adam adds the `agent` label to an issue.
# Telling voices apart: everything the agent writes ends with MARKER, because
# the agent may act under the same GitHub identity as Adam.

require "json"
require "open3"
require "time"

class CodingAgentTick
  REPO     = "adamkstinson/remuda"
  LABEL    = "agent"
  MARKER   = "<!-- coding-agent -->"
  PRIORITY = %i[review fix_ci continue start].freeze
  RED      = %w[FAILURE ERROR CANCELLED TIMED_OUT ACTION_REQUIRED STARTUP_FAILURE].freeze
  WAITING  = ["", "PENDING", "IN_PROGRESS", "QUEUED", "EXPECTED", "WAITING", "REQUESTED"].freeze

  SITUATIONS = {
    start:    "Implement this issue. Nothing has been pushed for it yet.",
    continue: "Continue implementing this draft pull request.",
    fix_ci:   "Checks are failing on this pull request. Fix them.",
    review:   "Adam has replied or reviewed since your last session. Read what is new and handle it."
  }.freeze

  def initialize(root, dry_run:)
    @root = root
    @dry_run = dry_run
  end

  def run
    gh("auth", "status")
    prs = gh_json("pr", "list", "-R", REPO, "--state", "open", "--limit", "100", "--json",
                  "number,title,url,isDraft,headRefName,labels,reviewDecision,statusCheckRollup")
    mine = prs.select { |pr| labeled?(pr) }

    candidates = []
    mine.each do |pr|
      decision = decide_pr(pr)
      log "PR ##{pr['number']} #{pr['headRefName']}: #{decision || 'nothing to do'}"
      case decision
      when :merge then merge(pr)
      when Symbol then candidates << [decision, pr]
      end
    end

    issues = gh_json("issue", "list", "-R", REPO, "--state", "open", "--label", LABEL, "--limit", "100",
                     "--json", "number,title,url,createdAt")
    issues.sort_by { |i| i["createdAt"] }.each do |issue|
      if prs.any? { |pr| pr["headRefName"].start_with?("#{issue['number']}-") }
        next
      end
      if waiting_on_issue?(issue)
        log "Issue ##{issue['number']}: waiting on Adam"
        next
      end
      log "Issue ##{issue['number']}: ready to start"
      candidates << [:start, issue]
    end

    kind, subject = candidates.min_by { |k, _| PRIORITY.index(k) }
    return log("Nothing needs the agent.") unless kind

    start_agent(kind, subject)
  end

  private

  # ── deciding ──────────────────────────────────────────────────────────────

  def decide_pr(pr)
    checks = check_state(pr)
    return :merge if !pr["isDraft"] && pr["reviewDecision"] == "APPROVED" && %i[green none].include?(checks)

    thread = pr_thread(pr["number"])
    return :review if thread[:adam_new]
    return nil if thread[:waiting]
    return :fix_ci if checks == :red
    return :continue if pr["isDraft"]

    nil # ready, waiting for review or checks
  end

  def check_state(pr)
    items = pr["statusCheckRollup"] || []
    return :none if items.empty?

    states = items.map { |c| (c["conclusion"].to_s.empty? ? (c["state"] || c["status"]) : c["conclusion"]).to_s.upcase }
    return :red if states.any? { |s| RED.include?(s) }
    return :pending if states.any? { |s| WAITING.include?(s) }

    :green
  end

  # Adam spoke after the agent's last act → :adam_new.
  # The agent's last act was talking rather than pushing → :waiting (it asked or parked).
  def pr_thread(number)
    data = gh_json("pr", "view", number.to_s, "-R", REPO, "--json", "comments,reviews,commits")
    inline = gh_json("api", "repos/#{REPO}/pulls/#{number}/comments?per_page=100")

    talk = data["comments"].map { |c| [time(c["createdAt"]), agent?(c["body"])] }
    talk += data["reviews"].reject { |r| r["state"] == "APPROVED" && r["body"].to_s.strip.empty? }
                           .map { |r| [time(r["submittedAt"]), agent?(r["body"])] }
    talk += inline.map { |c| [time(c["created_at"]), agent?(c["body"])] }

    adam = talk.reject(&:last).map(&:first).max
    agent_talk = talk.select(&:last).map(&:first).max
    last_push = data["commits"].map { |c| time(c["committedDate"]) }.max
    agent_act = [agent_talk, last_push].compact.max

    adam_new = adam && (agent_act.nil? || adam > agent_act)
    waiting = !adam_new && agent_talk && (last_push.nil? || agent_talk > last_push)
    { adam_new: adam_new, waiting: waiting }
  end

  def waiting_on_issue?(issue)
    comments = gh_json("issue", "view", issue["number"].to_s, "-R", REPO, "--json", "comments")["comments"]
    agent_last = comments.select { |c| agent?(c["body"]) }.map { |c| time(c["createdAt"]) }.max
    adam_last = comments.reject { |c| agent?(c["body"]) }.map { |c| time(c["createdAt"]) }.max
    agent_last && (adam_last.nil? || agent_last > adam_last)
  end

  # ── acting ────────────────────────────────────────────────────────────────

  def merge(pr)
    return log("would merge ##{pr['number']}") if @dry_run

    gh("pr", "merge", pr["number"].to_s, "-R", REPO, "--squash", "--delete-branch")
    log "merged ##{pr['number']}"
  end

  def start_agent(kind, subject)
    issue, pr = kind == :start ? [subject, nil] : [nil, subject]
    branch = pr ? pr["headRefName"] : "#{issue['number']}-#{slug(issue['title'])}"
    log "starting the agent: #{kind} on #{branch}"
    return if @dry_run

    ensure_sandbox_mounts_repository
    prepare_checkout
    if pr
      git("switch", "--quiet", "-C", branch, "origin/#{branch}")
    else
      git("switch", "--quiet", "-C", branch, "origin/#{default_branch}")
    end

    result = Remuda.agent(prompt(kind, issue: issue, pr: pr, branch: branch))
    log result.output.to_s
    raise "agent exited #{result.exit_code}" unless result.ok
  end

  # The agent must see the whole repository. Refuse rather than start it on a
  # partial mount.
  def ensure_sandbox_mounts_repository
    raise "run the tick through remuda to start the agent" unless defined?(Remuda::Sandbox)

    binds = Remuda::Sandbox.send(:binds, @root)
    return if binds.include?("#{@root}:/agent:rw")

    raise "remuda #{Remuda::VERSION} mounts only parts of this repository into the sandbox; " \
          "the agent would start without the code"
  end

  def prepare_checkout
    dirty = git("status", "--porcelain")
    raise "uncommitted changes from a previous session:\n#{dirty}" unless dirty.empty?

    git("fetch", "--quiet", "--prune", "origin")
    current = git("branch", "--show-current").strip
    unpushed = current.empty? ? "" : (git("log", "--oneline", "origin/#{current}..#{current}").strip rescue "")
    raise "unpushed commits on #{current}:\n#{unpushed}" unless unpushed.empty?
  end

  def prompt(kind, issue:, pr:, branch:)
    lines = [SITUATIONS.fetch(kind), ""]
    lines << "Repository: #{REPO}. It is your working directory, on branch `#{branch}`."
    lines << "Issue ##{issue['number']}: #{issue['title']} — #{issue['url']}" if issue
    lines << "Pull request ##{pr['number']}: #{pr['title']} — #{pr['url']}" if pr
    lines << ""
    lines << "Follow AGENTS.md in the repository. Stop when this situation is handled."
    lines.join("\n")
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  def labeled?(item) = (item["labels"] || []).any? { |l| l["name"] == LABEL }
  def agent?(body) = body.to_s.include?(MARKER)
  def time(value) = value && Time.parse(value)
  def slug(title) = title.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")[0, 40].sub(/-\z/, "")
  def log(message) = puts("[#{REPO}] #{message}")

  def default_branch
    @default_branch ||= gh("repo", "view", REPO, "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name").strip
  end

  def gh(*args)
    out, err, status = Open3.capture3("gh", *args)
    raise "gh #{args.take(2).join(' ')}: #{err.strip}" unless status.success?

    out
  end

  def gh_json(*args) = JSON.parse(gh(*args))

  def git(*args)
    out, err, status = Open3.capture3("git", "-C", @root, *args)
    raise "git #{args.first}: #{err.strip}" unless status.success?

    out
  end
end

CodingAgentTick.new(Dir.pwd, dry_run: ENV["DRY_RUN"] == "1").run
