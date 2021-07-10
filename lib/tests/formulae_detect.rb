# frozen_string_literal: true

module Homebrew
  module Tests
    class FormulaeDetect < Test
      attr_reader :testing_formulae, :added_formulae, :deleted_formulae

      def initialize(argument, tap:, git:, dry_run:, fail_fast:, verbose:)
        super(tap: tap, git: git, dry_run: dry_run, fail_fast: fail_fast, verbose: verbose)

        @argument = argument
        @added_formulae = []
        @deleted_formulae = []
      end

      def run!(args:)
        detect_formulae!(args: args)

        return unless ENV["GITHUB_ACTIONS"]

        puts "::set-output name=testing_formulae::#{@testing_formulae.join(",")}"
        puts "::set-output name=added_formulae::#{@added_formulae.join(",")}"
        puts "::set-output name=deleted_formulae::#{@deleted_formulae.join(",")}"
      end

      private

      def detect_formulae!(args:)
        test_header(:FormulaeDetect, method: :detect_formulae!)

        url = nil
        origin_ref = "origin/master"

        if @argument == "HEAD"
          @testing_formulae = []
          # Use GitHub Actions variables for pull request jobs.
          if ENV["GITHUB_REF"].present? && ENV["GITHUB_REPOSITORY"].present? &&
             %r{refs/pull/(?<pr>\d+)/merge} =~ ENV["GITHUB_REF"]
            url = "https://github.com/#{ENV["GITHUB_REPOSITORY"]}/pull/#{pr}/checks"
          end
        elsif (canonical_formula_name = safe_formula_canonical_name(@argument, args: args))
          @testing_formulae = [canonical_formula_name]
        else
          raise UsageError,
                "#{@argument} is not detected from GitHub Actions or a formula name!"
        end

        if ENV["GITHUB_REPOSITORY"].blank? || ENV["GITHUB_SHA"].blank? || ENV["GITHUB_REF"].blank?
          if ENV["GITHUB_ACTIONS"]
            odie <<~EOS
              We cannot find the needed GitHub Actions environment variables! Check you have e.g. exported them to a Docker container.
            EOS
          elsif ENV["CI"]
            onoe <<~EOS
              No known CI provider detected! If you are using GitHub Actions then we cannot find the expected environment variables! Check you have e.g. exported them to a Docker container.
            EOS
          end
        elsif tap.present? && tap.full_name.casecmp(ENV["GITHUB_REPOSITORY"]).zero?
          # Use GitHub Actions variables for pull request jobs.
          if ENV["GITHUB_BASE_REF"].present?
            unless tap.official?
              test git, "-C", repository, "fetch",
                   "origin", "+refs/heads/#{ENV["GITHUB_BASE_REF"]}"
            end
            origin_ref = "origin/#{ENV["GITHUB_BASE_REF"]}"
            diff_start_sha1 = rev_parse(origin_ref)
            diff_end_sha1 = ENV["GITHUB_SHA"]
          # Use GitHub Actions variables for branch jobs.
          else
            test git, "-C", repository, "fetch", "origin", "+#{ENV["GITHUB_REF"]}" unless tap.official?
            origin_ref = "origin/#{ENV["GITHUB_REF"].gsub(%r{^refs/heads/}, "")}"
            diff_end_sha1 = diff_start_sha1 = ENV["GITHUB_SHA"]
          end
        end

        if diff_start_sha1.present? && diff_end_sha1.present?
          merge_base_sha1 =
            Utils.safe_popen_read(git, "-C", repository, "merge-base",
                                  diff_start_sha1, diff_end_sha1).strip
          diff_start_sha1 = merge_base_sha1 if merge_base_sha1.present?
        end

        diff_start_sha1 = current_sha1 if diff_start_sha1.blank?
        diff_end_sha1 = current_sha1 if diff_end_sha1.blank?

        diff_start_sha1 = diff_end_sha1 if @testing_formulae.present?

        if tap
          tap_origin_ref_revision_args =
            [git, "-C", tap.path.to_s, "log", "-1", "--format=%h (%s)", origin_ref]
          tap_origin_ref_revision = if args.dry_run?
            # May fail on dry run as we've not fetched.
            Utils.popen_read(*tap_origin_ref_revision_args).strip
          else
            Utils.safe_popen_read(*tap_origin_ref_revision_args)
          end.strip
          tap_revision = Utils.safe_popen_read(
            git, "-C", tap.path.to_s,
            "log", "-1", "--format=%h (%s)"
          ).strip
        end

        puts <<-EOS
    url               #{url.presence                     || "(blank)"}
    tap #{origin_ref} #{tap_origin_ref_revision.presence || "(blank)"}
    HEAD              #{tap_revision.presence            || "(blank)"}
    diff_start_sha1   #{diff_start_sha1.presence         || "(blank)"}
    diff_end_sha1     #{diff_end_sha1.presence           || "(blank)"}
        EOS

        modified_formulae = []

        if tap && diff_start_sha1 != diff_end_sha1
          formula_path = tap.formula_dir.to_s
          @added_formulae +=
            diff_formulae(diff_start_sha1, diff_end_sha1, formula_path, "A")
          modified_formulae +=
            diff_formulae(diff_start_sha1, diff_end_sha1, formula_path, "M")
          @deleted_formulae +=
            diff_formulae(diff_start_sha1, diff_end_sha1, formula_path, "D")
        end

        if args.test_default_formula?
          # Build the default test formula.
          @test_default_formula = true
          modified_formulae << "testbottest"
        end

        @testing_formulae += @added_formulae + modified_formulae

        if @testing_formulae.blank? && @deleted_formulae.blank? && diff_start_sha1 == diff_end_sha1
          raise UsageError, "Did not find any formulae or commits to test!"
        end

        puts <<-EOS

    testing_formulae  #{@testing_formulae.join(" ").presence || "(none)"}
    added_formulae    #{@added_formulae.join(" ").presence   || "(none)"}
    modified_formulae #{modified_formulae.join(" ").presence || "(none)"}
    deleted_formulae  #{@deleted_formulae.join(" ").presence || "(none)"}
        EOS
      end

      def safe_formula_canonical_name(formula_name, args:)
        Formulary.factory(formula_name).full_name
      rescue TapFormulaUnavailableError => e
        raise if e.tap.installed?

        test "brew", "tap", e.tap.name
        retry unless steps.last.failed?
        onoe e
        puts e.backtrace if args.debug?
      rescue FormulaUnavailableError, TapFormulaAmbiguityError,
             TapFormulaWithOldnameAmbiguityError => e
        onoe e
        puts e.backtrace if args.debug?
      end

      def rev_parse(ref)
        Utils.popen_read(git, "-C", repository, "rev-parse", "--verify", ref).strip
      end

      def current_sha1
        rev_parse("HEAD")
      end

      def diff_formulae(start_revision, end_revision, path, filter)
        return unless tap

        Utils.safe_popen_read(
          git, "-C", repository,
          "diff-tree", "-r", "--name-only", "--diff-filter=#{filter}",
          start_revision, end_revision, "--", path
        ).lines.map do |line|
          file = Pathname.new line.chomp
          next unless tap.formula_file?(file)

          tap.formula_file_to_name(file)
        end.compact
      end
    end
  end
end
