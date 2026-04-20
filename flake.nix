{
  description = "Handy - A free, open source, and extensible speech-to-text application that works completely offline";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # bun2nix: generates per-package Nix fetchurl expressions from bun.lock,
    # replacing the old FOD approach where a single hash covered the entire
    # node_modules directory (that hash would break on bun version changes).
    # See: https://github.com/nix-community/bun2nix
    bun2nix = {
      url = "github:nix-community/bun2nix/2.0.8";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      bun2nix,
    }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        # Darwin support lives on debug/darwin-flake branch only — used to
        # reproduce the cargo-tauri stub-binary issue philocalyst hit in
        # NixOS/nixpkgs#507754 (see tmp/pending-tasks.md). Not for upstream.
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      cargoToml = fromTOML (builtins.readFile ./src-tauri/Cargo.toml);
      version = cargoToml.package.version;

      # Verified on philocalyst/nixpkgs#1 with bun 1.3.11 at Handy merge commit
      # af6ec6c (squash of cjpais/Handy#1256, content identical to PR head
      # 681c6a9). Recompute via normalize-install.ts on version bump.
      frontendDepsHashes = {
        "x86_64-linux" = "sha256-tJ6LK99dELOiR0BcsTRTt/vLyNamntujLxhBy5Xl/lc=";
        "aarch64-linux" = "sha256-S+dX6ZVgv9dexxIHoa5PxP7e0nxf/d7cKUGty5eEi8A=";
        "aarch64-darwin" = "sha256-DQbogNBQ9izK5GPmoOudqiB2lJvct1vZI2U5lp3WFy8=";
      };

      linuxNativeDeps = pkgs: with pkgs; [
        webkitgtk_4_1
        gtk3
        glib
        libsoup_3
        alsa-lib
        libayatana-appindicator
        libevdev
        libxtst
        gtk-layer-shell
        vulkan-loader
        vulkan-headers
        shaderc
      ];

      gstPlugins = pkgs: with pkgs.gst_all_1; [
        gstreamer
        gst-plugins-base
        gst-plugins-good
        gst-plugins-bad
        gst-plugins-ugly
      ];

    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ bun2nix.overlays.default ];
          };
          lib = pkgs.lib;
          isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
          isLinux = pkgs.stdenv.hostPlatform.isLinux;

          combinedAlsaPlugins = pkgs.symlinkJoin {
            name = "combined-alsa-plugins";
            paths = [
              "${pkgs.pipewire}/lib/alsa-lib"
              "${pkgs.alsa-plugins}/lib/alsa-lib"
            ];
          };

          # FOD path for frontend deps — used on Darwin because bun2nix's
          # bun.lock-based fetch has not been verified on Darwin yet. Linux
          # keeps the bun2nix path below.
          frontendDeps = pkgs.stdenv.mkDerivation {
            pname = "handy-frontend-deps";
            inherit version;
            src = self;
            nativeBuildInputs = [ pkgs.bun ];
            dontConfigure = true;
            buildPhase = ''
              runHook preBuild
              export HOME=$(mktemp -d)
              export BUN_INSTALL_CACHE_DIR=$(mktemp -d)
              bun install --linker=isolated --force --frozen-lockfile \
                --ignore-scripts --no-progress
              bun --bun "$PWD/.nix/scripts/normalize-install.ts"
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p $out
              cp -R node_modules $out/
              runHook postInstall
            '';
            dontFixup = true;
            outputHash = frontendDepsHashes.${system} or (throw ''
              handy: no frontendDeps hash for ${system}.
            '');
            outputHashMode = "recursive";
          };

          # Experiment A: add -parse-as-library to swiftc invocation.
          # Tests the hypothesis that swiftc's default script mode is
          # emitting an empty _main that shadows Rust's. If _main becomes
          # a proper Rust entry after this, A is confirmed.
          patchParseAsLibrary = ''
            sed -i 's|            "-target",|            "-parse-as-library",\n            "-target",|' src-tauri/build.rs
          '';

          # Experiment B: overwrite the stub swift file with minimal content
          # (only @_cdecl function declarations, no `import`, no typealias).
          # Tests whether the top-level `import Foundation` + typealias trigger
          # script mode. If _main becomes real, B is confirmed.
          patchMinimalSwiftStub = ''
            cat > src-tauri/swift/apple_intelligence_stub.swift <<'MINIMAL_STUB'
            @_cdecl("is_apple_intelligence_available")
            public func isAppleIntelligenceAvailable() -> Int32 { return 0 }

            @_cdecl("process_text_with_system_prompt_apple")
            public func processTextWithSystemPrompt(
                _ systemPrompt: UnsafePointer<CChar>,
                _ userContent: UnsafePointer<CChar>,
                maxTokens: Int32
            ) -> UnsafeMutablePointer<AppleLLMResponse> {
                let ptr = UnsafeMutablePointer<AppleLLMResponse>.allocate(capacity: 1)
                ptr.initialize(to: AppleLLMResponse(response: nil, success: 0, error_message: nil))
                return ptr
            }

            @_cdecl("free_apple_llm_response")
            public func freeAppleLLMResponse(_ response: UnsafeMutablePointer<AppleLLMResponse>?) {
                response?.deallocate()
            }
            MINIMAL_STUB
          '';

          mkHandy =
            { pname, extraPostPatch ? "", extraNativeBuildInputs ? [ ] }:
            pkgs.rustPlatform.buildRustPackage ({
            inherit pname;
            inherit version;
            src = self;

            cargoRoot = "src-tauri";

            cargoLock = {
              lockFile = ./src-tauri/Cargo.lock;
              allowBuiltinFetchGit = true;
            };

            postPatch = ''
              ${pkgs.jq}/bin/jq '
                del(.build.beforeBuildCommand) |
                .bundle.createUpdaterArtifacts = false |
                .bundle.macOS.signingIdentity = null |
                .bundle.macOS.hardenedRuntime = false
              ' src-tauri/tauri.conf.json > $TMPDIR/tauri.conf.json
              cp $TMPDIR/tauri.conf.json src-tauri/tauri.conf.json

              ${pkgs.jq}/bin/jq 'del(.scripts.postinstall)' \
                package.json > $TMPDIR/package.json
              cp $TMPDIR/package.json package.json

              # cbindgen's cargo metadata fails in the sandbox
              substituteInPlace $cargoDepsCopy/ferrous-opencc-0.2.3/build.rs \
                --replace-fail '.expect("Unable to generate bindings")' '.ok();'
              substituteInPlace $cargoDepsCopy/ferrous-opencc-0.2.3/build.rs \
                --replace-fail '.write_to_file("opencc.h");' '// skipped'
            ''
            + lib.optionalString isLinux ''
              substituteInPlace \
                $cargoDepsCopy/libappindicator-sys-*/src/lib.rs \
                --replace-fail \
                  "libayatana-appindicator3.so.1" \
                  "${pkgs.libayatana-appindicator}/lib/libayatana-appindicator3.so.1"
            ''
            + lib.optionalString isDarwin ''
              patch -p1 < ${./nix/use-nix-swift.patch}
            ''
            + extraPostPatch;

            nativeBuildInputs = with pkgs; [
              cargo-tauri.hook
              pkg-config
              bun
              jq
              cmake
              rustPlatform.bindgenHook
            ]
            ++ lib.optionals isLinux (with pkgs; [
              wrapGAppsHook4
              pkgs.bun2nix.hook
              shaderc
            ])
            ++ lib.optionals isDarwin (with pkgs; [
              nodejs
              makeBinaryWrapper
              cctools
              swift
            ])
            ++ extraNativeBuildInputs;

            preBuild =
              lib.optionalString isDarwin ''
                cp -R ${frontendDeps}/node_modules .
                chmod -R u+w node_modules
                patchShebangs node_modules
              ''
              + ''
                export HOME=$TMPDIR
                bun run build
              '';

            doCheck = false;

            installPhase = ''
              runHook preInstall
              mkdir -p $out
            ''
            + lib.optionalString isLinux ''
              cd src-tauri
              mv target/${pkgs.stdenv.hostPlatform.rust.rustcTarget}/release/bundle/deb/*/data/usr/* $out/
            ''
            + lib.optionalString isDarwin ''
              mkdir -p $out/Applications $out/bin $out/debug
              # Capture the pre-bundle cargo output BEFORE the bundle move.
              # If this has the stub _main too, the bug is upstream of
              # cargo-tauri's bundling step.
              cp "src-tauri/target/${pkgs.stdenv.hostPlatform.rust.rustcTarget}/release/handy" \
                 "$out/debug/handy-prebundle" || echo "prebundle copy failed"
              mv src-tauri/target/${pkgs.stdenv.hostPlatform.rust.rustcTarget}/release/bundle/macos/Handy.app \
                $out/Applications/
              makeWrapper "$out/Applications/Handy.app/Contents/MacOS/handy" "$out/bin/handy"
            ''
            + ''
              runHook postInstall
            '';

            buildInputs = [
              pkgs.onnxruntime
              pkgs.openssl
            ]
            ++ lib.optionals isLinux (linuxNativeDeps pkgs ++ (with pkgs; [
              glib-networking
              libx11
            ]) ++ gstPlugins pkgs);

            env = {
              ORT_LIB_LOCATION = "${pkgs.onnxruntime}/lib";
              ORT_PREFER_DYNAMIC_LINK = "1";
              OPENSSL_NO_VENDOR = "1";
            }
            // lib.optionalAttrs isLinux {
              GST_PLUGIN_SYSTEM_PATH_1_0 = lib.makeSearchPathOutput "lib" "lib/gstreamer-1.0" (gstPlugins pkgs);
            }
            // lib.optionalAttrs isDarwin {
              SWIFTC = "${pkgs.swift}/bin/swiftc";
            };

            preFixup = lib.optionalString isLinux ''
              gappsWrapperArgs+=(
                --set WEBKIT_DISABLE_DMABUF_RENDERER 1
                --set ALSA_PLUGIN_DIR "${combinedAlsaPlugins}"
                --prefix LD_LIBRARY_PATH : "${
                  lib.makeLibraryPath [
                    pkgs.vulkan-loader
                    pkgs.onnxruntime
                  ]
                }"
              )
            '';

            # DYLD_LIBRARY_PATH is blocked by SIP on macOS, so patch rpath
            postFixup = lib.optionalString isDarwin ''
              install_name_tool -add_rpath ${pkgs.onnxruntime}/lib \
                "$out/Applications/Handy.app/Contents/MacOS/handy"
            '';

            passthru = lib.optionalAttrs isDarwin { inherit frontendDeps; };

            meta = {
              description = "A free, open source, and extensible speech-to-text application that works completely offline";
              homepage = "https://github.com/cjpais/Handy";
              license = lib.licenses.mit;
              mainProgram = "handy";
              platforms = supportedSystems;
            };
          }
          // lib.optionalAttrs isLinux {
            bunDeps = pkgs.bun2nix.fetchBunDeps {
              bunNix = ./.nix/bun.nix;
            };
          });

        in
        {
          # Baseline: current Darwin build producing the stub _main.
          handy = mkHandy { pname = "handy"; };

          # A: add swiftc -parse-as-library
          handy-parse-as-library = mkHandy {
            pname = "handy-parse-as-library";
            extraPostPatch = lib.optionalString isDarwin patchParseAsLibrary;
          };

          # B: swap the swift stub file for a minimal declarations-only version
          handy-minimal-swift = mkHandy {
            pname = "handy-minimal-swift";
            extraPostPatch = lib.optionalString isDarwin patchMinimalSwiftStub;
          };

          # C: add apple-sdk_26 (FoundationModels) so build.rs compiles the
          # real swift file (and exposes SDKROOT via its setup hook).
          handy-sdk26 = mkHandy {
            pname = "handy-sdk26";
            extraNativeBuildInputs = lib.optionals isDarwin [ pkgs.apple-sdk_26 ];
          };

          default = self.packages.${system}.handy;
        }
      );

      nixosModules.default =
        { lib, pkgs, ... }:
        {
          imports = [ ./nix/module.nix ];
          programs.handy.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.handy;
        };

      homeManagerModules.default =
        { lib, pkgs, ... }:
        {
          imports = [ ./nix/hm-module.nix ];
          services.handy.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.handy;
        };

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          lib = pkgs.lib;
          isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
        in
        {
          default = pkgs.mkShell {
            buildInputs =
              (with pkgs; [
                rustc
                cargo
                rust-analyzer
                clippy
                nodejs
                bun
                cargo-tauri
                pkg-config
                rustPlatform.bindgenHook
                cmake
              ])
              ++ lib.optionals (!isDarwin) (linuxNativeDeps pkgs);

            ORT_LIB_LOCATION = "${pkgs.onnxruntime}/lib";
            ORT_PREFER_DYNAMIC_LINK = "1";

            GST_PLUGIN_SYSTEM_PATH_1_0 = lib.optionalString (!isDarwin) (
              lib.makeSearchPathOutput "lib" "lib/gstreamer-1.0" (gstPlugins pkgs)
            );

            LD_LIBRARY_PATH = lib.optionalString (!isDarwin) (
              lib.makeLibraryPath [
                pkgs.libayatana-appindicator
                pkgs.onnxruntime
                pkgs.vulkan-loader
              ]
            );

            XDG_DATA_DIRS = lib.optionalString (!isDarwin) (
              "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}:${pkgs.hicolor-icon-theme}/share"
            );

            shellHook = ''
              echo "Handy development environment"
              bun install
              echo "Run 'bun run tauri dev' to start"
            '';
          };
        }
      );
    };
}
