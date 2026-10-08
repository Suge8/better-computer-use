#!/bin/bash
# Local release, run from a clean main: scripts/release.sh X.Y.Z [--dry-run]
#
# Tags vX.Y.Z, builds the universal app, signs it with Developer ID, has Apple notarize it,
# staples the ticket, zips it, publishes the GitHub release and regenerates Casks/bcu.rb in the
# Suge8/homebrew-tap repo. It runs on this Mac and not in CI because the signing certificate and
# the notary credentials live in this Mac's keychain and are never exported.
#
# `--dry-run` stops after the zip: it tags temporarily, builds, signs and zips, checks the
# signature, and writes the cask to .build/dist/, but does not notarize, publish or push.
# That is the way to see what a release would ship before the notary credentials exist.
#
# One-time setup of the notary credentials (an app-specific password from appleid.apple.com):
#   xcrun notarytool store-credentials bcu-notary --apple-id <apple id> --team-id SVPPQJM9JG
set -euo pipefail

source "$(dirname "$0")/lib/package.sh"

readonly NOTARY_PROFILE=bcu-notary
readonly REPO=Suge8/better-computer-use
readonly TAP=Suge8/homebrew-tap
readonly DIST=$ROOT/.build/dist

release_version=${1:-}
dry_run=false
[[ $release_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: scripts/release.sh X.Y.Z [--dry-run]"
case ${2:-} in
"") ;;
--dry-run) dry_run=true ;;
*) die "usage: scripts/release.sh X.Y.Z [--dry-run]" ;;
esac
readonly release_version dry_run
readonly tag=v$release_version
readonly app_path=$DIST/bcu.app
readonly zip=$DIST/bcu-$release_version.zip

preflight() {
	[[ -z $(git -C "$ROOT" status --porcelain) ]] || die "the working tree is not clean"
	git -C "$ROOT" rev-parse -q --verify "refs/tags/$tag" >/dev/null && die "$tag already exists"
	signing_identity >/dev/null
	[[ $dry_run == true ]] && return
	gh auth status >/dev/null 2>&1 || die "gh is not logged in: gh auth login"
	xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 ||
		die "notary credentials '$NOTARY_PROFILE' are missing: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple id> --team-id SVPPQJM9JG"
	[[ $(git -C "$ROOT" branch --show-current) == main ]] || die "release from main"
	git -C "$ROOT" ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1 && die "$tag already exists on origin"
	git -C "$ROOT" fetch -q origin main
	[[ $(git -C "$ROOT" rev-parse HEAD) == "$(git -C "$ROOT" rev-parse origin/main)" ]] || die "main is not pushed: origin/main differs from HEAD"
}

zip_app() { ditto -c -k --keepParent "$app_path" "$1"; }

# The ticket is stapled into the app, so Gatekeeper accepts it offline.
notarize() {
	local submission result status
	submission=$DIST/notarize.zip
	zip_app "$submission"
	result=$(xcrun notarytool submit "$submission" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist)
	status=$(plutil -extract status raw -o - - <<<"$result")
	if [[ $status != Accepted ]]; then
		xcrun notarytool log "$(plutil -extract id raw -o - - <<<"$result")" --keychain-profile "$NOTARY_PROFILE" >&2
		die "notarization ended as $status"
	fi
	xcrun stapler staple "$app_path" >&2
	xcrun stapler validate "$app_path" >&2
	rm "$submission"
}

write_cask() {
	local macos sha
	case $(minimum_macos) in
	14.*) macos=sonoma ;;
	15.*) macos=sequoia ;;
	26.*) macos=tahoe ;;
	*) die "no cask macOS name for $(minimum_macos): extend write_cask" ;;
	esac
	sha=$(shasum -a 256 "$zip" | awk '{ print $1 }')
	cat >"$1" <<-CASK
	cask "bcu" do
	  version "$release_version"
	  sha256 "$sha"

	  url "https://github.com/$REPO/releases/download/v#{version}/bcu-#{version}.zip"
	  name "bcu"
	  desc "Command-line control of desktop apps for AI agents"
	  homepage "https://github.com/$REPO"

	  depends_on macos: :$macos

	  app "bcu.app"
	  binary "#{appdir}/bcu.app/Contents/MacOS/bcu"

	  uninstall signal: ["TERM", "com.sugeh.bcu"]

	  zap trash: [
	    "~/.config/bcu",
	    "~/Library/Caches/bcu",
	  ]
	end
	CASK
}

publish() {
	git -C "$ROOT" push origin "refs/tags/$tag"
	gh release create "$tag" "$zip" --repo "$REPO" --title "$tag" --generate-notes --verify-tag
	local tap
	tap=$(mktemp -d)
	git clone --depth 1 "git@github.com:$TAP.git" "$tap"
	mkdir -p "$tap/Casks"
	cp "$DIST/bcu.rb" "$tap/Casks/bcu.rb"
	git -C "$tap" add Casks/bcu.rb
	git -C "$tap" commit -q -m "bcu $release_version"
	git -C "$tap" push
	rm -rf "$tap"
}

main() {
	preflight
	# Global: the EXIT trap runs after main has returned.
	published=false
	# A tag nobody published is removed again, so a failed run can be repeated.
	trap '[[ $published == true ]] || git -C "$ROOT" tag -d "$tag" >/dev/null' EXIT
	git -C "$ROOT" tag "$tag"
	[[ $(app_version) == "$release_version" ]] || die "the build would be version $(app_version), not $release_version"
	rm -rf "$DIST"
	mkdir -p "$DIST"
	make_app "$app_path"
	if [[ $dry_run == false ]]; then notarize; fi
	zip_app "$zip"
	write_cask "$DIST/bcu.rb"
	# Unnotarized apps are rejected here; only a real release must pass.
	if [[ $dry_run == true ]]; then spctl -a -vv "$app_path" || true; else spctl -a -vv "$app_path"; fi
	if [[ $dry_run == true ]]; then
		log "dry run: $zip and $DIST/bcu.rb are ready, nothing was notarized or published"
		return
	fi
	publish
	published=true
	log "released $tag"
}

main
