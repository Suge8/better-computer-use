# Sourced by install.sh and release.sh: build, assemble and sign bcu.app.
#
# The version has one source, the git tag vX.Y.Z: a build at a tag is X.Y.Z, any other build
# is `git describe` (X.Y.Z-N-gHASH, plus -dirty.<time> for uncommitted changes, so every
# development install differs). It goes into Info.plist, which the client and the resident
# read; the resident running from an app of another version than the one on disk is replaced.
#
# Signing is always Developer ID with the hardened runtime: macOS keys the Accessibility and
# Screen Recording grants to the signing identity and bundle id, so installs and releases must
# share one identity for the grants to survive upgrades.

readonly BUNDLE_ID=com.sugeh.bcu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
readonly ROOT

log() { printf '[bcu] %s\n' "$*" >&2; }
die() { log "$*"; exit 1; }

app_version() {
	git -C "$ROOT" describe --tags --match 'v[0-9]*' --dirty="-dirty.$(date +%s)" | sed 's/^v//'
}

# The deployment target is the one Package.swift builds for.
minimum_macos() {
	swift package --package-path "$ROOT" describe --type json | plutil -extract platforms.0.version raw -o - -
}

signing_identity() {
	local identity
	identity=$(security find-identity -v -p codesigning | awk '/"Developer ID Application:/ { print $2; exit }')
	[[ -n $identity ]] || die "no 'Developer ID Application' identity in the keychain"
	printf '%s' "$identity"
}

# Prints the path of the universal binary.
build() {
	local build=(swift build -c release --product bcu --arch arm64 --arch x86_64 --package-path "$ROOT")
	"${build[@]}" >&2
	printf '%s/bcu' "$("${build[@]}" --show-bin-path)"
}

assemble() {
	local binary=$1 app=$2 version=$3 minimum
	minimum=$(minimum_macos)
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
	<key>CFBundleShortVersionString</key><string>$version</string>
	<key>CFBundleVersion</key><string>$version</string>
	<key>LSMinimumSystemVersion</key><string>$minimum</string>
	<key>LSUIElement</key><true/>
	</dict></plist>
	PLIST
}

sign() {
	codesign --force --sign "$(signing_identity)" --options runtime --timestamp "$1"
	codesign --verify --deep --strict "$1"
}

# Builds, assembles and signs bcu.app at $1.
make_app() {
	local app=$1
	assemble "$(build)" "$app" "$(app_version)"
	sign "$app"
}
