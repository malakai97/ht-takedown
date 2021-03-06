require_relative "take_down/grepper"
require_relative "take_down/loader"
require_relative "take_down/pruner"
require_relative "take_down/queryer"
require_relative "take_down/reporter"
require "sqlite3"
require "yaml"
require "pathname"

module TakeDown

  def self.path
    @path ||= Pathname.new(__FILE__).parent.parent.realdirpath.to_s
  end

  # Get the paths described by the job file.
  # @param job [String] The path to the job file.
  # @return [String, String, String, String] The filepaths for the
  #   progress tracker, list of apps to search for, the output dir,
  #   and the directory containing the access logs; respectively.
  def self.get_paths(job)
    app_list_file = File.join(path, "data/app_list.yml" )
    output_dir = File.join(job["output_dir"], job["ticket"])
    access_log_dir = File.join(output_dir, "grepped_access_logs")
    progress_file = File.join(output_dir, "progress.yml")
    return progress_file, app_list_file, output_dir, access_log_dir
  end
  
  
  # Get the list of directories within the parent dir,
  # removing '.', '..', and the skip directories.  Includes
  # hidden directories.
  # @param parent_dir [String] The parent directory path.
  # @param skip_dirs [Array<String>] List of directory *names* 
  #   (not paths) that should not be included.
  # @param sub_dir_path [String] Path to be appended under the
  #   discovered dirs, if any.  Ex. "logs"
  # @return [Array<String>] The directory *paths*..
  def self.get_log_dirs(parent_dir, skip_dirs, sub_dir_path)
    # Get the folders we need
    log_dirs = Dir.entries(parent_dir).select { |entry| File.directory? File.join(parent_dir, entry )}
    log_dirs -= [".", ".."]
    log_dirs -= (skip_dirs || [])
    return log_dirs.map { |log_dir| File.join(log_dir, sub_dir_path)}
  end
  
  
  # Get the hash result of loading the yaml for the application list 
  # and the progress file.
  # @param app_list_file [String] Path to the application list file
  # @param progress_file [String] Path to the progress file.  If it
  #   does not exist, it is created.
  # @return [Hash, Hash] App list and progress, respectively.
  def self.get_configs(app_list_file, progress_file)
    app_list = YAML.load_file(app_list_file)[:apps]
    `touch #{progress_file}`
    progress = YAML.load_file(progress_file)
    return app_list, progress
  end
  
  
  # Do everything
  # @param job_file [String] Path of the job file.
  def self.execute(job_file)
    # open job file
    job = YAML.load_file(job_file)

    # get paths, make dirs
    progress_file, app_list_file, output_dir, access_log_dir = get_paths(job)
    `mkdir -p #{output_dir}`
    `mkdir -p #{access_log_dir}`
    
    # open configs
    app_list, progress = get_configs(app_list_file, progress_file)
    
    # dirs to read from, dirs to create
    log_dirs = get_log_dirs(job["parent_dir"], job["skip_dirs"], job["sub_dir_path"])
    input_output_map = {}
    log_dirs.each do |relative_dir|
      input_dir = File.join job["parent_dir"], relative_dir
      input_output_map[input_dir] = File.join(access_log_dir, "#{relative_dir.sub('/', '-')}-access.log")
    end
    
    
    # grep!
    unless progress[:grepper]
      grepper = Grepper.new(app_list, job["volumes"].keys)
      input_output_map.each do |input_dir, output_file|
        grepper.grep!(input_dir, output_file)
      end
      progress[:grepper] = true
      File.write(progress_file, progress.to_yaml)
    end
    
    
    # Load into sql
    db_path = File.join output_dir, "results.db"
    if progress[:loader]
      db = SQLite3::Database.new @db_path
    else
      `rm -f #{db_path}`
      loader = Loader.new(db_path)
      db = loader.get_db
      input_output_map.values.each do |grepped_access_log|
        loader.load!(grepped_access_log)
      end
      progress[:loader] = true
      File.write(progress_file, progress.to_yaml)
    end


    # Prune things we don't want
    unless progress[:pruner]
      pruner = Pruner.new(db)
      pruner.prune!(job["volumes"])
      progress[:pruner] = true
      File.write(progress_file, progress.to_yaml)
    end

    
    # Gather report data
    unless progress[:report]
      reporter = Reporter.new(Queryer.new(db))
      job["volumes"].keys.each do |volume_id|
        job["volumes"][volume_id].each do |time_window|
          start_time = time_window["start"]
          end_time = time_window["end"]
          reporter.add_volume_to_report(volume_id, start_time, end_time)
        end
      end
      File.write(File.join(output_dir, "report.txt"), reporter.report)
      progress[:report] = true
      File.write(progress_file, progress.to_yaml)
    end
    
  end
  
  
  
end

