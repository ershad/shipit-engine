class PerformTaskJob < BackgroundJob
  queue_as :deploys

  def perform(task)
    @task = task
    unless @task.pending?
      logger.error("Task ##{@task.id} already in `#{@task.status}` state. Aborting.")
      return
    end

    @task.run!
    commands = Commands.for(@task)
    @task.acquire_git_cache_lock do
      capture commands.fetch
      capture commands.clone
    end
    capture commands.checkout(@task.until_commit)

    Bundler.with_clean_env do
      capture_all commands.install_dependencies
      capture_all commands.perform
    end
    @task.complete!
  rescue Command::Error => error
    @task.report_failure!(error)
  rescue StandardError => error
    @task.report_error!(error)
  ensure
    @task.clear_working_directory
  end

  def capture_all(commands)
    commands.map { |c| capture(c) }
  end

  def capture(command)
    command.start
    @task.write("$ #{command}\npid: #{command.pid}\n")
    @task.pid = command.pid
    command.stream! do |line|
      @task.write(line)
    end
    @task.write("\n")
  end
end
