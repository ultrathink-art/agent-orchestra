# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("agent-orchestra-test")
    AgentOrchestra.root = @tmpdir
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
    AgentOrchestra.reset!
  end

  def test_defaults
    config = AgentOrchestra::Config.new({})
    assert_equal 3, config.max_concurrent_agents
    assert_equal 60, config.poll_interval
    assert_equal 3600, config.max_agent_runtime
  end

  def test_custom_values
    data = { "max_concurrent_agents" => 5, "poll_interval" => 30 }
    config = AgentOrchestra::Config.new(data)
    assert_equal 5, config.max_concurrent_agents
    assert_equal 30, config.poll_interval
  end

  def test_role_config
    data = {
      "roles" => {
        "coder" => { "git_push" => true },
        "qa" => { "serialize" => true }
      }
    }
    config = AgentOrchestra::Config.new(data)

    assert_equal [ "coder" ], config.git_pushing_roles
    assert_equal [ "qa" ], config.serialized_roles
  end

  def test_load_from_file
    config_path = File.join(@tmpdir, "agents.yml")
    File.write(config_path, YAML.dump(
      "max_concurrent_agents" => 10,
      "roles" => { "coder" => { "git_push" => true } }
    ))

    config = AgentOrchestra::Config.load(config_path)
    assert_equal 10, config.max_concurrent_agents
    assert_equal [ "coder" ], config.git_pushing_roles
  end

  def test_load_missing_file
    config = AgentOrchestra::Config.load("/nonexistent/agents.yml")
    assert_equal 3, config.max_concurrent_agents  # defaults
  end

  def test_state_dir_paths
    config = AgentOrchestra::Config.new({})
    assert config.queue_file.end_with?("queue.yml")
    assert config.runs_dir.end_with?("runs")
    assert config.logs_dir.end_with?("logs")
  end
end
