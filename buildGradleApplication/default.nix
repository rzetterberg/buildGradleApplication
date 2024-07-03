{
  pkgs,
  lib,
  stdenvNoCC,
  writeShellScript,
  makeWrapper,
  mkM2Repository,
}: {
  pname,
  version,
  src,
  meta,
  jdk ? pkgs.jdk,
  gradle ? pkgs.gradle,
  buildInputs ? [],
  nativeBuildInputs ? [],
  dependencyFilter ? depSpec: true,
  repositories ? ["https://plugins.gradle.org/m2/" "https://repo1.maven.org/maven2/"],
  verificationFile ? "gradle/verification-metadata.xml",
  buildTask ? ":installDist",
  installLocation ? "build/install/*/",
}: let
  m2Repository = mkM2Repository {
    inherit pname version src dependencyFilter repositories verificationFile;
  };

  # Prepare a script that will replace that jars with references into the NIX store.
  linkScript = writeShellScript "link-to-jars" ''
    declare -A fileByName
    declare -A hashByName
    ${
      lib.concatMapStringsSep "\n"
      (dep: "fileByName[\"${dep.name}\"]=\"${builtins.toString dep.jar}\"\nhashByName[\"${dep.name}\"]=\"${builtins.toString dep.hash}\"")
      (builtins.filter (dep: (lib.strings.hasSuffix ".jar" dep.name && !lib.strings.hasSuffix "-javadoc.jar" dep.name && !lib.strings.hasSuffix "-sources.jar" dep.name)) m2Repository.dependencies)
    }

    for jar in "$1"/*.jar; do
      dep=''${fileByName[$(basename "$jar")]}
      if [[ -n "$dep" ]]; then
          jarHash=$(sha256sum "$jar" | cut -c -64)
          sriHash=''${hashByName[$(basename "$jar")]}
          if [[ $sriHash == sha256-* ]]; then
            referenceHash="$(echo ''${sriHash#sha256-} | base64 -d | ${pkgs.hexdump}/bin/hexdump -v -e '/1 "%02x"')"
          else
            referenceHash=$(sha256sum "$dep" | cut -c -64)
          fi

          if [[ "$referenceHash" == "$jarHash" ]]; then
            echo "Replacing $jar with nix store reference $dep"
            rm "$jar"
            ln -s "$dep" "$jar"
          else
            echo "Hash of $jar differs from expected store reference $dep"
          fi
      else
        echo "No linking candidate found for $jar"
      fi
    done
  '';

  package = stdenvNoCC.mkDerivation {
    inherit pname version src meta buildInputs;
    nativeBuildInputs = [gradle jdk makeWrapper] ++ nativeBuildInputs;
    buildPhase = ''
      runHook preBuild

      # Setup maven repo
      export MAVEN_SOURCE_REPOSITORY=${m2Repository.m2Repository}
      echo "Using maven repository at: $MAVEN_SOURCE_REPOSITORY"

      # create temporary gradle home
      export GRADLE_USER_HOME=$(mktemp -d)

      # Export application version to the build
      export APP_VERSION=${version}

      # built the dam thing!
      gradle --offline --no-daemon --no-watch-fs --no-configuration-cache --no-build-cache --console=plain --no-scan -Porg.gradle.java.installations.auto-download=false --init-script ${./init.gradle.kts} ${buildTask}

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      pushd ${installLocation}

      mkdir -p $out/lib/
      mv lib/*.jar $out/lib/
      echo ${linkScript} $out/lib/
      ${linkScript} $out/lib/

      if [ -d agent-libs/ ]; then
          mkdir -p $out/agent-libs/
          mv agent-libs/*.jar $out/agent-libs/
          ${linkScript} $out/agent-libs/
      fi

      mkdir -p $out/bin

      cp $(ls bin/* | grep -v ".bat") $out/bin/${pname}

      popd
      runHook postInstall
    '';

    dontWrapGApps = true;
    postFixup = ''
      wrapProgram $out/bin/${pname} \
        --set-default JAVA_HOME "${jdk.home}" \
        ''${gappsWrapperArgs[@]}
    '';
  };
in
  package
