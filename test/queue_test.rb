# frozen_string_literal: true

require_relative "test_helper"

class QueueTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("agent-orchestra-test")
    AgentOrchestra.root = @tmpdir

    # Minimal config pointing to tmpdir
    config_data = { "state_dir" => File.join(@tmpdir, ".orchestra") }
    AgentOrchestra.config = AgentOrchestra::Config.new(config_data)

    @queue = AgentOrchestra::Queue.new
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
    AgentOrchestra.reset!
  end

  def test_add_and_find
    task = AgentOrchestra::Task.new("id" => "T-1", "role" => "coder", "subject" => "Fix bug")
    @queue.add(task)

    found = @queue.find("T-1")
    refute_nil found
    assert_equal "coder", found.role
    assert_equal "Fix bug", found.subject
  end

  def test_list_all
    @queue.add(AgentOrchestra::Task.new("id" => "T-1", "subject" => "Task 1"))
    @queue.add(AgentOrchestra::Task.new("id" => "T-2", "subject" => "Task 2"))

    tasks = @queue.all
    assert_equal 2, tasks.size
  end

  def test_list_by_status
    @queue.add(AgentOrchestra::Task.new("id" => "T-1", "status" => "ready"))
    @queue.add(AgentOrchestra::Task.new("id" => "T-2", "status" => "pending"))
    @queue.add(AgentOrchestra::Task.new("id" => "T-3", "status" => "ready"))

    ready = @queue.list(status: "ready")
    assert_equal 2, ready.size
  end

  def test_list_by_role
    @queue.add(AgentOrchestra::Task.new("id" => "T-1", "role" => "coder"))
    @queue.add(AgentOrchestra::Task.new("id" => "T-2", "role" => "qa"))

    coders = @queue.list(role: "coder")
    assert_equal 1, coders.size
    assert_equal "coder", coders.first.role
  end

  def test_ready_tasks_sorted_by_priority
    @queue.add(AgentOrchestra::Task.new("id" => "T-1", "status" => "ready", "priority" => "P2"))
    @queue.add(AgentOrchestra::Task.new("id" => "T-2", "status" => "ready", "priority" => "P0"))
    @queue.add(AgentOrchestra::Task.new("id" => "T-3", "status" => "ready", "priority" => "P1"))

    ready = @queue.ready_tasks
    assert_equal 3, ready.size
    assert_equal "T-2", ready[0].id  # P0 first
    assert_equal "T-3", ready[1].id  # P1 second
    assert_equal "T-1", ready[2].id  # P2 last
  end

  def test_ready_tasks_excludes_blocked
    @queue.add(AgentOrchestra::Task.new("id" => "T-1", "status" => "ready"))
    @queue.add(AgentOrchestra::Task.new("id" => "T-2", "status" => "ready", "blocked_by" => [ "T-99" ]))

    ready = @queue.ready_tasks
    assert_equal 1, ready.size
    assert_equal "T-1", ready.first.id
  end

  def test_update
    task = AgentOrchestra::Task.new("id" => "T-1", "subject" => "Original")
    @queue.add(task)

    task.subject = "Updated"
    @queue.update(task)

    found = @queue.find("T-1")
    assert_equal "Updated", found.subject
  end

  def test_remove
    @queue.add(AgentOrchestra::Task.new("id" => "T-1"))
    @queue.add(AgentOrchestra::Task.new("id" => "T-2"))

    @queue.remove("T-1")
    assert_nil @queue.find("T-1")
    refute_nil @queue.find("T-2")
  end

  def test_status_counts
    @queue.add(AgentOrchestra::Task.new("id" => "T-1", "status" => "ready"))
    @queue.add(AgentOrchestra::Task.new("id" => "T-2", "status" => "ready"))
    @queue.add(AgentOrchestra::Task.new("id" => "T-3", "status" => "complete"))

    counts = @queue.status_counts
    assert_equal 2, counts["ready"]
    assert_equal 1, counts["complete"]
  end

  def test_next_id_increments
    id1 = @queue.next_id
    id2 = @queue.next_id
    id3 = @queue.next_id

    assert_equal "AO-1", id1
    assert_equal "AO-2", id2
    assert_equal "AO-3", id3
  end
end
