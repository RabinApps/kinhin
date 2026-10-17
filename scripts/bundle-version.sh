# Sourced by scripts/build-app.sh and scripts/appcast.sh; the one place that maps a release version to the bundle's
# CFBundleVersion. Sparkle decides "newer" by comparing that number, so it must grow with every release: a beta maps
# to X.Y.Z.N (its beta number) and a stable release to X.Y.Z.9999, which sorts above every beta of the same version.
#
#   bundle_version 0.0.1-beta-2   -> 0.0.1.2
#   bundle_version 0.0.1          -> 0.0.1.9999
bundle_version() {
    local version="$1"
    if [[ "$version" =~ ^([0-9.]+)-beta-([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    else
        echo "${version%%-*}.9999"
    fi
}
