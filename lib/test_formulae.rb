# frozen_string_literal: true

module Homebrew
  module Tests
    class TestFormulae < Test
      attr_accessor :skipped_or_failed_formulae

      def initialize(tap:, git:, dry_run:, fail_fast:, verbose:)
        super

        @skipped_or_failed_formulae = []
      end

      protected

      def bottle_glob(formula_name)
        Pathname.glob("#{formula_name}--*.#{Utils::Bottles.tag}.bottle*.tar.gz")
      end

      def install_formula_from_bottle(formula_name, testing_formulae_dependents:, dry_run:)
        bottle_filename = bottle_glob(formula_name).first
        if bottle_filename.blank?
          if testing_formulae_dependents && !dry_run
            raise "Failed to find bottle for '#{formula_name}'."
          elsif !dry_run
            return false
          end

          bottle_filename = "$BOTTLE_FILENAME"
        end

        install_args = []
        install_args += %w[--ignore-dependencies --skip-post-install] if testing_formulae_dependents
        test "brew", "install", *install_args, bottle_filename
        install_step = steps.last
        return install_step.passed? unless testing_formulae_dependents

        test "brew", "unlink", formula_name
        puts

        install_step.passed?
      end

      def bottled?(formula, no_older_versions: false)
        # If a formula has an `:all` bottle, then all its dependencies have
        # to be bottled too for us to use it. We only need to recurse
        # up the dep tree when we encounter an `:all` bottle because
        # a formula is not bottled unless its dependencies are.
        if formula.bottle_specification.tag?(Utils::Bottles.tag(:all))
          formula.deps.all? { |dep| bottled?(dep.to_formula, no_older_versions: no_older_versions) }
        else
          formula.bottle_specification.tag?(Utils::Bottles.tag, no_older_versions: no_older_versions)
        end
      end

      def bottled_or_built?(formula, built_formulae, no_older_versions: false)
        bottled?(formula, no_older_versions: no_older_versions) || built_formulae.include?(formula.full_name)
      end

      def downloads_using_homebrew_curl?(formula)
        [:stable, :head].any? do |spec_name|
          next false unless (spec = formula.send(spec_name))

          spec.using == :homebrew_curl || spec.resources.values.any? { |r| r.using == :homebrew_curl }
        end
      end

      def install_curl_if_needed(formula)
        return unless downloads_using_homebrew_curl?(formula)

        test "brew", "install", "curl",
             env: { "HOMEBREW_DEVELOPER" => nil }
      end

      def install_mercurial_if_needed(deps, reqs)
        return if (deps | reqs).none? { |d| d.name == "mercurial" && d.build? }

        test "brew", "install", "mercurial",
             env:  { "HOMEBREW_DEVELOPER" => nil }
      end

      def install_subversion_if_needed(deps, reqs)
        return if (deps | reqs).none? { |d| d.name == "subversion" && d.build? }

        test "brew", "install", "subversion",
             env:  { "HOMEBREW_DEVELOPER" => nil }
      end

      def skipped(formula_name, reason)
        @skipped_or_failed_formulae << formula_name

        puts Formatter.headline(
          "#{Formatter.warning("SKIPPED")} #{Formatter.identifier(formula_name)}",
          color: :yellow,
        )
        opoo reason
      end

      def failed(formula_name, reason)
        @skipped_or_failed_formulae << formula_name

        puts Formatter.headline(
          "#{Formatter.error("FAILED")} #{Formatter.identifier(formula_name)}",
          color: :red,
        )
        onoe reason
      end

      def unsatisfied_requirements_messages(formula)
        f = Formulary.factory(formula.full_name)
        fi = FormulaInstaller.new(f, build_bottle: true)

        unsatisfied_requirements, = fi.expand_requirements
        return if unsatisfied_requirements.blank?

        unsatisfied_requirements.values.flatten.map(&:message).join("\n").presence
      end

      def cleanup_during!(keep_formulae = [], args:)
        return unless args.cleanup?
        return unless HOMEBREW_CACHE.exist?

        free_gb = Utils.safe_popen_read({ "BLOCKSIZE" => (1000 ** 3).to_s }, "df", HOMEBREW_CACHE.to_s)
                       .lines[1] # HOMEBREW_CACHE
                       .split[3] # free GB
                       .to_i
        return if free_gb > 10

        test_header(:TestFormulae, method: :cleanup_during!)

        FileUtils.chmod_R "u+rw", HOMEBREW_CACHE, force: true
        test "rm", "-rf", HOMEBREW_CACHE.to_s

        if @cleaned_up_during.blank?
          @cleaned_up_during = true
          return
        end

        installed_formulae = Utils.safe_popen_read("brew", "list", "--full-name", "--formulae").split("\n")
        uninstallable_formulae = installed_formulae - keep_formulae

        @installed_formulae_deps ||= Hash.new do |h, formula|
          h[formula] = Utils.safe_popen_read("brew", "deps", "--full-name", formula).split("\n")
        end
        uninstallable_formulae.reject! do |name|
          keep_formulae.any? { |f| @installed_formulae_deps[f].include?(name) }
        end

        return if uninstallable_formulae.blank?

        test "brew", "uninstall", "--force", "--ignore-dependencies", *uninstallable_formulae
      end
    end
  end
end
