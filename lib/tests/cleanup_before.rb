# frozen_string_literal: true

module Homebrew
  module Tests
    class CleanupBefore < TestCleanup
      def run!(args:)
        test_header(:CleanupBefore)

        if tap.to_s != CoreTap.instance.name
          core_path = CoreTap.instance.path
          if core_path.exist?
            test git, "-C", core_path.to_s, "fetch", "--depth=1", "origin"
            reset_if_needed(core_path.to_s)
          else
            test git, "clone", "--depth=1",
                  CoreTap.instance.default_remote,
                  core_path.to_s
          end
        end

        Pathname.glob("*.bottle*.*").each(&:unlink)

        if ENV["HOMEBREW_GITHUB_ACTIONS"] && !ENV["GITHUB_ACTIONS_HOMEBREW_SELF_HOSTED"]
          # minimally fix brew doctor failures (a full clean takes ~5m)
          if OS.linux?
            # brew doctor complains
            FileUtils.rm_rf "/usr/local/include/node/"
          else
            # moving is much faster than deleting.
            system "mv", "#{HOMEBREW_CELLAR}/*", "/tmp"
          end
        end

        # Keep all "brew" invocations after cleanup_shared
        # (which cleans up Homebrew/brew)
        cleanup_shared

        installed_taps = Tap.select(&:installed?).map(&:name)
        (REQUIRED_TAPS - installed_taps).each do |tap|
          test "brew", "tap", tap
        end

        # install newer Git when needed
        if OS.mac? && MacOS.version < :sierra
          test "brew", "install", "git"
          ENV["HOMEBREW_FORCE_BREWED_GIT"] = "1"
          change_git!("#{HOMEBREW_PREFIX}/opt/git/bin/git")
        end

        brew_version = Utils.safe_popen_read(
          git, "-C", HOMEBREW_REPOSITORY.to_s,
                "describe", "--tags", "--abbrev", "--dirty"
        ).strip
        brew_commit_subject = Utils.safe_popen_read(
          git, "-C", HOMEBREW_REPOSITORY.to_s,
                "log", "-1", "--format=%s"
        ).strip
        puts
        verb = tap ? "Using" : "Testing"
        info_header "#{verb} Homebrew/brew #{brew_version} (#{brew_commit_subject})"
      end
    end
  end
end
