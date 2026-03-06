# frozen_string_literal: true

require "yaml"
require "fileutils"

module AgentOrchestra
  class Queue
    attr_reader :path

    def initialize(path = nil)
      @path = path || AgentOrchestra.config.queue_file
      ensure_file
    end

    # Add a new task to the queue
    def add(task)
      with_lock do
        tasks = load_all
        tasks << task
        save_all(tasks)
      end
      task
    end

    # Find task by ID
    def find(id)
      load_all.find { |t| t.id == id }
    end

    # All tasks matching optional filters
    def list(status: nil, role: nil)
      tasks = load_all
      tasks = tasks.select { |t| t.status == status } if status
      tasks = tasks.select { |t| t.role == role } if role
      tasks
    end

    # Tasks ready to be picked up by orchestrator
    def ready_tasks
      tasks = load_all
      completed_ids = tasks.select { |t| t.status == "complete" }.map(&:id)

      tasks.select { |t|
        t.status == "ready" && !blocked?(t, completed_ids)
      }.sort_by(&:priority_sort_key)
    end

    # Update a task in place
    def update(task)
      with_lock do
        tasks = load_all
        idx = tasks.index { |t| t.id == task.id }
        return nil unless idx
        tasks[idx] = task
        save_all(tasks)
      end
      task
    end

    # Remove a task
    def remove(id)
      with_lock do
        tasks = load_all
        removed = tasks.reject! { |t| t.id == id }
        save_all(tasks) if removed
      end
    end

    # Status summary counts
    def status_counts
      counts = Hash.new(0)
      load_all.each { |t| counts[t.status] += 1 }
      counts
    end

    # All tasks
    def all
      load_all
    end

    # Next sequential ID (AO-NNN format using counter)
    def next_id
      with_lock do
        counter_file = File.join(File.dirname(@path), ".counter")
        current = File.exist?(counter_file) ? File.read(counter_file).strip.to_i : 0
        next_val = current + 1
        File.write(counter_file, next_val.to_s)
        "AO-#{next_val}"
      end
    end

    private

    def blocked?(task, completed_ids)
      return false if task.blocked_by.nil? || task.blocked_by.empty?
      task.blocked_by.any? { |id| !completed_ids.include?(id) }
    end

    def load_all
      data = YAML.load_file(@path) rescue nil
      return [] unless data.is_a?(Array)
      data.map { |h| Task.new(h) }
    end

    def save_all(tasks)
      File.write(@path, YAML.dump(tasks.map(&:to_h)))
    end

    def ensure_file
      dir = File.dirname(@path)
      FileUtils.mkdir_p(dir)
      File.write(@path, YAML.dump([])) unless File.exist?(@path)
    end

    def with_lock(&block)
      lock_path = "#{@path}.lock"
      FileUtils.mkdir_p(File.dirname(lock_path))
      File.open(lock_path, File::RDWR | File::CREAT) do |f|
        f.flock(File::LOCK_EX)
        yield
      ensure
        f.flock(File::LOCK_UN)
      end
    end
  end
end
