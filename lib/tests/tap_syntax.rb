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

        return if ["push", "merge_group"].exclude?(ENV["GITHUB_EVENT_NAME"])

        FileUtils.mkdir_p "api"
        Pathname("api").cd do
          if tap.core_tap?
            test "brew", "generate-formula-api"
          elsif tap.name.start_with?("homebrew/cask")
            test "brew", "generate-cask-api"
          end
        end
      ensure
        FileUtils.rm_rf "api"
      end
    end
  end
end
