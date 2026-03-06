# frozen_string_literal: true

require "yaml"

module AgentOrchestra
  class Config
    DEFAULTS = {
      "max_concurrent_agents" => 3,
      "poll_interval" => 60,
      "max_agent_runtime" => 3600,
      "state_dir" => ".orchestra",
      "agents_dir" => ".claude/agents",
      "roles" => {}
    }.freeze

    attr_reader :data, :path

    def initialize(data, path: nil)
      @data = DEFAULTS.merge(data)
      @path = path
    end

    def self.load(path = nil)
      path ||= find_config_file
      unless path && File.exist?(path)
        return new({}, path: nil)
      end
      data = YAML.load_file(path) || {}
      new(data, path: path)
    end

    def self.find_config_file
      dir = AgentOrchestra.root
      %w[agents.yml agent-orchestra.yml .orchestra.yml].each do |name|
        candidate = File.join(dir, name)
        return candidate if File.exist?(candidate)
      end
      nil
    end

    def max_concurrent_agents
      @data["max_concurrent_agents"]
    end

    def poll_interval
      @data["poll_interval"]
    end

    def max_agent_runtime
      @data["max_agent_runtime"]
    end

    def state_dir
      File.join(AgentOrchestra.root, @data["state_dir"])
    end

    def agents_dir
      File.join(AgentOrchestra.root, @data["agents_dir"])
    end

    def queue_file
      File.join(state_dir, "queue.yml")
    end

    def runs_dir
      File.join(state_dir, "runs")
    end

    def logs_dir
      File.join(state_dir, "logs")
    end

    def lock_file
      File.join(state_dir, "orchestrator.lock")
    end

    def roles
      @data["roles"] || {}
    end

    def role_config(role_name)
      roles[role_name.to_s] || {}
    end

    # Roles that should be serialized (max 1 concurrent)
    def serialized_roles
      roles.select { |_, v| v["serialize"] }.keys
    end

    # Roles that push to git (max 1 concurrent to prevent overlapping deploys)
    def git_pushing_roles
      roles.select { |_, v| v["git_push"] }.keys
    end
  end
end
