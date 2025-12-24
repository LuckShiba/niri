# This flake file is community maintained
{
  description = "Niri: A scrollable-tiling Wayland compositor.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    naersk = {
      url = "github:nix-community/naersk";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # NOTE: This is not necessary for end users
    # You can omit it with `inputs.rust-overlay.follows = ""`
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      naersk,
      rust-overlay,
    }:
    let
      niri-package =
        {
          lib,
          callPackage,
          cairo,
          dbus,
          libGL,
          libdisplay-info,
          libinput,
          seatd,
          libxkbcommon,
          libgbm,
          pango,
          pipewire,
          pkg-config,
          systemd,
          wayland,
          installShellFiles,
          clang,
          withDbus ? true,
          withSystemd ? true,
          withScreencastSupport ? true,
          withDinit ? false
        }:

        let
          naersk' = callPackage naersk {};
        in
        naersk'.buildPackage {
          pname = "niri";
          # Use a stable version for the deps derivation to enable caching
          version = "unstable";

          src = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./niri-config
              ./niri-ipc
              ./niri-visual-tests
              ./resources
              ./src
              ./Cargo.toml
              ./Cargo.lock
            ];
          };

          overrideMain = old: {
            # Set the actual version here (doesn't affect build and deps caching)
            version = self.shortRev or self.dirtyShortRev or "unknown";

            # Silence warning since we're intentionally overriding version without src
            __intentionallyOverridingVersion = true;
            
            postPatch = ''
              patchShebangs resources/niri-session
              substituteInPlace resources/niri.service \
                --replace-fail '/usr/bin' "$out/bin"
            '';
          };

          nativeBuildInputs = [
            pkg-config
            installShellFiles
            clang
          ];

          buildInputs =
            [
              cairo
              dbus
              libGL
              libdisplay-info
              libinput
              seatd
              libxkbcommon
              libgbm
              pango
              wayland
            ]
            ++ lib.optional (withDbus || withScreencastSupport || withSystemd) dbus
            ++ lib.optional withScreencastSupport pipewire
            # Also includes libudev
            ++ lib.optional withSystemd systemd;

          LIBCLANG_PATH = "${clang.cc.lib}/lib";

          cargoBuildOptions = old: old ++ [
            "--features"
            (lib.concatStringsSep "," (
              lib.optional withDbus "dbus"
              ++ lib.optional withDinit "dinit"
              ++ lib.optional withScreencastSupport "xdp-gnome-screencast"
              ++ lib.optional withSystemd "systemd"
            ))
            "--no-default-features"
          ];

          # ever since this commit:
          # https://github.com/YaLTeR/niri/commit/771ea1e81557ffe7af9cbdbec161601575b64d81
          # niri now runs an actual instance of the real compositor (with a mock backend) during tests
          # and thus creates a real socket file in the runtime dir.
          # this is fine for our build, we just need to make sure it has a directory to write to.
          preCheck = ''
            export XDG_RUNTIME_DIR="$(mktemp -d)"
          '';

          cargoTestOptions = old: old ++ [
            # These tests require the ability to access a "valid EGL Display", but that won't work
            # inside the Nix sandbox
            "--"
            "--skip=::egl"
          ];

          postInstall =
            ''
              installShellCompletion --cmd niri \
                --bash <($out/bin/niri completions bash) \
                --fish <($out/bin/niri completions fish) \
                --nushell <($out/bin/niri completions nushell) \
                --zsh <($out/bin/niri completions zsh)

              install -Dm644 resources/niri.desktop -t $out/share/wayland-sessions
              install -Dm644 resources/niri-portals.conf -t $out/share/xdg-desktop-portal
            ''
            + lib.optionalString withSystemd ''
              install -Dm755 resources/niri-session $out/bin/niri-session
              install -Dm644 resources/niri{.service,-shutdown.target} -t $out/share/systemd/user
            '';

          # Force linking with libEGL and libwayland-client
          RUSTFLAGS = toString (
            map (arg: "-C link-arg=" + arg) [
              "-Wl,--push-state,--no-as-needed"
              "-lEGL"
              "-lwayland-client"
              "-Wl,--pop-state"
            ]
          );

          passthru = {
            providedSessions = [ "niri" ];
          };

          meta = {
            description = "Scrollable-tiling Wayland compositor";
            homepage = "https://github.com/YaLTeR/niri";
            license = lib.licenses.gpl3Only;
            mainProgram = "niri";
            platforms = lib.platforms.linux;
          };
        };

      inherit (nixpkgs) lib;
      # Support all Linux systems that the nixpkgs flake exposes
      systems = lib.intersectLists lib.systems.flakeExposed lib.platforms.linux;

      forAllSystems = lib.genAttrs systems;
      nixpkgsFor = forAllSystems (system: nixpkgs.legacyPackages.${system});
    in
    {
      checks = forAllSystems (system: {
        inherit (self.packages.${system}) niri;
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor.${system};
          rust-bin = rust-overlay.lib.mkRustBin { } pkgs;
          inherit (self.packages.${system}) niri;
        in
        {
          default = pkgs.mkShell {
            packages = [
              # We don't use the toolchain from nixpkgs
              # because we prefer a nightly toolchain
              # and we *require* a nightly rustfmt
              (rust-bin.selectLatestNightlyWith (
                toolchain:
                toolchain.default.override {
                  extensions = [
                    # includes already:
                    # rustc
                    # cargo
                    # rust-std
                    # rust-docs
                    # rustfmt-preview
                    # clippy-preview
                    "rust-analyzer"
                    "rust-src"
                  ];
                }
              ))
              pkgs.cargo-insta
            ];

            nativeBuildInputs = [
              pkgs.rustPlatform.bindgenHook
              pkgs.pkg-config
              pkgs.wrapGAppsHook4 # For `niri-visual-tests`
            ];

            buildInputs = niri.buildInputs ++ [
              pkgs.libadwaita # For `niri-visual-tests`
            ];

            env = {
              # WARN: Do not overwrite this variable in your shell!
              # It is required for `dlopen()` to work on some libraries; see the comment
              # in the package expression
              #
              # This should only be set with `CARGO_BUILD_RUSTFLAGS="$CARGO_BUILD_RUSTFLAGS -C your-flags"`
              CARGO_BUILD_RUSTFLAGS = niri.RUSTFLAGS;
            };
          };
        }
      );

      formatter = forAllSystems (system: nixpkgsFor.${system}.nixfmt-rfc-style);

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor.${system};
          niri = pkgs.callPackage niri-package { };
        in
        {
          inherit niri;
          default = niri;
        }
      );

      overlays.default = final: _: {
        niri = final.callPackage niri-package { };
      };
    };
}
