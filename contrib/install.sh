#!/bin/sh

set -eu


BINARY_DIRECTORY="$HOME/.local/bin"
DATA_DIRECTORY="${XDG_DATA_HOME:-$HOME/.local/share}"
NETWORK_PATH="/etc/twingate/network.conf"
PKEXEC_PATH="/usr/bin/pkexec"
RELEASE_URL="https://github.com/braycarlson/solopass/releases/latest/download"
RULE_PATH="/etc/polkit-1/rules.d/50-solopass.rules"
TIMEOUT_CONNECT_SECONDS=30
TIMEOUT_QUERY_SECONDS=20
TIMEOUT_STALL_SECONDS=60
TWINGATE_PATH="/usr/bin/twingate"
TWINGATE_REPOSITORY_PATH="/etc/yum.repos.d/packages.twingate.com_rpm_.repo"
TWINGATE_URL="https://binaries.twingate.com/client/linux/install.sh"


check_system() {
    [ "$(id -u)" -ne 0 ] || fail "run this as your own user; it asks for sudo when it needs root"
    [ "$(uname -s)" = "Linux" ] || fail "solopass runs only on Linux"
    has curl || has wget || fail "curl or wget is required"
    has sha256sum || fail "sha256sum is required"
    has sudo || fail "sudo is required"
    has tar || fail "tar is required"
    has timeout || fail "timeout is required"
}

configure_twingate() {
    echo "solopass: setting up Twingate"
    sudo "$TWINGATE_PATH" setup </dev/tty || fail "Twingate setup failed"
    is_configured || fail "Twingate setup did not finish; run this installer again"
}

download() {
    if has curl; then
        curl \
            --connect-timeout "$TIMEOUT_CONNECT_SECONDS" \
            --fail \
            --location \
            --show-error \
            --silent \
            --speed-limit 1 \
            --speed-time "$TIMEOUT_STALL_SECONDS" \
            "$1"
    else
        wget \
            --connect-timeout="$TIMEOUT_CONNECT_SECONDS" \
            --dns-timeout="$TIMEOUT_CONNECT_SECONDS" \
            --output-document=- \
            --quiet \
            --read-timeout="$TIMEOUT_STALL_SECONDS" \
            --tries=1 \
            "$1"
    fi
}

fail() {
    echo "solopass: $1" >&2
    exit 1
}

fetch_archive() (
    work=$1
    platform="$(uname -m)-linux"

    download "$RELEASE_URL/SHA256SUMS" >"$work/SHA256SUMS" \
        || fail "the release checksums did not download"

    line=$(grep -e "-$platform\.tar\.gz\$" "$work/SHA256SUMS") \
        || fail "the latest release has no $platform archive"

    [ "$(printf '%s\n' "$line" | wc -l)" -eq 1 ] \
        || fail "the latest release has more than one $platform archive"

    archive=${line##*[ *]}

    echo "solopass: downloading $archive"
    download "$RELEASE_URL/$archive" >"$work/$archive" || fail "$archive did not download"

    (cd "$work" && printf '%s\n' "$line" | sha256sum -c - >/dev/null) \
        || fail "$archive failed its checksum; refusing to install"

    echo "  checksum verified"
    tar -xzf "$work/$archive" -C "$work" --strip-components=1 || fail "$archive did not extract"
)

has() {
    command -v "$1" >/dev/null 2>&1
}

install_pkexec() {
    echo "solopass: installing pkexec"

    if has apt-get; then
        retry sudo apt-get install -y pkexec </dev/null || fail "apt-get could not install pkexec"
    elif has dnf; then
        retry sudo dnf install -y polkit </dev/null || fail "dnf could not install polkit"
    elif has pacman; then
        retry sudo pacman -S --needed --noconfirm polkit </dev/null \
            || fail "pacman could not install polkit"
    else
        fail "pkexec is missing; install the polkit package for this distribution"
    fi

    [ -x "$PKEXEC_PATH" ] || fail "the polkit package did not provide $PKEXEC_PATH"
}

install_rule() (
    work=$1

    echo "solopass: installing the polkit rule"

    sudo install -D -m 644 "$work/share/polkit-1/rules.d/50-solopass.rules" "$RULE_PATH" \
        || fail "the polkit rule did not install"

    echo "  rule     $RULE_PATH"
)

install_solopass() (
    work=$1

    install -D -m 755 "$work/solopass" "$BINARY_DIRECTORY/solopass.new" \
        || fail "the program could not be copied to $BINARY_DIRECTORY"

    mv -f "$BINARY_DIRECTORY/solopass.new" "$BINARY_DIRECTORY/solopass" \
        || fail "the program could not replace $BINARY_DIRECTORY/solopass"

    mkdir -p "$DATA_DIRECTORY" || fail "$DATA_DIRECTORY could not be created"

    cp -R \
        "$work/share/applications" \
        "$work/share/icons" \
        "$work/share/licenses" \
        "$DATA_DIRECTORY/" \
        || fail "the desktop entry, icons, and licenses could not be copied to $DATA_DIRECTORY"

    echo "  binary   $BINARY_DIRECTORY/solopass"
)

install_twingate() (
    work=$1

    echo "solopass: installing Twingate"
    download "$TWINGATE_URL" >"$work/twingate.sh" || fail "the Twingate installer did not download"
    retry install_twingate_attempt "$work" </dev/null || fail "the Twingate installer failed"
    [ -x "$TWINGATE_PATH" ] || fail "Twingate is still missing from $TWINGATE_PATH"
)

install_twingate_attempt() (
    work=$1

    if [ -f "$TWINGATE_REPOSITORY_PATH" ]; then
        sudo dnf install -y twingate
    else
        cd "$work" && sudo bash twingate.sh
    fi
)

is_configured() {
    timeout "$TIMEOUT_QUERY_SECONDS" "$TWINGATE_PATH" account list >/dev/null 2>&1
}

main() {
    check_system

    work=$(mktemp -d) || fail "a temporary directory could not be created"
    trap 'rm -rf "$work"' EXIT
    trap 'exit 1' HUP INT TERM

    fetch_archive "$work"
    [ -x "$TWINGATE_PATH" ] || install_twingate "$work"
    [ -x "$PKEXEC_PATH" ] || install_pkexec
    install_rule "$work"

    if is_configured; then
        network=$(cat "$NETWORK_PATH" 2>/dev/null) \
            || network="unknown ($NETWORK_PATH is unreadable)"

        echo "  network  $network"
    else
        configure_twingate
    fi

    install_solopass "$work"

    if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        start_solopass
    else
        echo "solopass: installed; start $BINARY_DIRECTORY/solopass from your desktop session"
    fi
}

retry() (
    for delay_seconds in 15 30; do
        "$@" && exit 0

        echo "solopass: the install failed; trying again in $delay_seconds seconds"
        sleep "$delay_seconds"
    done

    "$@"
)

start_solopass() (
    pkill -x -u "$(id -u)" solopass || [ "$?" -eq 1 ] || fail "the running solopass did not stop"
    nohup "$BINARY_DIRECTORY/solopass" >/dev/null 2>&1 &
    echo "solopass: started; turn on Start at login from its window"
)

main
