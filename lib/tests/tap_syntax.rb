# frozen_string_literal: true

module Homebrew
  module Tests
    class TapSyntax < Test
      def run!(args:)
        test_header(:TapSyntax)

        broken_xcode_rubygems = MacOS.version == :mojave &&
                                MacOS.active_developer_dir == "/Applications/Xcode.app/Contents/Developer"
        test "brew", "style", tap.name unless broken_xcode_rubygems

        return if tap.formula_files.blank? && tap.cask_files.blank?

        test "brew", "readall", "--aliases", tap.name
        test "brew", "audit", "--tap=#{tap.name}"
      end
    end
  end
end
