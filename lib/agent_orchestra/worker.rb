# frozen_string_literal: true

require "yaml"
require "time"
require "open3"

module AgentOrchestra
  class Worker
    CLAUDE_TIMEOUT_SECONDS = 3600

    def initialize
      @task_id = ENV["AGENT_TASK_ID"]
      @role = ENV["AGENT_ROLE"] || "coder"
      @log_file = ENV["AGENT_LOG_FILE"]
      @state_file = ENV["AGENT_STATE_FILE"]
      @completion_file = ENV["AGENT_COMPLETION_FILE"]
      @brief_path = ENV["AGENT_BRIEF"]
      @append_prompt = ENV["AGENT_APPEND_PROMPT"]
      @task_prompt = ENV["AGENT_TASK_PROMPT"]
      @project_dir = ENV["AGENT_ORCHESTRA_ROOT"] || Dir.pwd
      @blocked = false
      @usage_limit_error = false

      validate_environment
    end

    def run
      log "Agent worker starting for #{@task_id} (#{@role})"

      append_prompt = @append_prompt || build_default_prompt
      task_prompt = @task_prompt || "Complete task #{@task_id}."

      log "Running Claude Code agent..."

      success = run_claude(append_prompt, task_prompt)

      if success && @blocked
        log "Agent reported BLOCKED"
        report_completion("blocked", "Agent reported blocking issue")
        1
      elsif success
        log "Agent completed successfully"
        report_completion("completed", "Task completed by #{@role} agent")
        0
      else
        reason = @usage_limit_error ? "Claude usage/rate limit exceeded" : "Claude agent exited with error"
        log "Agent failed: #{reason}"
        report_completion("failed", reason)
        1
      end
    rescue StandardError => e
      log "ERROR: #{e.message}"
      log e.backtrace.first(10).join("\n") if e.backtrace
      report_completion("failed", "Worker error: #{e.message}")
      1
    end

    private

    def validate_environment
      abort "AGENT_TASK_ID not set" unless @task_id
      abort "AGENT_COMPLETION_FILE not set" unless @completion_file
    end

    def build_default_prompt
      <<~PROMPT
        ---
        # AUTONOMOUS TASK CONTEXT

        You are running as an autonomous agent.
        Complete the assigned task and report results.

        ## Task: #{@task_id}

        Output one of when done:
        - "TASK_COMPLETE: <summary>"
        - "NEEDS_REVIEW: <reason>"
        - "BLOCKED: <reason>"
      PROMPT
    end

    def run_claude(append_prompt, task_prompt)
      cmd = [
        "claude",
        "--agent", @role,
        "--print",
        "--dangerously-skip-permissions",
        "--append-system-prompt", append_prompt,
        task_prompt
      ]

      log "Executing: claude --agent #{@role} --print ... (timeout: #{CLAUDE_TIMEOUT_SECONDS}s)"

      stdin_r, stdin_w = IO.pipe
      stdout_r, stdout_w = IO.pipe
      stderr_r, stderr_w = IO.pipe
      stdin_w.close

      pid = Process.spawn(*cmd, chdir: @project_dir, in: stdin_r, out: stdout_w, err: stderr_w)
      stdin_r.close
      stdout_w.close
      stderr_w.close

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + CLAUDE_TIMEOUT_SECONDS
      wait_thread = Thread.new { Process.waitpid2(pid) }

      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = wait_thread.join([ remaining, 0 ].max)

      if result.nil?
        log "ERROR: Claude timed out after #{CLAUDE_TIMEOUT_SECONDS}s — killing PID #{pid}"
        Process.kill("TERM", pid) rescue nil
        sleep 2
        Process.kill("KILL", pid) rescue nil
        wait_thread.join(5)
        stdout_r.close rescue nil
        stderr_r.close rescue nil
        return false
      end

      _, process_status = result.value
      stdout = stdout_r.read
      stderr = stderr_r.read
      stdout_r.close
      stderr_r.close

      log stdout unless stdout.empty?
      log stderr unless stderr.empty?

      combined = "#{stdout}\n#{stderr}"
      if combined.match?(/out of extra usage|rate limit|quota exceeded|billing|hit your limit/i)
        @usage_limit_error = true
        if stdout.include?("TASK_COMPLETE")
          log "Rate limit hit BUT TASK_COMPLETE found — treating as success"
          parse_output(stdout)
          return true
        end
        return false
      end

      parse_output(stdout)
      process_status.success?
    rescue StandardError => e
      log "ERROR: Failed to run Claude: #{e.message}"
      Process.kill("KILL", pid) rescue nil if defined?(pid) && pid
      false
    end

    def parse_output(output)
      output = output.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
      @blocked = true if output.include?("BLOCKED:")
    end

    def report_completion(result, notes)
      completion = {
        "task_id" => @task_id,
        "role" => @role,
        "result" => result,
        "notes" => notes,
        "completed_at" => Time.now.utc.iso8601
      }
      File.write(@completion_file, YAML.dump(completion))
      log "Completion: #{result}"
    end

    def log(message)
      timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S")
      puts "[#{timestamp}] [Worker #{@task_id}] #{message}"
    end
  end
end
