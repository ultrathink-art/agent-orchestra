# frozen_string_literal: true

require "time"
require "securerandom"

module AgentOrchestra
  class Task
    STATUSES = %w[pending ready claimed in_progress complete failed cancelled].freeze
    PRIORITIES = %w[P0 P1 P2 P3].freeze

    attr_accessor :id, :role, :subject, :type, :priority, :status,
                  :owner, :notes, :brief, :workflow,
                  :created_at, :updated_at, :claimed_at, :completed_at,
                  :failure_count, :last_failure, :next_tasks, :blocked_by,
                  :agent_pid, :log_file

    def initialize(attrs = {})
      attrs = stringify_keys(attrs)
      @id = attrs["id"] || generate_id
      @role = attrs["role"] || "coder"
      @subject = attrs["subject"] || ""
      @type = attrs["type"] || "feature"
      @priority = attrs["priority"] || "P1"
      @status = attrs["status"] || "pending"
      @owner = attrs["owner"]
      @notes = attrs["notes"]
      @brief = attrs["brief"]
      @workflow = attrs["workflow"]
      @created_at = parse_time(attrs["created_at"]) || Time.now.utc
      @updated_at = parse_time(attrs["updated_at"]) || Time.now.utc
      @claimed_at = parse_time(attrs["claimed_at"])
      @completed_at = parse_time(attrs["completed_at"])
      @failure_count = attrs["failure_count"] || 0
      @last_failure = attrs["last_failure"]
      @next_tasks = attrs["next_tasks"]
      @blocked_by = attrs["blocked_by"] || []
      @agent_pid = attrs["agent_pid"]
      @log_file = attrs["log_file"]
    end

    def to_h
      {
        "id" => @id,
        "role" => @role,
        "subject" => @subject,
        "type" => @type,
        "priority" => @priority,
        "status" => @status,
        "owner" => @owner,
        "notes" => @notes,
        "brief" => @brief,
        "workflow" => @workflow,
        "created_at" => @created_at&.iso8601,
        "updated_at" => @updated_at&.iso8601,
        "claimed_at" => @claimed_at&.iso8601,
        "completed_at" => @completed_at&.iso8601,
        "failure_count" => @failure_count,
        "last_failure" => @last_failure,
        "next_tasks" => @next_tasks,
        "blocked_by" => @blocked_by,
        "agent_pid" => @agent_pid,
        "log_file" => @log_file
      }.compact
    end

    def ready!
      @status = "ready"
      @updated_at = Time.now.utc
    end

    def claim!(owner_name)
      @status = "claimed"
      @owner = owner_name
      @claimed_at = Time.now.utc
      @updated_at = Time.now.utc
    end

    def start!
      @status = "in_progress"
      @updated_at = Time.now.utc
    end

    def complete!(completion_notes = nil)
      @status = "complete"
      @notes = completion_notes if completion_notes
      @completed_at = Time.now.utc
      @updated_at = Time.now.utc
    end

    def fail!(reason = nil)
      @failure_count += 1
      @last_failure = reason
      @updated_at = Time.now.utc

      if @failure_count >= 3
        @status = "failed"
      else
        @status = "ready"
        @owner = nil
        @claimed_at = nil
      end
    end

    def cancel!
      @status = "cancelled"
      @updated_at = Time.now.utc
    end

    def reset!
      @status = "ready"
      @owner = nil
      @claimed_at = nil
      @agent_pid = nil
      @log_file = nil
      @updated_at = Time.now.utc
    end

    def priority_sort_key
      case @priority
      when "P0" then 0
      when "P1" then 1
      when "P2" then 2
      else 3
      end
    end

    private

    def generate_id
      seq = Time.now.strftime("%Y%m%d%H%M%S")
      "AO-#{seq}-#{SecureRandom.hex(2)}"
    end

    def parse_time(val)
      return nil if val.nil?
      return val if val.is_a?(Time)
      Time.parse(val.to_s)
    rescue ArgumentError
      nil
    end

    def stringify_keys(hash)
      hash.transform_keys(&:to_s)
    end
  end
end
