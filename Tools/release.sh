#!/bin/zsh
# Builds, checks, notarizes and (optionally) publishes a release of CraftAnythingNative:
#   pinned engine → tests → release build → bundle (app, tool server, WebKit plugin, engine) → Developer ID signature
#   → smoke test of the bundle → [notarize + staple the app] → DMG → sign → [notarize + staple the DMG] → [GitHub Release]
# CI runs it on a v<version> tag (.github/workflows/release.yml); it runs on this Mac the same way.
#
#   Tools/release.sh
#
# Environment:
#   NOTARIZE        yes | no | auto (default). auto notarizes when the notary profile exists.
#   NOTARY_PROFILE  the notarytool keychain profile (default mlx-notary, the fleet's).
#   NOTARY_KEYCHAIN the keychain holding that profile (CI's temporary keychain); default: login.
#   PUBLISH         no (default) | yes: create the GitHub Release v<version> with the DMG. Needs a notarized build, a
#                   clean tree at a pushed commit, and Docs/releases/<version>.md for the notes.
#   SIGN_IDENTITY   a codesigning identity; default: the Developer ID Application of team CFZS6RXUCP. `-` signs ad hoc
#                   for a quick local check (never notarized or published).
#   ENGINE_CLONE    the craft-anything clone at the pin (default ../craft-anything); Tools/engine/pin-engine.sh builds it.
#   TESTS           yes (default) | no: run `swift test` against the pinned engine first.
#   ALLOW_DIRTY     yes: build from a tree with uncommitted changes (never notarized or published).
#
# The version is VERSION. Output: dist/ — CraftAnythingNative.app, CraftAnythingNative-<version>.dmg (+ .sha256),
# RELEASE.txt, the smoke test's files and the notary logs.
# Follows DeckCraftNative's Tools/release.sh (the DMG and its checks) and Gaea's scripts/release.sh (CI).
set -euo pipefail
root=${0:A:h:h}
cd $root
NOTARIZE=${NOTARIZE:-auto}
PUBLISH=${PUBLISH:-no}
PROFILE=${NOTARY_PROFILE:-mlx-notary}
TEAM=CFZS6RXUCP
BUNDLE_ID=com.xocialize.craftanythingnative
REPO=xocialize-code/CraftAnythingNative
step() { print -P "%B==> $*%b" }
fail() { print -u2 -P "%F{red}release: $*%f"; exit 1 }

# --- Preflight -------------------------------------------------------------------------------------------------
VERSION=$(tr -d ' \n' < VERSION)
[[ $VERSION == <->.<->.<->* ]] || fail "VERSION isn't a version: '$VERSION'"
TAG=v$VERSION
if [[ ${GITHUB_REF_TYPE:-} == tag && ${GITHUB_REF_NAME:-} != $TAG ]]; then
  fail "tag $GITHUB_REF_NAME doesn't match VERSION $VERSION"
fi
dirty=no
[[ -z $(git status --porcelain) ]] || dirty=yes
if [[ $dirty == yes && ${ALLOW_DIRTY:-no} != yes ]]; then
  git status --short >&2
  fail "uncommitted changes: commit first, or set ALLOW_DIRTY=yes for a test build."
fi

if [[ -n ${SIGN_IDENTITY:-} ]]; then
  IDENTITY=$SIGN_IDENTITY
else
  IDENTITY=$(security find-identity -v -p codesigning | sed -n "s/.*\"\(Developer ID Application: .*($TEAM)\)\".*/\1/p" | head -1)
  [[ -n $IDENTITY ]] || fail "no 'Developer ID Application: … ($TEAM)' identity in the keychain."
fi
adhoc=no; [[ $IDENTITY == - ]] && adhoc=yes

notary=(--keychain-profile $PROFILE); [[ -n ${NOTARY_KEYCHAIN:-} ]] && notary+=(--keychain $NOTARY_KEYCHAIN)
if [[ $NOTARIZE == auto ]]; then
  if [[ $adhoc == no && $dirty == no ]] && xcrun notarytool history $notary >/dev/null 2>&1; then NOTARIZE=yes; else NOTARIZE=no; fi
fi
if [[ $NOTARIZE == yes ]]; then
  [[ $adhoc == no ]] || fail "an ad hoc signature can't be notarized."
  [[ $dirty == no ]] || fail "a dirty tree is never notarized."
  xcrun notarytool history $notary >/dev/null 2>&1 || fail "notary profile '$PROFILE' is missing or invalid."
fi
if [[ $PUBLISH == yes ]]; then
  [[ $NOTARIZE == yes ]] || fail "only a notarized build is published."
  [[ -f Docs/releases/$VERSION.md ]] || fail "no release notes: write Docs/releases/$VERSION.md."
  git fetch -q origin
  git merge-base --is-ancestor HEAD origin/main || fail "HEAD isn't on origin/main: push it first."
  gh release view $TAG -R $REPO >/dev/null 2>&1 && fail "$TAG is already released: bump VERSION."
fi

commit=$(git rev-parse HEAD)
build_number=$(git rev-list --count HEAD)
DIST=$root/dist
APP=$DIST/CraftAnythingNative.app
rm -rf $DIST
mkdir -p $DIST
step "CraftAnythingNative $VERSION ($build_number) at ${commit[1,7]}$([[ $dirty == yes ]] && print ' (dirty)'), signed by $IDENTITY"

# --- The pinned engine -----------------------------------------------------------------------------------------
step "Building the pinned engine"
Tools/engine/pin-engine.sh ${ENGINE_CLONE:-$root/../craft-anything}
# pin-engine.sh regenerates the WebKit page scripts from the pin: what's committed must be what the pin has.
git diff --quiet -- Sources/CraftWebKit/PageScripts.swift \
  || fail "Sources/CraftWebKit/PageScripts.swift differs from the pinned engine's scripts: commit the regenerated file."

if [[ ${TESTS:-yes} == yes ]]; then
  step "swift test (against the pinned engine)"
  swift test 2>&1 | tee $DIST/tests.log | tail -5
  [[ ${pipestatus[1]} == 0 ]] || fail "swift test failed (dist/tests.log)"
fi

# --- Build and assemble ----------------------------------------------------------------------------------------
step "swift build -c release"
swift build -c release --arch arm64
bin=$(swift build -c release --arch arm64 --show-bin-path)

step "Assembling ${APP:t}"
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources/Licenses
for exe in CraftAnythingNative craft-anything-tool-server craft-anything-native-tools; do
  cp $bin/$exe $APP/Contents/MacOS/$exe
done
# The engine keeps its name: it finds itself by name to start a builder's tools.
cp Engine/bin/craft-anything-cli $APP/Contents/MacOS/craft-anything-cli
cp Engine/bin/pin.txt $APP/Contents/Resources/engine-pin.txt
engine_clone=${ENGINE_CLONE:-$root/../craft-anything}
cp LICENSE $APP/Contents/Resources/Licenses/CraftAnythingNative-LICENSE.txt
for f in LICENSE-MIT LICENSE-APACHE NOTICE; do
  cp $engine_clone/$f $APP/Contents/Resources/Licenses/craft-anything-$f.txt
done
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>CraftAnythingNative</string>
<key>CFBundleDisplayName</key><string>Craft Anything Native</string>
<key>CFBundleExecutable</key><string>CraftAnythingNative</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$build_number</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Wonder Assembly LLC. MIT License.</string>
</dict></plist>
PLIST
plutil -lint -s $APP/Contents/Info.plist
printf 'APPL????' > $APP/Contents/PkgInfo

# --- Sign, inside out ------------------------------------------------------------------------------------------
step "Signing"
sign=(codesign --force --options runtime --sign $IDENTITY)
[[ $adhoc == yes ]] || sign+=(--timestamp)
$sign --identifier $BUNDLE_ID.engine $APP/Contents/MacOS/craft-anything-cli
$sign --identifier $BUNDLE_ID.tool-server $APP/Contents/MacOS/craft-anything-tool-server
$sign --identifier $BUNDLE_ID.native-tools $APP/Contents/MacOS/craft-anything-native-tools
$sign $APP
check_code() {   # $1 = the bundle or a Mach-O inside it
  local info
  codesign --verify --strict "$1" || fail "${1#$DIST/}: signature does not verify."
  info=$(codesign -dvv "$1" 2>&1)
  print -r -- "$info" | grep -q 'flags=.*runtime' || fail "${1#$DIST/} lacks the hardened runtime."
  if [[ $adhoc == no ]]; then
    [[ $(print -r -- "$info" | sed -n 's/^Authority=//p' | head -1) == $IDENTITY ]] || fail "${1#$DIST/} isn't signed by $IDENTITY."
    print -r -- "$info" | grep -q '^Timestamp=' || fail "${1#$DIST/} has no secure timestamp."
  fi
  if codesign -d --entitlements - --xml "$1" 2>/dev/null | grep -q 'get-task-allow'; then
    fail "${1#$DIST/} carries get-task-allow (notarization would reject it)."
  fi
  print "    ok  ${1#$DIST/}"
}
for f in $APP/Contents/MacOS/*; do check_code $f; done
codesign --verify --deep --strict $APP || fail "the bundle doesn't verify with --deep --strict."
check_code $APP

# --- Smoke test ------------------------------------------------------------------------------------------------
# The build folders are hidden meanwhile, so nothing the bundle needs can be found there instead of in it.
step "Smoke test, with .build and Engine/bin hidden"
mv .build .build-hidden; mv Engine/bin Engine/bin-hidden
trap '[[ -d .build-hidden ]] && mv .build-hidden .build; [[ -d Engine/bin-hidden ]] && mv Engine/bin-hidden Engine/bin' EXIT
pin_version=$(sed -n 's/^version=//p' $APP/Contents/Resources/engine-pin.txt)
[[ $($APP/Contents/MacOS/craft-anything-cli --version) == $pin_version ]] || fail "the bundled engine isn't the pinned one."
python3 -I Tools/smoke-bundle.py $APP $DIST
# The app itself: it starts the bundled engine (in a temp settings folder), draws its window and quits.
$APP/Contents/MacOS/CraftAnythingNative --screenshot $DIST/smoke-window.png > $DIST/smoke-window.log 2>&1 &
app_pid=$!
for _ in {1..120}; do kill -0 $app_pid 2>/dev/null || break; sleep 0.5; done
if kill -0 $app_pid 2>/dev/null; then kill $app_pid; fail "the app didn't save its window and quit within a minute (dist/smoke-window.log)"; fi
wait $app_pid || fail "the app exited with an error (dist/smoke-window.log)"
[[ -s $DIST/smoke-window.png ]] || fail "the app saved no picture of its window (dist/smoke-window.log)"
mv .build-hidden .build; mv Engine/bin-hidden Engine/bin; trap - EXIT
print "    ok  the app drew its window: dist/smoke-window.png"

# --- Notarize --------------------------------------------------------------------------------------------------
submissions=()
notarize() {   # $1 = the file to submit
  local result id status_
  result=$(xcrun notarytool submit "$1" $notary --wait --timeout 1h --output-format json) || true
  id=$(print -r -- "$result" | plutil -extract id raw -o - - 2>/dev/null || true)
  status_=$(print -r -- "$result" | plutil -extract status raw -o - - 2>/dev/null || true)
  [[ -n $id ]] && { xcrun notarytool log "$id" $notary "$DIST/notary-$id.json" >/dev/null 2>&1 || true; }
  if [[ $status_ != Accepted ]]; then
    print -u2 -r -- "$result"
    fail "notarization of ${1:t} ended '${status_:-unknown}'${id:+ (dist/notary-$id.json)}"
  fi
  submissions+=("${1:t} $id")
  print "    accepted: $id"
}
if [[ $NOTARIZE == yes ]]; then
  # The app carries its own ticket, so the copy dragged to /Applications passes Gatekeeper offline.
  step "Notarizing the app"
  ditto -c -k --keepParent $APP $DIST/app.zip
  notarize $DIST/app.zip
  xcrun stapler staple -q $APP
  rm $DIST/app.zip
fi

# --- DMG -------------------------------------------------------------------------------------------------------
suffix=""; [[ $NOTARIZE == yes ]] || suffix="-unnotarized"
DMG=$DIST/CraftAnythingNative-$VERSION$suffix.dmg
step "Building ${DMG:t}"
stage=$DIST/dmg
mkdir -p $stage
ditto $APP $stage/${APP:t}
ln -s /Applications $stage/Applications
# `create -srcfolder`, as DeckCraftNative does: `makehybrid -hfs` gives every file a FinderInfo attribute, and an app
# copied off such a volume fails `codesign --verify --strict`.
hdiutil create -quiet -volname "Craft Anything Native" -srcfolder $stage -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov $DMG
rm -rf $stage
if [[ $adhoc == no ]]; then
  codesign --sign $IDENTITY --timestamp $DMG
  codesign --verify --strict $DMG || fail "the DMG's signature does not verify."
fi
# The app as people get it: on the mounted volume, and copied off it.
mount_point=$(hdiutil attach -nobrowse -readonly -noautoopen $DMG 2>/dev/null | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)
[[ -d $mount_point/${APP:t} ]] || fail "the DMG doesn't mount with ${APP:t} in it."
copy_dir=$(mktemp -d "${TMPDIR:-/tmp}/cany-release.XXXXXX")
ok_on_dmg=1
codesign --verify --deep --strict $mount_point/${APP:t} || ok_on_dmg=0
ditto $mount_point/${APP:t} $copy_dir/${APP:t} && { codesign --verify --deep --strict $copy_dir/${APP:t} || ok_on_dmg=0; }
[[ -L $mount_point/Applications ]] || ok_on_dmg=0
hdiutil detach -quiet $mount_point || true
rm -rf $copy_dir
(( ok_on_dmg )) || fail "the app on the DMG (or copied off it) doesn't verify strictly, or the Applications link is missing."
print "    ok  the app on the DMG and copied off it; Applications link present"

if [[ $NOTARIZE == yes ]]; then
  step "Notarizing the DMG"
  notarize $DMG
  xcrun stapler staple -q $DMG
  step "Gatekeeper"
  xcrun stapler validate -q $DMG
  xcrun stapler validate -q $APP
  spctl -a -vv --type open --context context:primary-signature $DMG
  spctl -a -vv $APP
fi

(cd $DIST && shasum -a 256 ${DMG:t} > ${DMG:t}.sha256 && cat ${DMG:t}.sha256)
SHA=$(cut -d' ' -f1 $DMG.sha256)
{
  print "version: $VERSION ($build_number)"
  print "commit: $commit"
  print "dirty: $dirty"
  print "engine: $(sed -n 's/^commit=//p' $APP/Contents/Resources/engine-pin.txt) ($pin_version)"
  print "signed by: $IDENTITY"
  print "notarized: $NOTARIZE"
  for s in $submissions; do print "notarization: $s"; done
  print "dmg: ${DMG:t}"
  print "sha256: $SHA"
  print "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > $DIST/RELEASE.txt

if [[ $PUBLISH != yes ]]; then
  step "Done: $DMG (not published; PUBLISH=yes publishes)"
  exit 0
fi

# --- Publish ---------------------------------------------------------------------------------------------------
step "GitHub Release $TAG"
pre=(); [[ $VERSION == *-* ]] && pre=(--prerelease)
previous=$(git tag --list 'v*' --sort=-v:refname | grep -vx $TAG | head -1 || true)
notes="$(cat Docs/releases/$VERSION.md)

---

Signed with Developer ID (hardened runtime, secure timestamp), notarized and stapled. Apple silicon, macOS 14 or later.

- \`${DMG:t}\` sha256 \`$SHA\`
- Engine: our fork of storytold/craft-anything at \`$(sed -n 's/^commit=//p' $APP/Contents/Resources/engine-pin.txt | cut -c1-7)\` ($pin_version), bundled

Checked before publishing: \`swift test\` against the pinned engine, \`codesign --verify --deep --strict\` on the app, on the DMG and on a copy taken off it, the bundled engine serving the WebKit browser set through the bundled plugin, the app drawing its window, \`stapler validate\` and \`spctl --assess\`."
[[ -n $previous ]] && notes+="

Changes since ${previous}: https://github.com/$REPO/compare/${previous}...${TAG}"
gh release create $TAG $DMG $DMG.sha256 -R $REPO --target $commit --title "Craft Anything Native $VERSION" --notes $notes $pre
gh release view $TAG -R $REPO --json url,isPrerelease,assets -q '.url, (.assets[] | .name)'
