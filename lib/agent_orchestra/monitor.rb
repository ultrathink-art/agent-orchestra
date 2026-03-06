# frozen_string_literal: true

require "yaml"
require "fileutils"

module AgentOrchestra
  class Monitor
    STALE_MINUTES = 60
    ORPHAN_MINUTES = 5

    def initialize
      @config = AgentOrchestra.config
      @queue = Queue.new
    end

    def show_status
      puts "Queue Status"
      puts "=" * 40

      counts = @queue.status_counts
      total = counts.values.sum

      %w[ready pending claimed in_progress complete failed cancelled].each do |s|
        count = counts[s] || 0
        next if count == 0
        printf "  %-15s %d\n", s, count
      end
      puts "-" * 40
      printf "  %-15s %d\n", "total", total
      puts

      stale = find_stale_tasks
      if stale.any?
        puts "WARNING: #{stale.size} stale claimed task(s) detected"
      else
        puts "No stale tasks"
      end
    end

    def check_health
      counts = @queue.status_counts
      stale = find_stale_tasks
      issues = []

      if stale.size > 10
        issues << "Too many stale tasks: #{stale.size}"
      end

      unless stale.empty?
        reset_stale_tasks(stale)
      end

      if issues.empty?
        puts "Health check passed"
        puts "  Ready: #{counts["ready"] || 0}, In progress: #{counts["in_progress"] || 0}, Stale: #{stale.size}"
        { healthy: true }
      else
        puts "Health issues: #{issues.join("; ")}"
        { healthy: false, issues: issues }
      end
    end

    def find_stale_tasks
      stale = []
      runs_dir = @config.runs_dir
      return stale unless Dir.exist?(runs_dir)

      Dir.glob(File.join(runs_dir, "*.running")).each do |state_file|
        begin
          state = YAML.load_file(state_file)
          pid = state["pid"]
          task_id = state["task_id"]
          started = Time.parse(state["started_at"])
          age_minutes = (Time.now - started) / 60

          alive = begin
            Process.kill(0, pid)
            true
          rescue Errno::ESRCH, Errno::EPERM
            false
          end

          if !alive && age_minutes > ORPHAN_MINUTES
            stale << { id: task_id, age_minutes: age_minutes.round, reason: "process dead" }
          elsif alive && age_minutes > STALE_MINUTES
            stale << { id: task_id, age_minutes: age_minutes.round, reason: "exceeded runtime" }
          end
        rescue StandardError
          next
        end
      end

      stale
    end

    def reset_stale_tasks(stale_tasks)
      return if stale_tasks.empty?

      puts "Found #{stale_tasks.size} stale task(s):"
      stale_tasks.each do |t|
        puts "  #{t[:id]} — #{t[:age_minutes]}m ago, #{t[:reason]}"
      end

      stale_tasks.each do |t|
        task = @queue.find(t[:id])
        next unless task

        # Kill process if alive
        state_file = File.join(@config.runs_dir, "#{t[:id]}.running")
        if File.exist?(state_file)
          state = YAML.load_file(state_file)
          pid = state["pid"]
          begin
            Process.kill("TERM", pid)
            sleep 1
            Process.kill("KILL", pid) if begin
              Process.kill(0, pid)
              true
            rescue Errno::ESRCH
              false
            end
          rescue Errno::ESRCH, Errno::EPERM
            # already dead
          end
          FileUtils.rm_f(state_file)
        end

        task.reset!
        @queue.update(task)
        puts "  #{t[:id]}: Reset to ready"
      end
    end
  end
end
