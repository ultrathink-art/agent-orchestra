# frozen_string_literal: true

require_relative "agent_orchestra/version"
require_relative "agent_orchestra/config"
require_relative "agent_orchestra/task"
require_relative "agent_orchestra/queue"
require_relative "agent_orchestra/orchestrator"
require_relative "agent_orchestra/worker"
require_relative "agent_orchestra/monitor"

module AgentOrchestra
  class Error < StandardError; end

  def self.root
    @root ||= detect_project_root
  end

  def self.root=(path)
    @root = path
  end

  def self.config
    @config ||= Config.load
  end

  def self.config=(cfg)
    @config = cfg
  end

  def self.reset!
    @root = nil
    @config = nil
  end

  private_class_method def self.detect_project_root
    dir = Dir.pwd
    loop do
      return dir if File.exist?(File.join(dir, "agents.yml"))
      return dir if File.exist?(File.join(dir, ".claude"))
      parent = File.dirname(dir)
      break if parent == dir
      dir = parent
    end
    Dir.pwd
  end
end
