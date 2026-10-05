{
  description = "Mardi Gras - a BubbleTea TUI for Beads issues";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # mg has no manifest naming its version: `make build` and the release
      # workflow both read it off the git tag, and a nix build has neither git
      # nor tags. CHANGELOG.md's newest heading is the one place in the tree
      # that states a version, and the release commit that writes it is the
      # commit the tag is cut from — so a `nix build` of a release answers
      # `mg --version` with that release rather than the "dev" the ldflag
      # defaults to.
      #
      # A heading that stops reading `## vX.Y.Z` throws, for the reason the
      # version pin throws in the flake this one is modelled on: a pin that
      # silently matches nothing reads exactly like one that worked, and this
      # one would go on shipping "dev" in release binaries without anything
      # failing to say so.
      version =
        let
          headings = builtins.filter
            (line: builtins.match "## v[0-9]+\\.[0-9]+\\.[0-9]+.*" line != null)
            (nixpkgs.lib.splitString "\n" (builtins.readFile ./CHANGELOG.md));
        in
        if headings == [ ]
        then throw "CHANGELOG.md no longer opens an entry with `## vX.Y.Z`, so the build cannot name the version it is building"
        else builtins.head (builtins.match "## v([0-9]+\\.[0-9]+\\.[0-9]+).*" (builtins.head headings));

      # Every check is built from a source tree, and nix hashes the whole of
      # the one it is handed. So a file in there that no check reads still
      # gives every check a derivation nothing has built before, and the run
      # rebuilds all of them for a verdict the tree already has: a pull
      # request changing only README.md would pay for the entire suite.
      #
      # An allowlist rather than an exclude list — a file that arrives later
      # is out until somebody says so. Out is also the safe direction: a check
      # that needed the file fails saying it is missing, where an exclude list
      # that forgot it goes on quietly rebuilding.
      sourceOf = paths: nixpkgs.lib.fileset.toSource {
        root = ./.;
        fileset = nixpkgs.lib.fileset.unions paths;
      };

      # What the compiler, the tests and golangci-lint read, and nothing else.
      # The testdata entries are the ones tests reach for by relative path:
      # internal/data and internal/tmux load testdata/sample.jsonl, and
      # internal/app puts testdata/ on PATH so gastown.Detect finds a `gt`
      # there (testdata/gt is a symlink to fake-gt.sh, so both have to be
      # here — exec.LookPath only looks, it never runs it). The rest of
      # testdata/ is vhs tapes and fake servers for `make dev-*`, which no
      # test reads.
      source = sourceOf [
        ./go.mod
        ./go.sum
        ./.golangci.yml
        ./cmd
        ./internal
        ./testdata/sample.jsonl
        ./testdata/gt
        ./testdata/fake-gt.sh
      ];

      # The overlay and the per-system outputs are the same package, so a
      # consumer taking either gets what CI built.
      mardiGrasFor = pkgs: pkgs.buildGoModule {
        pname = "mardi-gras";
        inherit version;
        src = source;

        # Keyed on go.mod and go.sum alone, so every edit to the source reuses
        # one module download. After a dependency change nix prints the hash
        # it wanted; `lib.fakeHash` here is how to make it print one.
        vendorHash = "sha256-Ji7ij19/4akUex2gabqrnWFQlr+XvDlHKVg8FxZQ97A=";

        # What the Makefile and .goreleaser.yaml pass, so the three builds of
        # this binary differ in nothing a user can see.
        ldflags = [ "-s" "-w" "-X main.version=${version}" ];

        # Nothing in the module uses cgo and the release binaries are built
        # without it, so this one is a static Go binary too.
        env.CGO_ENABLED = 0;

        # data.CurrentActor asks git for user.name, and TestCurrentActor
        # expects the answer a machine with git gives. Only the check phase
        # needs it: nothing at runtime is built against git, and mg falls back
        # to $USER wherever it is missing.
        nativeCheckInputs = [ pkgs.git ];

        # No subPackages, so the build is `go build ./...` and the check phase
        # `go test ./...` — which is what lets this package stand as the
        # build-and-test check below. Naming cmd/mg would install the same one
        # binary and quietly stop testing internal/, where all but one of the
        # test files live.

        meta = with pkgs.lib; {
          description = "Terminal UI for Beads issue tracking - your issues deserve a parade";
          homepage = "https://github.com/quietpublish/mardi-gras";
          license = licenses.mit;
          # The package is named for the project, the binary for the command.
          mainProgram = "mg";
        };
      };

      # Not eachDefaultSystem: nixpkgs unstable has dropped x86_64-darwin, so
      # the flake cannot evaluate there. An Intel Mac takes the release
      # archive, which goreleaser builds without nix.
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
    in
    flake-utils.lib.eachSystem systems (system:
      let
        pkgs = import nixpkgs { inherit system; };

        mardi-gras = mardiGrasFor pkgs;

        goTools = [
          pkgs.go
          pkgs.gopls
          pkgs.gotools
          pkgs.go-tools
          pkgs.golangci-lint
          pkgs.git
        ];

        # A check runs against the same source and the same module cache as
        # the build, so the two cannot drift apart: it is the package with its
        # build phase replaced, inheriting the modules that build already
        # downloaded. Hand it `null` where the command compiles nothing — so
        # gofmt can say a file is misformatted without waiting on a module
        # download — and it reads the source tree directly instead.
        checkOf = name: modules: tools: command:
          if modules == null then
            pkgs.runCommand "mardi-gras-${name}" { nativeBuildInputs = tools; } ''
              cd ${source}
              ${command}
              touch $out
            ''
          else
            modules.overrideAttrs (build: {
              pname = "${build.pname}-${name}";
              nativeBuildInputs = build.nativeBuildInputs ++ tools;
              buildPhase = ''
                runHook preBuild
                ${command}
                runHook postBuild
              '';
              # The command above is the whole of the check. Leaving the
              # package's own test phase on would run the suite inside every
              # one of these, which is what build-and-test is for.
              doCheck = false;
              installPhase = "touch $out";
              dontFixup = true;
            });
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = goTools;

          shellHook = ''
            # The banner is diagnostic, so it goes where nix puts its own
            # diagnostics. On stdout it corrupts every `nix develop -c … --json`
            # a caller pipes into a parser.
            echo "⚜  Mardi Gras development shell" >&2
            # Print where go resolved from, not just what it claims to be — a
            # version alone cannot distinguish this shell's go from PATH's.
            echo "go: $(go version | cut -d' ' -f3) ($(command -v go))" >&2
          '';
        };

        packages.default = mardi-gras;
        packages.mardi-gras = mardi-gras;

        # `nix flake check` is the build, the test suite, gofmt, golangci-lint
        # and go vet — what .github/workflows/ci.yml runs, bar the race build
        # and the coverage floor. Anything CI should run belongs here, not
        # only in the workflow.
        checks = {
          # buildGoModule tests what it builds, so the package is the test
          # run. CI additionally builds it under -race, which needs cgo and a
          # C toolchain; this is the plain build a release ships.
          build-and-test = mardi-gras;

          fmt = checkOf "fmt" null [ pkgs.go ] ''
            unformatted="$(gofmt -l .)"
            if [ -n "$unformatted" ]; then
              echo "These files are not gofmt'd:"
              printf '%s\n' "$unformatted"
              echo
              echo "Run \`make fmt\`."
              exit 1
            fi
          '';

          # The workflow pins golangci-lint v2.11 and this takes whatever
          # nixpkgs carries, so the two can disagree about the tree in front
          # of them — and have: the 2.10.1 in the nixpkgs this flake was
          # locked to on arrival reported four gosec findings (G602, and G704
          # at each place mg requests an operator-configured URL) that v2.11
          # and 2.14.0 both pass. A nixpkgs bump that reintroduces one shows
          # up here as a failing check on a tree CI is green on; the fix is to
          # bring the two versions back together, not to silence this.
          lint = checkOf "lint" mardi-gras [ pkgs.golangci-lint ] ''
            # golangci-lint keeps a cache of its own, and the sandbox's HOME
            # is not writable.
            export GOLANGCI_LINT_CACHE="$TMPDIR/golangci-lint"
            golangci-lint run ./...
          '';

          vet = checkOf "vet" mardi-gras [ ] "go vet ./...";
        };
      }
    ) // {
      # Overlays carry no system, so this sits outside eachSystem. A consumer
      # adds it to nixpkgs.overlays and reaches pkgs.mardi-gras.
      #
      # pkgs.mardi-gras is the package above, built against this flake's own
      # nixpkgs rather than the consumer's, because that is the derivation CI
      # built: against `final` it is a derivation nothing has built, and every
      # nixpkgs bump on the consumer's side recompiles a tool that has not
      # changed. pkgs.mardi-gras-rebuilt is that build, for a consumer who
      # wants mg linked against their own nixpkgs and will pay for it.
      overlays.default = final: _prev: {
        mardi-gras = self.packages.${final.stdenv.hostPlatform.system}.mardi-gras;
        mardi-gras-rebuilt = mardiGrasFor final;
      };
    };
}
