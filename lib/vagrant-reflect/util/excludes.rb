module VagrantReflect
  module Util
    # This is a helper that builds the required commands and returns them
    class Excludes
      class << self
        PATTERNS = [
          ['.', '\\.'],
          ['***', '|||EMPTY|||'],
          ['**', '|||GLOBAL|||'],
          ['*', '|||PATH|||'],
          ['?', '[^/]'],
          ['|||PATH|||', '[^/]+'],
          ['|||GLOBAL|||', '.+'],
          ['|||EMPTY|||', '.*']
        ].freeze

        # This converts the rsync exclude patterns to regular expressions we can
        # send to Listen.
        def convert(excludes)
          excludes.map(&method(:convert_single))
        end

        protected

        def convert_single(exclude)
          start_anchor = false

          if exclude.start_with?('/')
            start_anchor = true
            exclude = exclude[1..-1]
          end

          regexp = start_anchor ? '^' : '(?:^|/)'
          regexp += perform_substitutions(exclude)
          regexp += exclude.end_with?('/') ? '' : '(?:/|$)'

          Regexp.new(regexp)
        end

        def perform_substitutions(exclude)
          # This is REALLY ghetto, but its a start. We can improve and
          # keep unit tests passing in the future.
          # TODO: Escaped wildcards get substituted incorrectly;
          #       replace with FSM?
          PATTERNS.each do |pattern|
            exclude = exclude.gsub(pattern[0], pattern[1])
          end
          exclude
        end
      end # << self
    end # ::Excludes
  end # ::Util
end # ::VagrantReflect
