# frozen_string_literal: true

module TapeDeck
  # One recorded diff, stored as a YAML file. Like a +File+, a tape knows where it lives, whether it is there to be
  # recorded or verified, and how to read and write itself. It never touches a database.
  #
  # Next to the diff, a tape stores what was recorded: the exclude rules, the watched databases, and per database the
  # tables and columns the rules left out. Empty lists are left out of the file.
  #
  #   recorded:
  #     exclude_tables: [shop.sessions]
  #     exclude_columns: ["*.created_at"]
  #     databases:
  #       shop:
  #         excluded: [orders.created_at, sessions]
  #       billing:
  #   diff:
  #     shop:
  #       orders:
  #         inserted: [...]
  class Tape
    # Lists in the +recorded+ section of a tape file, written on one line.
    RECORDED_LISTS = %w[exclude_tables exclude_columns excluded].freeze

    # Supported values for the +:record+ option:
    # [+:once+]      record if the tape file is missing, otherwise verify
    # [+:verify+]    verify only, never record. A missing tape raises {TapeLoadingError}
    # [+:overwrite+] always record, replacing an existing tape
    RECORD_MODES = %i[once verify overwrite].freeze

    # Characters in a tape name that are replaced with +_+ in its file name.
    UNSAFE_FILE_NAME_CHARS = %r{[^\w\-/]+}

    # @return [String]
    attr_reader :name

    # @return [Symbol] one of {RECORD_MODES}
    attr_reader :record_mode

    # @param diff [Hash] a diff as returned by {Recorder#diff}
    # @return [String] the YAML stored in a tape file
    def self.serialize(diff) = YAML.dump(diff, line_width: -1)

    # @param mode [Symbol]
    # @return [void]
    # @raise [ArgumentError] unless the mode is one of {RECORD_MODES}
    def self.validate_record_mode(mode)
      return if RECORD_MODES.include?(mode)

      raise ArgumentError, "invalid record mode #{mode.inspect}, use one of #{RECORD_MODES.inspect}"
    end

    # Like {.serialize}, but writes the {RECORDED_LISTS} on one line, so the +recorded+ section stays short.
    #
    # @param content [Hash] see {#read}
    # @return [String] the YAML stored in a tape file
    def self.dump(content)
      tree = Psych::Visitors::YAMLTree.create(line_width: -1)
      tree << content
      tree.tree.each do |node|
        next unless node.is_a?(Psych::Nodes::Mapping)

        node.children.each_slice(2) do |key, value|
          recorded_list = RECORDED_LISTS.include?(key.value) && value.is_a?(Psych::Nodes::Sequence)
          value.style = Psych::Nodes::Sequence::FLOW if recorded_list
        end
      end
      tree.tree.yaml(nil, line_width: -1)
    end

    # @param name [String] tape name, may contain +/+ to create subdirectories
    # @param record [Symbol] one of {RECORD_MODES}, defaults to {Configuration#default_record_mode}
    # @raise [ArgumentError] for an unknown record mode
    # @raise [TapeLoadingError] if the tape must be verified but does not exist
    def initialize(name, record: TapeDeck.configuration.default_record_mode)
      self.class.validate_record_mode(record)
      @name = name.to_s
      @record_mode = record

      tape_exists = File.exist?(file)
      raise TapeLoadingError, "no tape at #{file} (record mode :verify)" if @record_mode == :verify && !tape_exists

      @recording = @record_mode == :overwrite || !tape_exists
    end

    # @return [Boolean] whether the tape is to be written
    def recording? = @recording

    # @return [Boolean] whether the tape is to be read and compared
    def verifying? = !recording?

    # @return [String] path of the tape file, see {#file_name}
    def file
      File.join(TapeDeck.configuration.tape_library_dir, file_name)
    end

    # @return [String] the tape name with {UNSAFE_FILE_NAME_CHARS} replaced, plus +.yml+
    def file_name
      "#{name.gsub(UNSAFE_FILE_NAME_CHARS, "_")}.yml"
    end

    # Reads the tape file once, later calls return the same content.
    #
    # @return [Hash] +"recorded"+: see {#write}, and +"diff"+: the stored diff
    # @raise [TapeLoadingError] if the file is not valid YAML or does not hold a recording
    def read
      @content ||= load
    end

    # @param diff [Hash] the diff to store in the tape file, replacing its content
    # @param recorded [Hash] +"exclude_tables"+ and +"exclude_columns"+: the exclude rules, +"databases"+: database ->
    #   names the rules left out of it, as returned by {Recorder#exclusions}
    # @return [void]
    def write(diff, recorded:)
      databases = recorded.fetch("databases").transform_values do |names|
        {"excluded" => names} unless names.empty?
      end
      patterns = recorded.slice("exclude_tables", "exclude_columns").reject { |_, list| list.empty? }
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, self.class.dump("recorded" => {**patterns, "databases" => databases}, "diff" => diff))
      @content = nil
    end

    private

    def load
      content = YAML.safe_load_file(file)
      raise TapeLoadingError, "tape #{file} does not hold a recording" unless valid_content?(content)

      recorded = content["recorded"]
      databases = recorded["databases"].transform_values { Array(_1&.dig("excluded")) }
      {
        "recorded" => {
          "exclude_tables" => Array(recorded["exclude_tables"]),
          "exclude_columns" => Array(recorded["exclude_columns"]),
          "databases" => databases
        },
        "diff" => content["diff"]
      }
    rescue Psych::Exception => e
      raise TapeLoadingError, "cannot load tape #{file}: #{e.message}"
    end

    def valid_content?(content)
      return false unless content.is_a?(Hash) && content["diff"].is_a?(Hash)

      recorded = content["recorded"]
      databases = recorded["databases"] if recorded.is_a?(Hash)
      databases.is_a?(Hash) && databases.values.all? { _1.nil? || _1.is_a?(Hash) }
    end
  end
end
