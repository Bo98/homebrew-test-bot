# frozen_string_literal: true

module Homebrew
  module Tests
    class Setup < Test
      def run!
        test_header(:Setup)

        # Always output `brew config` output even when it doesn't fail.
        test "brew", "config", verbose: true

        test "brew", "doctor"
      end
    end
  end
end
