#!/bin/bash
# Development install: builds bcu.app for arm64 and x86_64, signs it with the Developer ID
# identity, stops the resident process that is still running the previous build, and replaces
# /Applications/bcu.app. The `bcu` command is the brew cask's link to the executable inside the
# app, so it runs this build at once; without the cask, link it yourself (see the README).
set -euo pipefail

source "$(dirname "$0")/lib/package.sh"

readonly APP=/Applications/bcu.app

main() {
	[[ $(uname -s) == Darwin ]] || die "bcu runs on macOS only"
	# Global: the EXIT trap runs after main has returned.
	staging=$(mktemp -d)
	trap 'rm -rf "$staging"' EXIT
	make_app "$staging/bcu.app"
	# The installed build stops its own resident; `BCU_SOCKET_PATH` is honoured.
	if [[ -x $APP/Contents/MacOS/bcu ]]; then "$APP/Contents/MacOS/bcu" stop >&2; fi
	rm -rf "$APP.new"
	ditto "$staging/bcu.app" "$APP.new"
	rm -rf "$APP"
	mv "$APP.new" "$APP"
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
	log "installed $APP $("$APP/Contents/MacOS/bcu" --version)"
	log "run 'bcu doctor'; if it reports missing permissions, run 'bcu setup'"
}

main "$@"
