#!/bin/bash
# Shared helper for package-specific pre-build hooks that need AUR-only deps.
# Runs as the non-root builder user; sudo is used only for pacman operations.
set -euo pipefail

AUR_DEPS_DIR="${AUR_DEPS_DIR:-/tmp/aur-deps}"
REPO_NAME="${REPO_NAME:-arch_lib}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-stevessr/custom_lib_build}"
REPO_URL="${REPO_URL:-https://github.com/${GITHUB_REPOSITORY}/releases/download/latest}"
mkdir -p "$AUR_DEPS_DIR"

ensure_arch_lib_repo() {
    if ! grep -q "^\[${REPO_NAME}\]$" /etc/pacman.conf 2>/dev/null; then
        echo "  [hook] Adding repo [$REPO_NAME] ($REPO_URL) to pacman.conf"
        {
            printf '\n[%s]\n' "$REPO_NAME"
            printf 'SigLevel = Never\n'
            printf 'Server = %s\n' "$REPO_URL"
        } | sudo tee -a /etc/pacman.conf >/dev/null
    fi

    local log="$AUR_DEPS_DIR/pacman-sy.log"
    if ! sudo pacman -Sy --noconfirm >"$log" 2>&1; then
        echo "  [hook] ✗ pacman -Sy failed" >&2
        tail -20 "$log" >&2 || true
        exit 1
    fi
}

aur_package_base() {
    local pkg="$1"
    local base=""
    base=$(curl -fsSL --max-time 15 --retry 5 --retry-all-errors --retry-delay 2 \
        "https://aur.archlinux.org/rpc/v5/info?arg[]=${pkg}" 2>/dev/null \
        | jq -r '.results[0].PackageBase // empty' 2>/dev/null) || true
    printf '%s\n' "${base:-$pkg}"
}

install_aur_dep() {
    local pkg="$1"

    if pacman -T "$pkg" >/dev/null 2>&1; then
        echo "  [hook] already satisfied: $pkg"
        return 0
    fi

    local pacman_log="$AUR_DEPS_DIR/pacman-${pkg}.log"
    if sudo pacman -S --noconfirm --needed "$pkg" >"$pacman_log" 2>&1; then
        echo "  [hook] ✓ Installed $pkg from configured repositories"
        return 0
    fi

    local base dir logfile custom_dir hook clone_ok=0
    base=$(aur_package_base "$pkg")
    dir="$AUR_DEPS_DIR/$base"
    logfile="$AUR_DEPS_DIR/${base}-build.log"
    custom_dir="${GITHUB_WORKSPACE:-}/custom-pkgs/$base"
    hook="${GITHUB_WORKSPACE:-}/scripts/pre-build/$base.sh"

    rm -rf "$dir"
    mkdir -p "$dir"

    # Prefer an in-repository recipe over AUR. This lets us carry small,
    # deliberate compatibility fixes for stale/broken AUR recipes while the
    # bootstrapper and the normal matrix build use exactly the same package.
    if [ -n "${GITHUB_WORKSPACE:-}" ] && [ -f "$custom_dir/PKGBUILD" ]; then
        echo "  [hook] $pkg not in repos — using custom package base $base"
        cp -a "$custom_dir/." "$dir/"
    else
        echo "  [hook] $pkg not in repos — building AUR package base $base"
        for attempt in 1 2 3 4 5; do
            if ( cd "$dir" && git clone -q --depth=1 "https://aur.archlinux.org/${base}.git" . ); then
                clone_ok=1
                break
            fi
            echo "  [hook] (clone $base attempt $attempt failed; retrying)"
            rm -rf "$dir"/* "$dir"/.[!.]* "$dir"/..?* 2>/dev/null || true
            sleep 5
        done

        if [ "$clone_ok" -ne 1 ]; then
            echo "  [hook] ✗ git clone failed for AUR package base $base" >&2
            exit 1
        fi
    fi

    # A dependency may itself need AUR-only dependencies. Run its package hook
    # before makepkg so bootstrap chains work recursively (for example
    # python-conda -> libmamba solver -> micromamba -> reproc).
    if [ -n "${GITHUB_WORKSPACE:-}" ] && [ -f "$hook" ]; then
        echo "  [hook] Running dependency pre-build hook: scripts/pre-build/$base.sh"
        bash "$hook" "$dir" "$pkg"
    fi

    # Bootstrap dependencies only. Skip check() to avoid pulling checkdepends or
    # running network/environment-sensitive package tests in the bootstrap path.
    if ! ( cd "$dir" && makepkg -s --nocheck --noconfirm --needed --skippgpcheck >"$logfile" 2>&1 ); then
        echo "  [hook] ✗ makepkg failed for dependency $pkg ($base)" >&2
        tail -50 "$logfile" >&2 || true
        exit 1
    fi

    local -a built=()
    while IFS= read -r pkgfile; do
        built+=("$pkgfile")
    done < <(find "$dir" -maxdepth 1 -type f -name '*.pkg.tar.zst' ! -name '*-debug-*' -print | sort)

    if [ "${#built[@]}" -eq 0 ]; then
        echo "  [hook] ✗ dependency $pkg produced no package files" >&2
        exit 1
    fi

    sudo pacman -U --noconfirm --needed "${built[@]}" >"$AUR_DEPS_DIR/pacman-u-${base}.log" 2>&1 || {
        echo "  [hook] ✗ pacman -U failed for dependency $pkg" >&2
        tail -50 "$AUR_DEPS_DIR/pacman-u-${base}.log" >&2 || true
        exit 1
    }

    if ! pacman -T "$pkg" >/dev/null 2>&1; then
        echo "  [hook] ✗ $base built successfully but did not satisfy dependency: $pkg" >&2
        exit 1
    fi
    echo "  [hook] ✓ Installed dependency: $pkg ($base)"
}

ensure_aur_deps() {
    ensure_arch_lib_repo
    local pkg
    for pkg in "$@"; do
        install_aur_dep "$pkg"
    done
}
