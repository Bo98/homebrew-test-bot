# frozen_string_literal: true

require_relative "step"
require_relative "test"

require "date"
require "json"
require "rexml/document"
require "rexml/xmldecl"
require "rexml/cdata"

require "development_tools"
require "formula"
require "formula_installer"
require "os"
require "tap"
require "utils"
require "utils/bottles"

module Homebrew
  module TestBot
    module_function

    BYTES_IN_1_MEGABYTE = 1024*1024
    MAX_STEP_OUTPUT_SIZE = BYTES_IN_1_MEGABYTE - (200*1024) # margin of safety

    HOMEBREW_TAP_REGEX = %r{^([\w-]+)/homebrew-([\w-]+)$}.freeze

    def resolve_test_tap
      if (tap = ARGV.value("tap"))
        return Tap.fetch(tap)
      end

      if (tap = ENV["TRAVIS_REPO_SLUG"]) && (tap =~ HOMEBREW_TAP_REGEX)
        return Tap.fetch(tap)
      end

      if ENV["UPSTREAM_BOT_PARAMS"]
        bot_argv = ENV["UPSTREAM_BOT_PARAMS"].split(" ")
        bot_argv.extend HomebrewArgvExtension
        if tap = bot_argv.value("tap")
          return Tap.fetch(tap)
        end
      end

      # Get tap from Jenkins UPSTREAM_GIT_URL, GIT_URL or
      # Circle CI's CIRCLE_REPOSITORY_URL or Azure Pipelines BUILD_REPOSITORY_URI
      # or GitHub Actions GITHUB_REPOSITORY
      git_url =
        ENV["UPSTREAM_GIT_URL"] ||
        ENV["GIT_URL"] ||
        ENV["CIRCLE_REPOSITORY_URL"] ||
        ENV["BUILD_REPOSITORY_URI"] ||
        ENV["GITHUB_REPOSITORY"]
      return unless git_url

      url_path = git_url.sub(%r{^https?://.*github\.com/}, "")
                        .chomp("/")
                        .sub(/\.git$/, "")
      begin
        return Tap.fetch(url_path) if url_path =~ HOMEBREW_TAP_REGEX
      rescue
        # Don't care if tap fetch fails
        nil
      end
    end

    def copy_bottles_from_jenkins
      jenkins = ENV["JENKINS_HOME"]
      job = ENV["UPSTREAM_JOB_NAME"]
      id = ENV["UPSTREAM_BUILD_ID"]
      if (!job || !id) && !ARGV.include?("--dry-run")
        raise "Missing Jenkins variables!"
      end

      jenkins_dir  = "#{jenkins}/jobs/#{job}/configurations/axis-version/*/"
      jenkins_dir += "builds/#{id}/archive/*.bottle*.*"
      bottles = Dir[jenkins_dir]

      raise "No bottles found in #{jenkins_dir}!" if bottles.empty? && !ARGV.include?("--dry-run")

      FileUtils.cp bottles, Dir.pwd, verbose: true
    end

    def test_ci_upload(tap)
      # Don't trust formulae we're uploading
      ENV["HOMEBREW_DISABLE_LOAD_FORMULA"] = "1"

      bintray_user = ENV["HOMEBREW_BINTRAY_USER"]
      bintray_key = ENV["HOMEBREW_BINTRAY_KEY"]
      if !bintray_user || !bintray_key
        unless ARGV.include?("--dry-run")
          raise "Missing HOMEBREW_BINTRAY_USER or HOMEBREW_BINTRAY_KEY variables!"
        end
      end

      # Ensure that uploading Homebrew bottles on Linux doesn't use Linuxbrew.
      bintray_org = ARGV.value("bintray-org") || "homebrew"
      if bintray_org == "homebrew" && !OS.mac?
        ENV["HOMEBREW_FORCE_HOMEBREW_ON_LINUX"] = "1"
      end

      # Don't pass keys/cookies to subprocesses
      ENV.clear_sensitive_environment!

      ARGV << "--verbose"

      copy_bottles_from_jenkins unless ENV["JENKINS_HOME"].nil?

      raise "No bottles found in #{Dir.pwd}!" if Dir["*.bottle*.*"].empty? && !ARGV.include?("--dry-run")

      json_files = Dir.glob("*.bottle.json")
      bottles_hash = json_files.reduce({}) do |hash, json_file|
        hash.deep_merge(JSON.parse(IO.read(json_file)))
      end

      if ARGV.include?("--dry-run")
        bottles_hash = {
          "testbottest" => {
            "formula" => {
              "pkg_version" => "1.0.0",
            },
            "bottle"  => {
              "rebuild" => 0,
              "tags"    => {
                Utils::Bottles.tag => {
                  "filename" =>
                                "testbottest-1.0.0.#{Utils::Bottles.tag}.bottle.tar.gz",
                  "sha256"   =>
                                "20cdde424f5fe6d4fdb6a24cff41d2f7aefcd1ef2f98d46f6c074c36a1eef81e",
                },
              },
            },
            "bintray" => {
              "package"    => "testbottest",
              "repository" => "bottles",
            },
          },
        }
      end

      first_formula_name = bottles_hash.keys.first
      tap_name = first_formula_name.rpartition("/").first.chuzzle
      tap_name ||= CoreTap.instance.name
      tap ||= Tap.fetch(tap_name)

      ENV["GIT_WORK_TREE"] = tap.path
      ENV["GIT_DIR"] = "#{ENV["GIT_WORK_TREE"]}/.git"
      ENV["HOMEBREW_GIT_NAME"] = ARGV.value("git-name") || "BrewTestBot"
      ENV["HOMEBREW_GIT_EMAIL"] = ARGV.value("git-email") ||
                                  "homebrew-test-bot@lists.sfconservancy.org"

      if ARGV.include?("--dry-run")
        puts <<~EOS
          git am --abort
          git rebase --abort
          git checkout -f master
          git reset --hard origin/master
          brew update
        EOS
      else
        quiet_system "git", "am", "--abort"
        quiet_system "git", "rebase", "--abort"
        safe_system "git", "checkout", "-f", "master"
        safe_system "git", "reset", "--hard", "origin/master"
        safe_system "brew", "update"
      end

      # These variables are for Jenkins, Jenkins pipeline and
      # Circle CI respectively.
      pr = ENV["UPSTREAM_PULL_REQUEST"] ||
          ENV["CHANGE_ID"] ||
          ENV["CIRCLE_PR_NUMBER"]
      if pr
        pull_pr = "#{tap.default_remote}/pull/#{pr}"
        safe_system "brew", "pull", "--clean", pull_pr
      end

      if ENV["UPSTREAM_BOTTLE_KEEP_OLD"] ||
        ENV["BOT_PARAMS"].to_s.include?("--keep-old") ||
        ARGV.include?("--keep-old")
        system "brew", "bottle", "--merge", "--write", "--keep-old", *json_files
      elsif !ARGV.include?("--dry-run")
        system "brew", "bottle", "--merge", "--write", *json_files
      else
        puts "brew bottle --merge --write $JSON_FILES"
      end

      # These variables are for Jenkins and Circle CI respectively.
      upstream_number = ENV["UPSTREAM_BUILD_NUMBER"] || ENV["CIRCLE_BUILD_NUM"]
      git_name = ENV["HOMEBREW_GIT_NAME"]
      remote = "git@github.com:#{git_name}/homebrew-#{tap.repo}.git"
      git_tag = if pr
        "pr-#{pr}"
      elsif upstream_number
        "testing-#{upstream_number}"
      elsif (number = ENV["BUILD_NUMBER"])
        "other-#{number}"
      elsif ARGV.include?("--dry-run")
        "$GIT_TAG"
      end

      if git_tag
        if ARGV.include?("--dry-run")
          puts "git push --force #{remote} origin/master:master :refs/tags/#{git_tag}"
        else
          safe_system "git", "push", "--force", remote, "origin/master:master",
                                                        ":refs/tags/#{git_tag}"
        end
      end

      formula_packaged = {}

      bottles_hash.each do |formula_name, bottle_hash|
        version = bottle_hash["formula"]["pkg_version"]
        bintray_package = bottle_hash["bintray"]["package"]
        bintray_repo = bottle_hash["bintray"]["repository"]
        bintray_packages_url =
          "https://api.bintray.com/packages/#{bintray_org}/#{bintray_repo}"

        rebuild = bottle_hash["bottle"]["rebuild"]

        bottle_hash["bottle"]["tags"].each do |tag, _tag_hash|
          filename = Bottle::Filename.new(formula_name, version, tag, rebuild)
          bintray_url =
            "#{HOMEBREW_BOTTLE_DOMAIN}/#{bintray_repo}/#{filename.bintray}"
          filename_already_published = if ARGV.include?("--dry-run")
            puts "curl -I --output /dev/null #{bintray_url}"
            false
          else
            begin
              system(curl_executable, *curl_args("-I", "--output", "/dev/null",
                    bintray_url))
            end
          end

          if filename_already_published
            raise <<~EOS
              #{filename.bintray} is already published. Please remove it manually from
              https://bintray.com/#{bintray_org}/#{bintray_repo}/#{bintray_package}/view#files
            EOS
          end

          unless formula_packaged[formula_name]
            package_url = "#{bintray_packages_url}/#{bintray_package}"
            package_exists = if ARGV.include?("--dry-run")
              puts "curl --output /dev/null #{package_url}"
              false
            else
              system(curl_executable, *curl_args("--output", "/dev/null", package_url))
            end

            unless package_exists
              package_blob = <<~EOS
                {"name": "#{bintray_package}",
                "public_download_numbers": true,
                "public_stats": true}
              EOS
              if ARGV.include?("--dry-run")
                puts <<~EOS
                  curl --user $HOMEBREW_BINTRAY_USER:$HOMEBREW_BINTRAY_KEY
                      --header Content-Type: application/json
                      --data #{package_blob.delete("\n")}
                      #{bintray_packages_url}
                EOS
              else
                curl "--user", "#{bintray_user}:#{bintray_key}",
                    "--header", "Content-Type: application/json",
                    "--data", package_blob, bintray_packages_url,
                    secrets: [bintray_key]
                puts
              end
            end
            formula_packaged[formula_name] = true
          end

          content_url = "https://api.bintray.com/content/#{bintray_org}"
          content_url +=
            "/#{bintray_repo}/#{bintray_package}/#{version}/#{filename.bintray}"
          if ARGV.include?("--dry-run")
            puts <<~EOS
              curl --user $HOMEBREW_BINTRAY_USER:$HOMEBREW_BINTRAY_KEY
                  --upload-file #{filename}
                  #{content_url}
            EOS
          else
            curl "--user", "#{bintray_user}:#{bintray_key}",
                "--upload-file", filename, content_url,
                secrets: [bintray_key]
            puts
          end
        end
      end

      return unless git_tag

      if ARGV.include?("--dry-run")
        puts "git tag --force #{git_tag}"
        puts "git push --force #{remote} origin/master:master refs/tags/#{git_tag}"
      else
        safe_system "git", "tag", "--force", git_tag
        safe_system "git", "push", "--force", remote, "origin/master:master",
                                                      "refs/tags/#{git_tag}"
      end
    end

    def sanitize_argv_and_env
      if Pathname.pwd == HOMEBREW_PREFIX && ARGV.include?("--cleanup")
        odie "cannot use --cleanup from HOMEBREW_PREFIX as it will delete all output."
      end

      ENV["HOMEBREW_DEVELOPER"] = "1"
      ENV["HOMEBREW_NO_AUTO_UPDATE"] = "1"
      ENV["HOMEBREW_NO_EMOJI"] = "1"
      ENV["HOMEBREW_FAIL_LOG_LINES"] = "150"
      ENV["HOMEBREW_PATH"] = ENV["PATH"] =
                              "#{HOMEBREW_PREFIX}/bin:#{HOMEBREW_PREFIX}/sbin:#{ENV["PATH"]}"

      travis = !ENV["TRAVIS"].nil?
      circle = !ENV["CIRCLECI"].nil?
      if travis || circle
        ARGV << "--ci-auto" << "--no-pull"
      end
      ENV["HOMEBREW_CIRCLECI"] = "1" if circle
      if travis
        ARGV << "--verbose"
        ENV["HOMEBREW_COLOR"] = "1"
        ENV["HOMEBREW_VERBOSE_USING_DOTS"] = "1"
        ENV["HOMEBREW_TRAVIS_CI"] = "1"
        ENV["HOMEBREW_TRAVIS_SUDO"] = ENV["TRAVIS_SUDO"]
      end

      jenkins = !ENV["JENKINS_HOME"].nil?
      jenkins_pipeline_pr = jenkins && !ENV["CHANGE_URL"].nil?
      jenkins_pipeline_branch = jenkins &&
                                !jenkins_pipeline_pr &&
                                !ENV["BRANCH_NAME"].nil?
      ARGV << "--ci-auto" if jenkins_pipeline_branch || jenkins_pipeline_pr
      ARGV << "--no-pull" if jenkins_pipeline_branch

      azure_pipelines = !ENV["TF_BUILD"].nil?
      if azure_pipelines
        ARGV << "--verbose" << "--ci-auto" << "--no-pull"
        ENV["HOMEBREW_AZURE_PIPELINES"] = "1"
        ENV["HOMEBREW_COLOR"] = "1"
      end

      github_actions = !ENV["GITHUB_ACTIONS"].nil?
      if github_actions
        ARGV << "--verbose" << "--ci-auto" << "--no-pull"
        ENV["HOMEBREW_COLOR"] = "1"
        ENV["HOMEBREW_GITHUB_ACTIONS"] = "1"
      end

      travis_pr = ENV["TRAVIS_PULL_REQUEST"] &&
                  ENV["TRAVIS_PULL_REQUEST"] != "false"
      jenkins_pr = !ENV["ghprbPullLink"].nil?
      jenkins_pr ||= !ENV["ROOT_BUILD_CAUSE_GHPRBCAUSE"].nil?
      jenkins_pr ||= jenkins_pipeline_pr
      jenkins_branch = !ENV["GIT_COMMIT"].nil?
      jenkins_branch ||= jenkins_pipeline_branch
      azure_pipelines_pr = ENV["BUILD_REASON"] == "PullRequest"
      github_actions_pr = ENV["GITHUB_EVENT_NAME"] == "pull_request"
      circle_pr = !ENV["CIRCLE_PULL_REQUEST"].to_s.empty?

      # Only report coverage if build runs on macOS and this is indeed Homebrew,
      # as we don't want this to be averaged with inferior Linux test coverage.
      if OS.mac? && ENV["HOMEBREW_COVERALLS_REPO_TOKEN"]
        ARGV << "--coverage"

        if azure_pipelines
          ENV["HOMEBREW_CI_NAME"] = "azure-pipelines"
          ENV["HOMEBREW_CI_BUILD_NUMBER"] = ENV["BUILD_BUILDID"]
          ENV["HOMEBREW_CI_BUILD_URL"] = "#{ENV["SYSTEM_TEAMFOUNDATIONSERVERURI"]}#{ENV["SYSTEM_TEAMPROJECT"]}/_build/results?buildId=#{ENV["BUILD_BUILDID"]}"
          ENV["HOMEBREW_CI_BRANCH"] = ENV["BUILD_SOURCEBRANCH"]
          ENV["HOMEBREW_CI_PULL_REQUEST"] = ENV["SYSTEM_PULLREQUEST_PULLREQUESTNUMBER"]
        end

        if github_actions
          ENV["HOMEBREW_CI_NAME"] = "github-actions"
          ENV["HOMEBREW_CI_BUILD_NUMBER"] = ENV["GITHUB_REF"]
          ENV["HOMEBREW_CI_BRANCH"] = ENV["HEAD_GITHUB_REF"]
          %r{refs/pull/(?<pr>\d+)/merge} =~ ENV["GITHUB_REF"]
          ENV["HOMEBREW_CI_PULL_REQUEST"] = pr
          ENV["HOMEBREW_CI_BUILD_URL"] = "https://github.com/#{ENV["GITHUB_REPOSITORY"]}/pull/#{pr}/checks"
        end
      end

      if ARGV.include?("--ci-auto")
        if travis_pr || jenkins_pr || azure_pipelines_pr ||
          github_actions_pr || circle_pr
          ARGV << "--ci-pr"
        elsif travis || jenkins_branch || circle
          ARGV << "--ci-master"
        else
          ARGV << "--ci-testing"
        end
      end

      if ARGV.include?("--ci-master") ||
        ARGV.include?("--ci-pr") ||
        ARGV.include?("--ci-testing")
        ARGV << "--cleanup"
        ARGV << "--test-default-formula"
        ARGV << "--local" if jenkins
        ARGV << "--junit" if jenkins || azure_pipelines
      end

      ARGV << "--fast" if ARGV.include?("--ci-master")

      test_bot_revision = Utils.popen_read(
        "git", "-C", Tap.fetch("homebrew/test-bot").path.to_s,
              "log", "-1", "--format=%h (%s)"
      ).strip
      puts "Homebrew/homebrew-test-bot #{test_bot_revision}"
      puts "ARGV: #{ARGV.join(" ")}"

      return unless ARGV.include?("--local")

      ENV["HOMEBREW_HOME"] = ENV["HOME"] = "#{Dir.pwd}/home"
      FileUtils.mkdir_p ENV["HOMEBREW_HOME"]
      ENV["HOMEBREW_LOGS"] = "#{Dir.pwd}/logs"
    end

    def test_bot
      $stdout.sync = true
      $stderr.sync = true

      sanitize_argv_and_env

      tap = resolve_test_tap
      # Tap repository if required, this is done before everything else
      # because Formula parsing and/or git commit hash lookup depends on it.
      # At the same time, make sure Tap is not a shallow clone.
      # bottle rebuild and bottle upload rely on full clone.
      if tap
        if !tap.path.exist?
          safe_system "brew", "tap", tap.name, "--full"
        elsif (tap.path/".git/shallow").exist?
          raise unless quiet_system "git", "-C", tap.path, "fetch", "--unshallow"
        end
      end

      return test_ci_upload(tap) if ARGV.include?("--ci-upload")

      tests = []
      any_errors = false
      skip_setup = ARGV.include?("--skip-setup")
      skip_cleanup_before = false
      if ARGV.named.empty?
        # With no arguments just build the most recent commit.
        current_test = Test.new("HEAD", tap:                 tap,
                                        skip_setup:          skip_setup,
                                        skip_cleanup_before: skip_cleanup_before)
        any_errors = !current_test.run
        tests << current_test
      else
        ARGV.named.each do |argument|
          skip_cleanup_after = argument != ARGV.named.last
          test_error = false
          begin
            current_test =
              Test.new(argument, tap:                 tap,
                                 skip_setup:          skip_setup,
                                 skip_cleanup_before: skip_cleanup_before,
                                 skip_cleanup_after:  skip_cleanup_after)
            skip_setup = true
            skip_cleanup_before = true
          rescue ArgumentError => e
            test_error = true
            ofail e.message
          else
            test_error = !current_test.run
            tests << current_test
          end
          any_errors ||= test_error
        end
      end

      if ARGV.include? "--junit"
        xml_document = REXML::Document.new
        xml_document << REXML::XMLDecl.new
        testsuites = xml_document.add_element "testsuites"

        tests.each do |test|
          testsuite = testsuites.add_element "testsuite"
          testsuite.add_attribute "name", "brew-test-bot.#{Utils::Bottles.tag}"
          testsuite.add_attribute "tests", test.steps.select(&:passed?).count
          testsuite.add_attribute "failures", test.steps.select(&:failed?).count
          testsuite.add_attribute "timestamp", test.steps.first.start_time.iso8601

          test.steps.each do |step|
            testcase = testsuite.add_element "testcase"
            testcase.add_attribute "name", step.command_short
            testcase.add_attribute "status", step.status
            testcase.add_attribute "time", step.time
            testcase.add_attribute "timestamp", step.start_time.iso8601

            next unless step.output?

            output = sanitize_output_for_xml(step.output)
            cdata = REXML::CData.new output

            if step.passed?
              elem = testcase.add_element "system-out"
            else
              elem = testcase.add_element "failure"
              elem.add_attribute "message",
                                "#{step.status}: #{step.command.join(" ")}"
            end

            elem << cdata
          end
        end

        open("brew-test-bot.xml", "w") do |xml_file|
          pretty_print_indent = 2
          xml_document.write(xml_file, pretty_print_indent)
        end
      end
    ensure
      if HOMEBREW_CACHE.exist?
        if ARGV.include? "--clean-cache"
          HOMEBREW_CACHE.children.each(&:rmtree)
        else
          Dir.glob("*.bottle*.tar.gz") do |bottle_file|
            FileUtils.rm_f HOMEBREW_CACHE/bottle_file
          end
        end
      end

      Homebrew.failed = any_errors
    end

    def sanitize_output_for_xml(output)
      return output if output.empty?

      # Remove invalid XML CData characters from step output.
      invalid_xml_pat =
        /[^\x09\x0A\x0D\x20-\uD7FF\uE000-\uFFFD\u{10000}-\u{10FFFF}]/
      output.gsub!(invalid_xml_pat, "\uFFFD")

      return output if output.bytesize <= MAX_STEP_OUTPUT_SIZE

      # Truncate to 1MB to avoid hitting CI limits
      output =
        truncate_text_to_approximate_size(
          output, MAX_STEP_OUTPUT_SIZE, front_weight: 0.0
        )
      "truncated output to 1MB:\n#{output}"
    end
  end
end
