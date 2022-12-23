module Muzik
  class Client
    include Appscript

    INDEX_FIELDS_CLOUD = %i[artist title id updated_at].freeze
    INDEX_FIELDS_LOCAL = %i[artist title location id updated_at].freeze
    TRASH_LIFE_SECONDS = 7 * 24 * 60 * 60

    attr_accessor :apple_music
    attr_accessor :cloud_directory
    attr_accessor :cloud_index_csv
    attr_accessor :cloud_index_file
    attr_accessor :github
    attr_accessor :google_drive
    attr_accessor :local_path
    attr_accessor :log_location
    attr_accessor :repo
    attr_accessor :trash_path
    attr_accessor :upload_path

    def initialize(**options)
      if options[:cloud_url]
        self.google_drive = GoogleDrive::Session.from_config(options[:google_drive_config_location])
        self.cloud_directory = google_drive.folder_by_url(options[:cloud_url])
        self.cloud_index_file =
          cloud_directory.files(q: ['name = ? and trashed = false', 'index.csv']).first
        self.cloud_index_file = nil if cloud_index_file&.trashed?
      end

      if options[:github_access_token] && options[:github_repo]
        self.github = Octokit::Client.new(access_token: options[:github_access_token])
        self.repo = options[:github_repo]
      end

      self.apple_music = app(options[:apple_music]) if options[:apple_music]

      self.local_path = options[:local_path]
      self.upload_path = options[:upload_path]
      self.trash_path = options[:trash_path]
      self.log_location = options[:log_location]
    end

    def setup_cloud
      print('Setting up cloud ~ ')
      return puts('Cloud index file already exists.'.red) if cloud_index_file

      csv = CSV.new('', **csv_options)
      csv << INDEX_FIELDS_CLOUD
      csv.rewind

      cloud_directory.upload_from_io(csv.to_io, 'index.csv')
      puts('done'.green)
    end

    def setup_local
      print('Setting up local ~ ')
      return puts('Local index file already exists.'.red) if
        File.exists?(local_index_file_location)

      CSV.open(local_index_file_location, 'w', **csv_options) { |csv| csv << INDEX_FIELDS_LOCAL }
      puts('done'.green)
    end

    def refresh_cloud
      print('Refreshing cloud library ~ ')
      return puts('Cloud index file not found.'.red) unless cloud_index_file

      download_index_file

      # Remove duplicates and build set of ids
      valid = {}
      songs = {}
      cloud_index_csv.each do |row|
        next unless row[:artist] && row[:title] && row[:id]

        songs[row[:artist]] ||= Set.new
        unless songs[row[:artist]].include?(row[:title])
          songs[row[:artist]] << row[:title]
          valid[row[:id]] = row
          next
        end

        google_drive.file_by_id(row[:id])&.delete
      end

      # Remove rogue files and build new index
      rows = []
      cloud_directory.subfolders(q: ['trashed = false']) do |directory|
        directory_empty = true
        directory.files(q: ['trashed = false']) do |file|
          unless file.full_file_extension == 'mp3'
            directory_empty = false
            next
          end

          if valid[file.id]
            directory_empty = false
            valid[file.id][:updated_at] = file.modified_time.to_time.to_i
            rows << valid[file.id]
          else
            file.delete
          end
        end

        directory.delete if directory_empty
      end

      rows.sort_by! { |row| [row[:artist], row[:title]] }

      csv = CSV.new('', **csv_options)
      csv << INDEX_FIELDS_CLOUD
      rows.each { |row| csv << row }
      io = csv.to_io
      io.rewind

      cloud_index_file.update_from_io(io)

      if github?
        io.rewind
        update_github_library(io.read)
      end

      puts('done'.green)
    rescue StandardError => error
      log_error(error)
    end

    def refresh_local
      print('Refreshing local library ~ ')
      return puts('No local index file found.'.red) unless File.exists?(local_index_file_location)

      songs = {}
      local_index_csv = CSV.read(local_index_file_location, **csv_options)
      raise('Invalid headers on local index file.') unless
        local_index_csv.headers.sort == INDEX_FIELDS_LOCAL.sort

      # Remove duplicates and build set of file locations
      locations = Set.new
      songs = {}
      local_index_csv.each do |row|
        next unless row[:artist] && row[:title] && row[:location]

        songs[row[:artist]] ||= Set.new
        unless songs[row[:artist]].include?(row[:title])
          songs[row[:artist]] << row[:title]
          locations << row[:location]
          next
        end

        move_file_to_trash(row[:location])
      end

      download_index_file unless cloud_index_csv

      cloud_index = {}
      cloud_index_csv.each do |row|
        cloud_index[row[:artist]] ||= {}
        cloud_index[row[:artist]][row[:title]] = row[:id]
      end

      # Remove rogue files and build new index
      rows = []
      Dir["#{local_path}/**/*.mp3"].each do |file_name|
        if locations.include?(file_name)
          File.open(file_name, 'rb') do |file|
            ID3Tag.read(file) do |tag|
              id = cloud_index.dig(tag.artist, tag.title)
              if id
                apple_music.add(file_name) if apple_music?
                rows << local_csv_row_for(
                  artist: tag.artist,
                  id: id,
                  location: file_name,
                  title: tag.title,
                  updated_at: file.mtime.to_i
                )
              else
                move_file_to_trash(file_name)
              end
            end
          end
        else
          move_file_to_trash(file_name)
        end
      end

      artist_index = INDEX_FIELDS_LOCAL.index(:artist)
      title_index = INDEX_FIELDS_LOCAL.index(:title)
      rows.sort_by! { |row| [row[artist_index], row[title_index]] }

      CSV.open(local_index_file_location, 'w', **csv_options) do |csv|
        csv << INDEX_FIELDS_LOCAL
        rows.each { |row| csv << row }
      end

      cleanup
      puts('done'.green)
    end

    def sync
      puts('Synching local library with cloud ~ ')

      local_index = {}
      if File.exists?(local_index_file_location)
        local_index_csv = CSV.read(local_index_file_location, **csv_options)
        raise('Invalid headers on local index file.') unless
          local_index_csv.headers.sort == INDEX_FIELDS_LOCAL.sort

        local_index_csv.each { |row| local_index[row[:id]] = row.to_h.except(:id) }
      end


      download_index_file
      locations = Set.new
      rows = []
      process_valid_row = proc do |file_name, row|
        locations << file_name

        rows << local_csv_row_for(
          location: file_name,
          **row.to_h.slice(:artist, :id, :title, :updated_at)
        )

        apple_music.add(file_name) if apple_music?
      end

      count = 0
      partial_failure = false
      cloud_index_csv.each do |row|
        local_data = local_index.delete(row[:id])
        if local_data&.dig(:location) && local_data.except(:location) == row.to_h.except(:id)
          process_valid_row.call(local_data[:location], row)
          next
        end

        print("#{row[:artist]} - #{row[:title]}")

        file = google_drive.file_by_id(row[:id])
        new_directory = "#{local_path}/#{google_drive.folder_by_id(file.parents.first).name}"
        FileUtils.mkdir_p(new_directory) unless File.directory?(new_directory)
        new_file_name = "#{new_directory}/#{file.name}"

        file.download_to_file(new_file_name)
        FileUtils.touch(new_file_name, mtime: row[:updated_at].to_i)
        process_valid_row.call(new_file_name, row)
        count += 1

        puts(' ✓'.green)
      rescue StandardError => error
        puts(' ✘'.red) if row[:artist] && row[:title]
        log_error(error)
        partial_failure = true
      end

      artist_index = INDEX_FIELDS_LOCAL.index(:artist)
      title_index = INDEX_FIELDS_LOCAL.index(:title)
      rows.sort_by! { |row| [row[artist_index], row[title_index]] }

      CSV.open(local_index_file_location, 'w', **csv_options) do |csv|
        csv << INDEX_FIELDS_LOCAL
        rows.each { |row| csv << row }
      end

      if partial_failure
        refresh_local
      else
        Dir["#{local_path}/**/*.mp3"].each do |file_name|
          move_file_to_trash(file_name) unless locations.include?(file_name)
        end

        cleanup
      end

      puts("#{count} file#{count == 1 ? '' : 's'} downloaded.".green)
    rescue StandardError => error
      puts('Failed.'.red)
      log_error(error)
      refresh_local if cloud_index_csv
    end

    def upload
      puts('Uploading new music ~ ')

      count = 0
      rows = []
      uploaded_files = []
      partial_failure = false
      begin
        directories = {}
        file_names = Dir["#{upload_path}/*.mp3"]
        new_songs = {}
        duplicates = []
        artist = title = nil
        file_names.each do |file_name|
          artist = title = nil
          File.open(file_name, 'rb') do |file|
            ID3Tag.read(file) do |tag|
              artist = tag.artist
              title = tag.title
            end
          end

          new_songs[artist] ||= Set.new
          next duplicates << file_name if new_songs[artist].include?(title)

          print("#{artist} - #{title}")
          new_songs[artist] << title

          unless directories[artist]
            directories[artist] =
              cloud_directory.subfolders(q: ['name = ? and trashed = false', artist]).first
            if directories[artist].nil? || directories[artist].title != artist
              directories[artist] = cloud_directory.create_subfolder(artist)
            end
          end

          new_file_name = "#{title}.mp3".tr('/?#', '_')
          file = directories[artist].files(q: ['name = ? and trashed = false', new_file_name]).first
          if file && !file.trashed? && file.title == new_file_name
            file.update_from_file(file_name)
            file = google_drive.file_by_id(file.id)
          else
            file = directories[artist].upload_from_file(file_name, new_file_name)
          end

          rows << cloud_csv_row_for(
            artist: artist,
            id: file.id,
            title: title,
            updated_at: file.modified_time.to_time.to_i
          )
          uploaded_files << file_name
          count += 1
          puts(' ✓'.green)
        end
      rescue StandardError => error
        puts(' ✘'.red) if artist && title
        log_error(error)
        partial_failure = true
      end

      begin
        artist_index = INDEX_FIELDS_CLOUD.index(:artist)
        title_index = INDEX_FIELDS_CLOUD.index(:title)

        if cloud_index_file
          download_index_file
          cloud_index_csv.to_a[1..].each do |row|
            rows << row unless new_songs[row[artist_index]]&.include?(row[title_index])
          end
        end

        rows.sort_by! { |row| [row[artist_index], row[title_index]] }

        csv = CSV.new('', **csv_options)
        csv << INDEX_FIELDS_CLOUD
        rows.each { |row| csv << row }
        io = csv.to_io
        io.rewind

        if cloud_index_file
          cloud_index_file.update_from_io(io)
        else
          cloud_directory.upload_from_io(io, 'index.csv')
        end
      rescue StandardError => error
        puts('Failed.'.red)
        puts
        log_error(error)
        refresh_cloud
        return
      end

      if count.positive? && github?
        io.rewind
        update_github_library(io.read)
      end

      begin
        uploaded_files.each { |file_name| move_file_to_trash(file_name) }
      rescue StandardError => error
        log_error(error)
        remove_failure = true
      end

      puts("#{count} file#{count == 1 ? '' : 's'} uploaded.".green)
      puts

      if partial_failure
        puts('Some files failed to upload.'.yellow)
        refresh_cloud
      end

      puts('Some files could not be removed.'.yellow) if remove_failure
      return if duplicates.empty?

      puts('Duplicate files ignored:'.yellow)
      duplicates.each { |duplicate| puts(duplicate) }
    end

    private

    def add_apple_music_track_to_playlists(file_name, *playlists)
      track = apple_music.tracks[its.location.eq(MacTypes::Alias.path(file_name))].first
      playlists.each do |playlist|
        track.duplicate(to: apple_music.user_playlists[its.name.eq(playlist)].first)
      end
    end

    def apple_music?
      !!apple_music
    end

    def cleanup
      Dir["#{local_path}/*/"].each { |directory| remove_empty_directory(directory) }
      remove_dead_apple_music_tracks if apple_music?
      take_out_trash
    end

    def cloud_csv_row_for(**fields)
      INDEX_FIELDS_CLOUD.each.with_object([]) { |header, array| array << fields[header] }
    end

    def csv_options
      { headers: true, header_converters: :symbol }
    end

    def download_index_file
      return if cloud_index_csv
      raise('No cloud index file found.') unless cloud_index_file

      self.cloud_index_csv = CSV.parse(cloud_index_file.download_to_string, **csv_options)
      raise('Invalid headers on cloud index file.') unless
        cloud_index_csv.headers.sort == INDEX_FIELDS_CLOUD.sort
    end

    def github?
      !!github
    end

    def local_csv_row_for(**fields)
      INDEX_FIELDS_LOCAL.each.with_object([]) { |header, array| array << fields[header] }
    end

    def local_index_file_location
      "#{local_path}/index.csv"
    end

    def log_error(error)
      puts
      puts("An error occurred, go to #{log_location} for more details.".red)
      File.write(log_location, "#{error.class}: #{error.message}\n#{error.backtrace.join("\n")}")
    end

    def move_file_to_trash(file)
      return unless File.exists?(file)

      FileUtils.mv(file, "#{trash_path}/#{File.basename(file, '.mp3')} #{Time.now.to_i}.mp3")
    end

    # Removes songs from Apple Music Library that are any of the following:
    # * No longer associated with a file
    # * Associated with a file outside of the designated local directory
    # * Duplicates (version with highest played count is kept) [not entirely sure this is possible]
    def remove_dead_apple_music_tracks
      return if apple_music.tracks.get.empty?

      keep = {}
      indexes_to_remove = Set.new
      played_counts = apple_music.tracks.played_count.get
      locations = apple_music.tracks.location.get
      locations.each.with_index do |location, index|
        if keep[location]
          if played_counts[index] > keep[location][:played_count]
            indexes_to_remove << keep[location][:index]
            keep[location][:index] = index
          else
            indexes_to_remove << index
          end

          next
        end

        if locations[index] == :missing_value || !locations[index].to_s.start_with?(local_path)
          indexes_to_remove << index
        else
          keep[location] = { index: index, played_count: played_counts[index] }
        end
      end

      apple_music.tracks.database_ID.get.values_at(*indexes_to_remove).each do |id|
        apple_music.tracks[its.database_ID.eq(id)].delete
      end
    end

    def remove_empty_directory(directory)
      FileUtils.remove_dir(directory) if Dir["#{directory}/*.mp3"].empty?
    end

    def remove_song_from_apple_music(file_name)
      apple_music.tracks[its.location.eq(MacTypes::Alias.path(file_name))].delete
    end

    def take_out_trash
      Dir["#{trash_path}/*.mp3"].each do |file_name|
        File.delete(file_name) if (Time.now - File.new(file_name).mtime) > TRASH_LIFE_SECONDS
      end
    end

    def update_apple_music_track(file_name, **attributes)
      track = apple_music.tracks[its.location.eq(MacTypes::Alias.path(file_name))]
      attributes.each { |field, value| track.send(field).set(to: value) }
    end

    def update_github_library(contents)
      branch_ref = 'heads/master'

      latest_sha = github.ref(repo, branch_ref).object.sha
      base_tree = github.commit(repo, latest_sha).commit.tree.sha

      library_file_name = 'library.csv'
      version = Base64.decode64(github.contents(repo, path: 'version').content).to_i + 1
      tree_data = { library_file_name => contents, version: version.to_s }.map do |path, data|
        blob = github.create_blob(repo, Base64.encode64(data), 'base64')
        { path: path, mode: '100644', type: 'blob', sha: blob }
      end

      new_tree = github.create_tree(repo, tree_data, base_tree: base_tree).sha
      new_sha = github.create_commit(repo, "v#{version}", new_tree, latest_sha).sha
      diff = github.compare(repo, latest_sha, new_sha)
      return unless diff.files.any? { |file| file.filename == library_file_name }

      github.update_ref(repo, branch_ref, new_sha)
    rescue StandardError => error
      log_error(error)
      puts('Failed to update github library. Run `muzik refresh cloud` to update it manually.'.red)
    end
  end
end
