#!/bin/bash
# Builds bcu for arm64 and x86_64 and installs it as bcu.app: signed with this Mac's stable
# local identity, because macOS keys the Accessibility and Screen Recording grants to the
# signing identity and bundle id; the resident process that is still running the previous
# build is stopped; `bcu` is linked into PATH.
#
#   BCU_APP_PATH           where the app goes (default /Applications/bcu.app)
#   BCU_BIN_DIR            where the `bcu` link goes (default ~/.local/bin)
#   BCU_SOCKET_PATH        the resident socket to stop (default ~/Library/Caches/bcu/resident.sock)
#   BCU_CODESIGN_IDENTITY  sign with this identity instead of the local one
set -euo pipefail

readonly BUNDLE_ID=com.sugeh.bcu
readonly VERSION=0.2.0
readonly MINIMUM_MACOS=14.0
readonly IDENTITY_NAME="bcu Local Signing ($BUNDLE_ID)"
readonly APP=${BCU_APP_PATH:-/Applications/bcu.app}
readonly BIN_DIR=${BCU_BIN_DIR:-$HOME/.local/bin}
readonly SOCKET=${BCU_SOCKET_PATH:-$HOME/Library/Caches/bcu/resident.sock}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
readonly ROOT

log() { printf '[bcu] %s\n' "$*" >&2; }

build() {
	local build=(swift build -c release --product bcu --arch arm64 --arch x86_64 --package-path "$ROOT")
	"${build[@]}" >&2
	printf '%s/bcu' "$("${build[@]}" --show-bin-path)"
}

assemble() {
	local binary=$1 app=$2
	mkdir -p "$app/Contents/MacOS"
	cp "$binary" "$app/Contents/MacOS/bcu"
	cat >"$app/Contents/Info.plist" <<-PLIST
	<?xml version="1.0" encoding="UTF-8"?>
	<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
	<plist version="1.0"><dict>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleName</key><string>bcu</string>
	<key>CFBundleDisplayName</key><string>bcu</string>
	<key>CFBundleExecutable</key><string>bcu</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>LSMinimumSystemVersion</key><string>$MINIMUM_MACOS</string>
	<key>LSUIElement</key><true/>
	</dict></plist>
	PLIST
}

# Self-signed identities are untrusted, so `find-identity -v` hides them; codesign still
# accepts them by fingerprint.
local_identity() {
	security find-identity -p codesigning | awk -v name="\"$IDENTITY_NAME\"" 'index($0, name) { print $2; exit }'
}

# A self-signed code-signing certificate in the login keychain. It is created once per Mac
# and reused by every later install, which keeps the grants valid across rebuilds.
create_identity() {
	local keychain=$HOME/Library/Keychains/login.keychain-db work password
	[[ -f $keychain ]] || keychain=$HOME/Library/Keychains/login.keychain
	work=$(mktemp -d)
	password=bcu-$$-$RANDOM
	cat >"$work/req.cnf" <<-CNF
	[req]
	distinguished_name=dn
	x509_extensions=ext
	prompt=no
	[dn]
	CN=$IDENTITY_NAME
	[ext]
	basicConstraints=critical,CA:FALSE
	keyUsage=critical,digitalSignature
	extendedKeyUsage=critical,codeSigning
	CNF
	openssl req -x509 -newkey rsa:2048 -keyout "$work/key.pem" -out "$work/cert.pem" -days 3650 -nodes -config "$work/req.cnf" 2>/dev/null
	openssl pkcs12 -export -legacy -inkey "$work/key.pem" -in "$work/cert.pem" -out "$work/id.p12" -passout "pass:$password" -name "$IDENTITY_NAME" 2>/dev/null ||
		openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -out "$work/id.p12" -passout "pass:$password" -name "$IDENTITY_NAME"
	security import "$work/id.p12" -k "$keychain" -P "$password" -A -T /usr/bin/codesign >&2
	rm -rf "$work"
}

signing_identity() {
	if [[ -n ${BCU_CODESIGN_IDENTITY:-} ]]; then
		printf '%s' "$BCU_CODESIGN_IDENTITY"
		return
	fi
	local identity
	identity=$(local_identity)
	if [[ -z $identity ]]; then
		log "creating the local signing identity \"$IDENTITY_NAME\""
		create_identity
		identity=$(local_identity)
	fi
	[[ -n $identity ]] || { log "could not create a signing identity; set BCU_CODESIGN_IDENTITY"; exit 1; }
	printf '%s' "$identity"
}

# The running resident keeps serving the build it started with, and is asked to stop over its
# own protocol: it binds under another name and publishes its socket by rename, which hides
# it from lsof. The Node CLI's Broker and helper that bcu.app replaced bound broker.sock and
# bridge.sock in place beside it, so the exact pid holding either is stopped and waited for.
stop_running() {
	local binary=$1 socket pid
	for socket in "$(dirname "$SOCKET")/broker.sock" "$(dirname "$SOCKET")/bridge.sock"; do
		[[ -S $socket ]] || continue
		for pid in $(lsof -t -- "$socket" 2>/dev/null); do
			log "stopping pid $pid on $socket"
			kill "$pid" 2>/dev/null || continue
			caffeinate -w "$pid"
		done
		rm -f "$socket"
	done
	BCU_SOCKET_PATH=$SOCKET "$binary" stop >&2
}

install_app() {
	local staged=$1
	mkdir -p "$(dirname "$APP")"
	rm -rf "$APP.new"
	ditto "$staged" "$APP.new"
	rm -rf "$APP"
	mv "$APP.new" "$APP"
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
}

link_cli() {
	mkdir -p "$BIN_DIR"
	ln -sfn "$APP/Contents/MacOS/bcu" "$BIN_DIR/bcu"
	case ":$PATH:" in
	*":$BIN_DIR:"*) ;;
	*) log "add $BIN_DIR to PATH to run bcu" ;;
	esac
	# The Node CLI this replaces was installed with `npm link`; npm rm -g better-computer-use removes it.
	local found
	found=$(command -v bcu || true)
	if [[ -n $found && $found != "$BIN_DIR/bcu" ]]; then log "$found comes first in PATH and is not this install; remove it"; fi
}

main() {
	[[ $(uname -s) == Darwin ]] || { log "bcu runs on macOS only"; exit 1; }
	local binary identity
	binary=$(build)
	# Global: the EXIT trap runs after main has returned.
	staging=$(mktemp -d)
	trap 'rm -rf "$staging"' EXIT
	assemble "$binary" "$staging/bcu.app"
	identity=$(signing_identity)
	codesign --force --sign "$identity" -i "$BUNDLE_ID" --timestamp=none "$staging/bcu.app"
	stop_running "$binary"
	install_app "$staging/bcu.app"
	link_cli
	log "installed $APP, signed by $identity; bcu → $BIN_DIR/bcu"
	log "run 'bcu doctor'; if it reports missing permissions, run 'bcu setup'"
}

main "$@"
