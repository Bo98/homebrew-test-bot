# frozen_string_literal: true

require_relative "test"
require_relative "tests/tap_syntax"

module Homebrew
  module TestRunner
    module_function

    def run!(tap, git:)
      tests = []
      any_errors = false
      skip_setup = Homebrew.args.skip_setup?
      skip_cleanup_before = false

      test_bot_args = Homebrew.args.named

      # With no arguments just build the most recent commit.
      test_bot_args << "HEAD" if test_bot_args.empty?

      test_bot_args.each do |argument|
        skip_cleanup_after = argument != test_bot_args.last
        current_test = build_test(argument, tap:                 tap,
                                            git:                 git,
                                            skip_setup:          skip_setup,
                                            skip_cleanup_before: skip_cleanup_before,
                                            skip_cleanup_after:  skip_cleanup_after)
        skip_setup = true
        skip_cleanup_before = true
        tests << current_test
        any_errors ||= !run_test(current_test)
      end

      failed_steps = tests.map { |test| test.steps.select(&:failed?) }
                          .flatten
                          .compact
      steps_output = if failed_steps.empty?
        "All steps passed!"
      else
        failed_steps_output = ["Error: #{failed_steps.length} failed steps!"]
        failed_steps_output += failed_steps.map(&:command_trimmed)
        failed_steps_output.join("\n")
      end
      puts steps_output

      steps_output_path = Pathname("steps_output.txt")
      steps_output_path.unlink if steps_output_path.exist?
      steps_output_path.write(steps_output)

      !any_errors
    end

    def no_only_args?
      any_only = Homebrew.args.only_cleanup_before? ||
                 Homebrew.args.only_setup? ||
                 Homebrew.args.only_tap_syntax? ||
                 Homebrew.args.only_formulae? ||
                 Homebrew.args.only_cleanup_after?
      !any_only
    end

    def build_test(argument, tap:, git:, skip_setup:, skip_cleanup_before:, skip_cleanup_after:)
      # TODO: clean this up when all classes ported.
      klass = if no_only_args? || Homebrew.args.only_tap_syntax?
        Tests::TapSyntax
      else
        Test
      end

      klass.new(argument, tap:                 tap,
                          git:                 git,
                          skip_setup:          skip_setup,
                          skip_cleanup_before: skip_cleanup_before,
                          skip_cleanup_after:  skip_cleanup_after)
    end

    def run_test(test)
      test.cleanup_before if no_only_args? || Homebrew.args.only_cleanup_before?
      begin
        test.setup if no_only_args? || Homebrew.args.only_setup?
        test.tap_syntax if no_only_args? || Homebrew.args.only_tap_syntax?
        test.test_formulae if no_only_args? || Homebrew.args.only_formulae?
      ensure
        test.cleanup_after if no_only_args? || Homebrew.args.only_cleanup_after?
      end
      test.all_steps_passed?
    end
  end
end
