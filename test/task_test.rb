# frozen_string_literal: true

require_relative "test_helper"

class TaskTest < Minitest::Test
  def test_new_task_has_defaults
    task = AgentOrchestra::Task.new("role" => "coder", "subject" => "Fix bug")
    assert_equal "coder", task.role
    assert_equal "Fix bug", task.subject
    assert_equal "pending", task.status
    assert_equal "P1", task.priority
    assert_equal "feature", task.type
    assert_equal 0, task.failure_count
    refute_nil task.id
  end

  def test_to_h_and_back
    task = AgentOrchestra::Task.new("role" => "qa", "subject" => "Review code", "priority" => "P0")
    hash = task.to_h
    restored = AgentOrchestra::Task.new(hash)
    assert_equal task.id, restored.id
    assert_equal task.role, restored.role
    assert_equal task.subject, restored.subject
    assert_equal task.priority, restored.priority
  end

  def test_ready
    task = AgentOrchestra::Task.new("subject" => "Test")
    assert_equal "pending", task.status
    task.ready!
    assert_equal "ready", task.status
  end

  def test_claim
    task = AgentOrchestra::Task.new("subject" => "Test")
    task.ready!
    task.claim!("coder-agent")
    assert_equal "claimed", task.status
    assert_equal "coder-agent", task.owner
    refute_nil task.claimed_at
  end

  def test_complete
    task = AgentOrchestra::Task.new("subject" => "Test")
    task.complete!("All done")
    assert_equal "complete", task.status
    assert_equal "All done", task.notes
    refute_nil task.completed_at
  end

  def test_fail_retries
    task = AgentOrchestra::Task.new("subject" => "Test")
    task.claim!("agent")

    task.fail!("Error 1")
    assert_equal "ready", task.status
    assert_equal 1, task.failure_count
    assert_nil task.owner

    task.claim!("agent")
    task.fail!("Error 2")
    assert_equal "ready", task.status
    assert_equal 2, task.failure_count

    task.claim!("agent")
    task.fail!("Error 3")
    assert_equal "failed", task.status
    assert_equal 3, task.failure_count
  end

  def test_cancel
    task = AgentOrchestra::Task.new("subject" => "Test")
    task.cancel!
    assert_equal "cancelled", task.status
  end

  def test_reset
    task = AgentOrchestra::Task.new("subject" => "Test")
    task.claim!("agent")
    task.reset!
    assert_equal "ready", task.status
    assert_nil task.owner
    assert_nil task.claimed_at
  end

  def test_priority_sort_key
    p0 = AgentOrchestra::Task.new("priority" => "P0")
    p1 = AgentOrchestra::Task.new("priority" => "P1")
    p2 = AgentOrchestra::Task.new("priority" => "P2")
    assert_operator p0.priority_sort_key, :<, p1.priority_sort_key
    assert_operator p1.priority_sort_key, :<, p2.priority_sort_key
  end
end
