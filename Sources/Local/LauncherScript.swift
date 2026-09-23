// The launcher `haruspec init` writes to `.haruspec/bin/haruspec`: the text of `Scripts/haruspec`,
// embedded so the CLI can install and refresh it. `LauncherScriptTests` fails if the two drift.

/// The launcher script, byte for byte the engine repository's `Scripts/haruspec`.
enum LauncherScript {
    /// The script's text.
    static let text = #"""
    #!/bin/bash
    # The haruspec launcher. Runs the haruspec CLI at exactly the engine version this project uses — a
    # local package it references, or the version its Package.resolved pins — building that CLI once
    # per version into ~/Library/Caches/haruspec. `haruspec init` writes it to .haruspec/bin/haruspec;
    # commit it, and everyone on the team runs `.haruspec/bin/haruspec check`.
    #
    # HARUSPEC_CLI=/path/to/haruspec skips all of this and runs that binary instead.
    set -euo pipefail

    say() { echo "haruspec launcher: $*" >&2; }

    if [ -n "${HARUSPEC_CLI:-}" ]; then
        exec "$HARUSPEC_CLI" "$@"
    fi

    root=$(git rev-parse --show-toplevel 2>/dev/null) || { say "run this inside a git repository"; exit 1; }
    cache="${HARUSPEC_CACHE:-$HOME/Library/Caches/haruspec}"

    # Prints the directory of a local package the project references whose Package.swift is Haruspec's.
    local_package() {
        local pbx rel dir
        for pbx in "$root"/*.xcodeproj/project.pbxproj; do
            [ -f "$pbx" ] || continue
            while IFS= read -r rel; do
                dir=$(cd "$(dirname "$pbx")/.." && cd "$rel" 2>/dev/null && pwd) || continue
                if [ -f "$dir/Package.swift" ] && grep -q 'name: "Haruspec"' "$dir/Package.swift"; then
                    echo "$dir"
                    return 0
                fi
            done < <(sed -n 's/^[[:space:]]*relativePath = "\{0,1\}\([^";]*\)"\{0,1\};/\1/p' "$pbx")
        done
        return 1
    }

    # Prints "<location> <revision>" for the haruspec pin in the project's Package.resolved.
    pinned() {
        local resolved i identity
        for resolved in "$root"/*.xcworkspace/xcshareddata/swiftpm/Package.resolved \
            "$root"/*.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
            "$root/Package.resolved"; do
            [ -f "$resolved" ] || continue
            i=0
            while identity=$(plutil -extract "pins.$i.identity" raw -o - "$resolved" 2>/dev/null); do
                if [ "$identity" = "haruspec" ]; then
                    echo "$(plutil -extract "pins.$i.location" raw -o - "$resolved")" \
                        "$(plutil -extract "pins.$i.state.revision" raw -o - "$resolved")"
                    return 0
                fi
                i=$((i + 1))
            done
        done
        return 1
    }

    # Builds the CLI in package directory $1, keeping the compiler's output in a log shown only on failure.
    build() {
        mkdir -p "$cache"
        if ! swift build -c release --package-path "$1" --product haruspec > "$cache/build.log" 2>&1; then
            cat "$cache/build.log" >&2
            say "could not build the CLI from $1 (log: $cache/build.log)"
            exit 1
        fi
    }

    if package=$(local_package); then
        [ -x "$package/.build/release/haruspec" ] || say "building the CLI from $package (first use; a few minutes)"
        build "$package"
        exec "$package/.build/release/haruspec" "$@"
    fi

    if pin=$(pinned); then
        location=${pin% *}
        revision=${pin##* }
        bin="$cache/cli/$revision/haruspec"
        if [ ! -x "$bin" ]; then
            mkdir -p "$cache/cli"
            lock="$cache/cli/$revision.lock"
            waited=0
            # Another launch may be building this version; a lock older than 15 minutes is abandoned.
            until mkdir "$lock" 2>/dev/null; do
                sleep 1
                waited=$((waited + 1))
                if [ "$waited" -gt 900 ]; then rmdir "$lock" 2>/dev/null || true; fi
            done
            trap 'rmdir "$lock" 2>/dev/null || true' EXIT
            if [ ! -x "$bin" ]; then
                say "building haruspec ${revision:0:7} (once per version; a few minutes)"
                source_dir="$cache/src/$revision"
                rm -rf "$source_dir"
                git clone --quiet "$location" "$source_dir"
                git -C "$source_dir" checkout --quiet "$revision"
                build "$source_dir"
                mkdir -p "$(dirname "$bin")"
                cp "$source_dir/.build/release/haruspec" "$bin"
            fi
            rmdir "$lock" 2>/dev/null || true
            trap - EXIT
        fi
        exec "$bin" "$@"
    fi

    say "this project does not use the Haruspec package yet — add it to the test target, resolve packages, and run again"
    exit 1
    """#
}
