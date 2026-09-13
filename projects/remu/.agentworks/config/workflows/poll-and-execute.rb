# poll-and-execute — the project agent's lane. Every 4 hours.
#
# Three triggers, computed here, before any agent is spawned: Respond (a fresh
# comment on one of my items that I did not write), Continue (my In Progress
# items), Start (my To Do items with no open blocker). Resume before start.
# Anything matching no trigger is not touched, and an idle run spawns nothing.
#
# Converted from poll-and-execute.yaml on 2026-08-24. Behaviour is unchanged
# except for the Start gate, which now runs forward and cross-project — see
# the comment above Trigger 3. bin/run and the scheduler both prefer this file
# over the .yaml beside it.

workflow "poll-and-execute" do
  require "time"

  # The only three values that differ between project workspaces. Provisioning
  # replaces them with literals; everything below is identical everywhere.
  project_id   = "47bbd93b-ee51-4c05-b4cb-d9fcfecdba06"
  me           = "ae4cc8f9-3a8c-43da-91b1-94cb80ab6205"
  project_name = "Remuda"

  closed = %w[completed cancelled]

  # Every Plane read in this file goes through here.
  #
  # try_tool alone is not enough: it swallows every failure alike, and a 429 is
  # not a 403. A 403 is permanent (we are not a member of that project) and the
  # caller should carry on without it. A 429 is transient — Planet rate-limits
  # per API key, and this workflow makes well over a hundred reads — and
  # swallowing it would silently drop a whole project's work items from a gate
  # that is supposed to fail closed. So: retry the 429, surface the give-up,
  # return nil for anything permanent and let each caller decide what nil means.
  read = ->(name, **args) {
    attempt = 0
    begin
      attempt += 1
      tool(name, **args)
    rescue Workflows::Script::StepError => e
      if e.message.include?("429") && attempt < 5
        sleep(10 * attempt)
        retry
      end
      log "#{name} gave up after #{attempt} attempt(s): #{e.message[0, 90]}"
      nil
    end
  }

  # A run that cannot reach the system of record must not start.
  read.call(:plane_get_me) or raise "Plane unreachable — refusing to run"

  # Every filter here is client-side: the API silently ignores assignee and
  # state query params (verified 2026-08-19 — the CE list endpoint reads no
  # filter params at all), so asking it to filter returns everything anyway.
  all_items = ((read.call(:plane_list_work_items,
                    project_id: project_id, per_page: 100, expand: "state") || {})["results"] || [])

  open_items = all_items.reject { |wi| closed.include?(wi.dig("state", "group")) }
  my_items   = open_items.select { |wi| (wi["assignees"] || []).include?(me) }
  log "#{all_items.size} item(s), #{open_items.size} open, #{my_items.size} mine"

  # ── Trigger 1: Respond ──────────────────────────────────────────────────
  # Fresh comments I did not write, on any of my open items. The 25h window
  # tolerates a missed run; the agent no-ops anything it already answered.

  cutoff = Time.now - (25 * 3600)

  fresh = my_items.flat_map { |wi|
    page = read.call(:plane_list_work_item_comments,
                    project_id: project_id, work_item_id: wi["id"], per_page: 100,
                    as: "comments:#{wi["sequence_id"] || wi["id"]}")
    (page || {})["results"] || []
  }.select { |c|
    c["created_by"] != me && Time.parse(c["created_at"]) > cutoff
  }

  log "Respond: #{fresh.size} fresh comment(s) not mine"
  log "Respond: capped at 5, #{fresh.size - 5} not handled this run" if fresh.size > 5

  respond_reports = fresh.first(5).map { |comment|
    try_agent <<~PROMPT, model: "opus", as: "respond:#{comment["issue"]}"
      You are the #{project_name} Project Agent. The Respond trigger fired:
      a comment on one of your work items, not authored by you, from the
      last day:
      #{comment.to_json}

      Load the `respond-to-comments` skill. The comment's `issue` field is
      the work item id; your project id is #{project_id}. Read ALL
      comments on that item before replying — if you already answered this
      one on a previous run, reply no-op and write nothing.

      You write comments only via `plane_create_comment` — no state,
      assignee, date, title, or description changes from this trigger.

      Plane is the system of record — if `plane_*` tools are unavailable,
      stop and say so.

      Reply with: work_item_id and a one-line summary of what you wrote,
      or no-op.
    PROMPT
  }.compact

  # ── Trigger 2: Continue ─────────────────────────────────────────────────
  # Ready For Review is also in the started group — exclude it by name. Items
  # sitting there are in Ops's court and match no trigger.

  in_progress = my_items.select { |wi|
    wi.dig("state", "group") == "started" && wi.dig("state", "name") != "Ready For Review"
  }

  log "Continue: #{in_progress.size} item(s) in progress"
  log "Continue: capped at 5, #{in_progress.size - 5} not handled this run" if in_progress.size > 5

  continue_reports = in_progress.first(5).map { |wi|
    try_agent <<~PROMPT, model: "opus", as: "continue:#{wi["sequence_id"] || wi["id"]}"
      You are the #{project_name} Project Agent. The Continue trigger
      fired: one of your work items in In Progress:
      #{wi.to_json}

      Load the `execute-work` skill and continue it: fresh full read first
      (comments included — answer anything unanswered before working), then
      execute toward a natural stopping point. End the session in exactly
      one of three ways per the skill: a session progress comment; done —
      completion report then the In Progress → Ready For Review transition;
      or blocked — an escalation comment, no state change.

      Plane is the system of record — if `plane_*` tools are unavailable,
      stop and say so.

      Reply with: work_item_id, the outcome (progress / done / blocked),
      and a one-line summary.
    PROMPT
  }.compact

  # ── Trigger 3: Start ────────────────────────────────────────────────────
  # Agents have no calendar and no capacity limit, so there is no date window
  # (Adam, 2026-08-22) — sequencing is the only thing that orders the work.
  #
  # The gate runs FORWARD, which the YAML dialect could not express: for each
  # of my To Do items, resolve every `blocked_by` edge and retrieve that
  # blocker by ITS OWN project id, then check its state. A blocker living in a
  # project this poll never lists is therefore still seen — that was the known
  # hole in the backwards version (OPS-130), and it is closed here.
  #
  # Fail closed on both halves: the relations call uses `tool`, so a hard
  # failure stops the run rather than gating on half the graph, and a blocker
  # that cannot be retrieved counts as OPEN rather than being skipped.

  todo = my_items.select { |wi| wi.dig("state", "group") == "unstarted" }

  # Blocker states are memoised: sibling items routinely share the same
  # blockers, and Planet answers 429 under a burst of per-edge reads. One read
  # per distinct blocker per run, not one per edge.
  blocker_state = {}

  blocker_open = ->(edge) {
    blocker_state.fetch(edge["issue_id"]) {
      found = read.call(:plane_retrieve_work_item,
                        project_id: edge["project_id"], work_item_id: edge["issue_id"],
                        expand: "state", fields: "id,name,sequence_id,state",
                        as: "blocker:#{edge["issue_id"][0, 8]}")
      blocker_state[edge["issue_id"]] = found.nil? || !closed.include?(found.dig("state", "group"))
    }
  }

  open_blockers = ->(wi) {
    rels = read.call(:plane_list_work_item_relations,
                     project_id: project_id, work_item_id: wi["id"],
                     as: "relations:#{wi["sequence_id"] || wi["id"]}")

    # Unreadable relations means an unknown graph. Refuse rather than gate on
    # half of it — a missing edge here releases an item that should be held.
    raise "relations unreadable for #{wi["id"]} — refusing to gate on a partial graph" if rels.nil?

    (rels["blocked_by"] || []).select { |edge| blocker_open.call(edge) }
  }

  gated = todo.map { |wi| [wi, open_blockers.call(wi)] }

  gated.reject { |_, blockers| blockers.empty? }.each { |wi, blockers|
    log "Start: holding #{wi["sequence_id"] || wi["id"]} — #{blockers.size} open blocker(s)"
  }

  startable = gated.select { |_, blockers| blockers.empty? }.map(&:first)

  log "Start: #{startable.size} of #{todo.size} To Do item(s) startable"
  log "Start: capped at 5, #{startable.size - 5} not handled this run" if startable.size > 5

  start_reports = startable.first(5).map { |wi|
    try_agent <<~PROMPT, model: "opus", as: "start:#{wi["sequence_id"] || wi["id"]}"
      You are the #{project_name} Project Agent. The Start trigger fired
      on one of your To Do work items:
      #{wi.to_json}

      WHAT WAS ALREADY CHECKED: every `blocked_by` edge on this item was
      resolved before you were woken — each blocker retrieved by its own
      project id, including any outside this project — and every one of them
      is completed or cancelled. A blocker that could not be retrieved would
      have held this item rather than released it.

      RE-VERIFY ANYWAY, from a fresh read: `plane_list_work_item_relations`
      on this item, every blocked_by edge resolved, each one completed or
      cancelled. If you find an open blocker this poll missed, do NOT start —
      that is the blocked outcome (escalation comment), never a workaround.
      Say which edge and why, once.

      Load the `execute-work` skill and start it. Gate holds:
      plan first if no plan comment exists (`plan-work-item`), starting
      comment, move To Do → In Progress, then execute toward a stopping
      point and end the session per the skill.

      Plane is the system of record — if `plane_*` tools are unavailable,
      stop and say so.

      Reply with: work_item_id, whether it started, the session outcome,
      and a one-line summary.
    PROMPT
  }.compact

  # ── Report ──────────────────────────────────────────────────────────────

  agent <<~PROMPT, model: "opus", as: "summarize"
    Summarize this poll-and-execute run for the #{project_name} project
    agent from the trigger reports below. Include counts per trigger
    INCLUDING zeros, every work item touched with its outcome, and
    anything flagged for Ops or Adam. Report only — write nothing.

    Respond: #{respond_reports.to_json}
    Continue: #{continue_reports.to_json}
    Start: #{start_reports.to_json}
  PROMPT
end
