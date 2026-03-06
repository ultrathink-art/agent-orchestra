# frozen_string_literal: true

require "fileutils"
require "set"

module AgentOrchestra
  class Orchestrator
    def initialize(dry_run: false)
      @dry_run = dry_run
      @config = AgentOrchestra.config
      @queue = Queue.new
      @failed_this_cycle = Set.new
      ensure_directories
    end

    def run_once
      log "Starting orchestrator run"
      @failed_this_cycle = Set.new

      # Check completed/dead agents
      check_agents

      # Spawn new agents for ready tasks
      ready = @queue.ready_tasks
      ready.reject! { |t| @failed_this_cycle.include?(t.id) }
      running_count = count_running

      log "Queue: #{ready.size} ready, #{running_count} running (max: #{@config.max_concurrent_agents})"

      if ready.any? && running_count < @config.max_concurrent_agents
        slots = @config.max_concurrent_agents - running_count
        spawned = 0
        ready.each do |task|
          break if spawned >= slots
          spawned += 1 if spawn_agent(task)
        end
      end

      log "Orchestrator run complete"
    end

    def run_daemon
      log "Starting daemon (poll every #{@config.poll_interval}s)"
      acquire_lock

      trap("INT") { release_lock; exit }
      trap("TERM") { release_lock; exit }

      loop do
        begin
          run_once
        rescue StandardError => e
          log "ERROR: #{e.message}"
          log e.backtrace.first(5).join("\n") if e.backtrace
        end
        sleep @config.poll_interval
      end
    ensure
      release_lock
    end

    def show_status
      puts "AGENT ORCHESTRA STATUS"
      puts "=" * 60

      running = list_running
      puts "\nRUNNING AGENTS: #{running.size}"
      puts "-" * 40

      if running.empty?
        puts "  (none)"
      else
        running.each do |agent|
          duration = Time.now - agent[:started_at]
          puts "  #{agent[:task_id]} (#{agent[:role]})"
          puts "    PID: #{agent[:pid]}, Running: #{format_duration(duration)}"
        end
      end

      show_queue_summary
    end

    private

    def show_queue_summary
      tasks = @queue.all
      statuses = %w[ready pending claimed in_progress complete failed]

      statuses.each do |status|
        matching = tasks.select { |t| t.status == status }
        next if matching.empty?

        puts "\n#{status.upcase}: #{matching.size}"
        puts "-" * 40
        matching.first(5).each do |t|
          puts "  #{t.id} (#{t.role}) [#{t.priority}] #{t.subject}"
        end
        puts "  ... and #{matching.size - 5} more" if matching.size > 5
      end
    end

    def check_agents
      list_running # triggers dead agent cleanup
    end

    def spawn_agent(task)
      role = task.role

      # Check agent definition exists
      agent_file = File.join(@config.agents_dir, "#{role}.md")
      unless File.exist?(agent_file)
        log "WARN: No agent definition for '#{role}' at #{agent_file}, skipping #{task.id}"
        return false
      end

      # Enforce serialization for git-pushing and serialized roles
      if @config.git_pushing_roles.include?(role) || @config.serialized_roles.include?(role)
        running_same = list_running.count { |a| a[:role] == role }
        if running_same > 0
          log "Skipping #{task.id} — already 1 #{role} agent running"
          return false
        end
      end

      log "Spawning #{role} agent for #{task.id}: #{task.subject}"
      return true if @dry_run

      timestamp = Time.now.strftime("%Y%m%d-%H%M%S")
      log_file = File.join(@config.logs_dir, "#{task.id}-#{timestamp}.log")
      state_file = File.join(@config.runs_dir, "#{task.id}.running")
      completion_file = File.join(@config.runs_dir, "#{task.id}.complete")

      task.claim!("orchestrator")
      @queue.update(task)

      begin
        pid = spawn_claude(task, role, log_file, state_file, completion_file)
      rescue StandardError => e
        log "ERROR spawning agent for #{task.id}: #{e.message}"
        task.reset!
        @queue.update(task)
        return false
      end

      state = {
        "task_id" => task.id,
        "role" => role,
        "pid" => pid,
        "started_at" => Time.now.utc.iso8601,
        "log_file" => log_file,
        "subject" => task.subject
      }
      File.write(state_file, YAML.dump(state))

      task.agent_pid = pid
      task.log_file = log_file
      task.start!
      @queue.update(task)

      log "Started agent PID #{pid} for #{task.id}"
      true
    end

    def spawn_claude(task, role, log_file, state_file, completion_file)
      append_prompt = build_append_prompt(task)
      task_prompt = build_task_prompt(task)

      # Build worker command
      worker_bin = File.join(File.dirname(File.dirname(__FILE__)), "..", "bin", "agent-worker")

      env = {
        "AGENT_TASK_ID" => task.id,
        "AGENT_ROLE" => role,
        "AGENT_LOG_FILE" => log_file,
        "AGENT_STATE_FILE" => state_file,
        "AGENT_COMPLETION_FILE" => completion_file,
        "AGENT_BRIEF" => task.brief || "",
        "AGENT_APPEND_PROMPT" => append_prompt,
        "AGENT_TASK_PROMPT" => task_prompt,
        "AGENT_ORCHESTRA_ROOT" => AgentOrchestra.root,
        "CLAUDECODE" => nil
      }

      pid = Process.spawn(
        env,
        RbConfig.ruby, worker_bin,
        chdir: AgentOrchestra.root,
        out: log_file,
        err: log_file,
        unsetenv_others: false
      )

      Process.detach(pid)
      pid
    end

    def build_append_prompt(task)
      <<~PROMPT
        ---
        # AUTONOMOUS TASK CONTEXT

        You are running as an autonomous agent spawned by Agent Orchestra.
        You must complete the assigned task and report results.

        ## Task Details
        - ID: #{task.id}
        - Subject: #{task.subject}
        - Type: #{task.type}
        - Priority: #{task.priority}
        - Workflow: #{task.workflow || "default"}

        ## Instructions

        1. Read and understand the task requirements
        2. Complete the work autonomously
        3. Document what you did in your output
        4. If you need human review, say "NEEDS_REVIEW:" followed by reason
        5. If you encounter a blocking issue, say "BLOCKED:" followed by reason

        ## Completion Protocol

        When done, output one of:
        - "TASK_COMPLETE: <summary of what was done>"
        - "NEEDS_REVIEW: <what needs review and why>"
        - "BLOCKED: <what is blocking and what help is needed>"
      PROMPT
    end

    def build_task_prompt(task)
      prompt = "You have been assigned task #{task.id}: #{task.subject}\n\n"
      prompt += "When finished, output TASK_COMPLETE, NEEDS_REVIEW, or BLOCKED as described."
      prompt
    end

    def count_running
      list_running.size
    end

    def list_running
      running = []
      Dir.glob(File.join(@config.runs_dir, "*.running")).each do |state_file|
        begin
          state = YAML.load_file(state_file)
          pid = state["pid"]

          if process_alive?(pid)
            started_at = Time.parse(state["started_at"])
            runtime = Time.now - started_at

            if runtime > @config.max_agent_runtime
              handle_stuck_agent(state_file, state, runtime)
            else
              running << {
                task_id: state["task_id"],
                role: state["role"],
                pid: pid,
                started_at: started_at,
                log_file: state["log_file"]
              }
            end
          else
            handle_dead_agent(state_file, state)
          end
        rescue StandardError => e
          log "Error reading #{state_file}: #{e.message}"
        end
      end
      running
    end

    def handle_stuck_agent(state_file, state, runtime)
      task_id = state["task_id"]
      pid = state["pid"]
      minutes = (runtime / 60).round

      log "Agent #{task_id} stuck (PID #{pid}, #{minutes}m) — terminating"
      @failed_this_cycle.add(task_id)

      begin
        Process.kill("TERM", pid)
        sleep 2
        Process.kill("KILL", pid) if process_alive?(pid)
      rescue Errno::ESRCH, Errno::EPERM => e
        log "Could not kill: #{e.message}"
      end

      task = @queue.find(task_id)
      task&.fail!("Agent timed out after #{minutes}m")
      @queue.update(task) if task

      FileUtils.rm_f(state_file)
    end

    def handle_dead_agent(state_file, state)
      task_id = state["task_id"]
      log "Agent for #{task_id} finished (PID #{state["pid"]})"
      @failed_this_cycle.add(task_id)

      completion_file = state_file.sub(".running", ".complete")

      if File.exist?(completion_file)
        process_completion(task_id, completion_file)
        FileUtils.rm_f(completion_file)
      else
        parse_completion_from_log(task_id, state["log_file"])
      end

      FileUtils.rm_f(state_file)
    end

    def process_completion(task_id, completion_file)
      data = YAML.load_file(completion_file)
      result = data["result"] || "complete"
      notes = data["notes"]

      task = @queue.find(task_id)
      return unless task

      case result
      when "completed", "complete"
        task.complete!(notes)
        spawn_next_tasks(task)
      when "blocked"
        task.fail!("BLOCKED: #{notes}")
      when "failed"
        task.fail!(notes)
      else
        task.complete!(notes)
        spawn_next_tasks(task)
      end

      @queue.update(task)
      log "Task #{task_id} → #{task.status}: #{notes}"
    end

    def parse_completion_from_log(task_id, log_file)
      task = @queue.find(task_id)
      return unless task

      unless log_file && File.exist?(log_file)
        task.fail!("No log file found")
        @queue.update(task)
        return
      end

      content = File.read(log_file)
      log_size = File.size(log_file)

      # 0-byte log = agent crashed before executing
      if log_size == 0
        log "ERROR: #{task_id} produced 0-byte log — marking failed"
        task.fail!("Agent crashed — 0-byte log")
        @queue.update(task)
        return
      end

      if content.include?("TASK_COMPLETE")
        match = content.match(/TASK_COMPLETE:\s*(.+?)(?:\n|$)/m)
        summary = match ? match[1].strip : "Task completed"
        task.complete!(summary)
        spawn_next_tasks(task)
      elsif content.include?("BLOCKED:")
        match = content.match(/BLOCKED:\s*(.+?)(?:\n|$)/m)
        reason = match ? match[1].strip : "Task blocked"
        task.fail!("BLOCKED: #{reason}")
      elsif content.include?("NEEDS_REVIEW:")
        match = content.match(/NEEDS_REVIEW:\s*(.+?)(?:\n|$)/m)
        reason = match ? match[1].strip : "Review requested"
        task.complete!(reason)
        spawn_next_tasks(task)
      else
        # Non-zero log, no signal — auto-complete
        log "No completion signal for #{task_id} — auto-completing"
        task.complete!("Auto-completed (no completion signal)")
        spawn_next_tasks(task)
      end

      @queue.update(task)
    end

    def spawn_next_tasks(parent_task)
      return unless parent_task.next_tasks.is_a?(Array)

      parent_task.next_tasks.each do |nt|
        nt = nt.transform_keys(&:to_s) if nt.respond_to?(:transform_keys)
        subject = (nt["subject"] || "").gsub("{{parent_task_id}}", parent_task.id)
        child = Task.new(
          "id" => @queue.next_id,
          "role" => nt["role"],
          "subject" => subject,
          "priority" => nt["priority"] || parent_task.priority,
          "status" => "ready"
        )
        @queue.add(child)
        log "Spawned child task #{child.id} (#{child.role}): #{child.subject}"
      end
    end

    def process_alive?(pid)
      return false unless pid
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def ensure_directories
      FileUtils.mkdir_p(@config.runs_dir)
      FileUtils.mkdir_p(@config.logs_dir)
      FileUtils.mkdir_p(File.dirname(@config.lock_file))
    end

    def acquire_lock
      if File.exist?(@config.lock_file)
        pid = File.read(@config.lock_file).to_i
        if process_alive?(pid)
          abort "Orchestrator already running (PID #{pid})"
        end
      end
      File.write(@config.lock_file, Process.pid.to_s)
    end

    def release_lock
      FileUtils.rm_f(@config.lock_file)
    end

    def format_duration(seconds)
      if seconds < 60
        "#{seconds.to_i}s"
      elsif seconds < 3600
        "#{(seconds / 60).to_i}m"
      else
        "#{(seconds / 3600).to_i}h #{((seconds % 3600) / 60).to_i}m"
      end
    end

    def log(message)
      timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S")
      puts "[#{timestamp}] #{message}"
    end
  end
end
