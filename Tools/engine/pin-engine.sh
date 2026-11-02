#!/bin/sh
# Build the pinned engine and put it in Engine/bin, where the app looks for it.
#   Tools/engine/pin-engine.sh [path to the craft-anything clone]   (default: ../craft-anything)
# The clone must be at the pinned commit with a clean tree, so the binary is what pin.env says.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
. "$here/pin.env"
clone=${1:-"$root/../craft-anything"}
clone=$(cd "$clone" && pwd)

head=$(git -C "$clone" rev-parse HEAD)
if [ "$head" != "$CRAFT_ANYTHING_COMMIT" ]; then
    echo "pin-engine: $clone is at $head, but pin.env pins $CRAFT_ANYTHING_COMMIT." >&2
    echo "Check out the pinned commit (git -C \"$clone\" checkout $CRAFT_ANYTHING_COMMIT) or move the pin." >&2
    exit 1
fi
if [ -n "$(git -C "$clone" status --porcelain --untracked-files=no)" ]; then
    echo "pin-engine: $clone has uncommitted changes; the binary wouldn't match the pin." >&2
    exit 1
fi

if ! command -v cargo >/dev/null 2>&1 && [ -x /opt/homebrew/opt/rustup/bin/cargo ]; then
    PATH=/opt/homebrew/opt/rustup/bin:$PATH
fi
(cd "$clone" && CARGO_INCREMENTAL=0 cargo build --release --locked -p craft-anything-cli)

# The CLI finds itself by name to start a builder's tools: keep its name, in a folder of its own.
mkdir -p "$root/Engine/bin"
cp "$clone/target/release/craft-anything-cli" "$root/Engine/bin/craft-anything-cli.new"
mv -f "$root/Engine/bin/craft-anything-cli.new" "$root/Engine/bin/craft-anything-cli"
sha=$(shasum -a 256 "$root/Engine/bin/craft-anything-cli" | cut -d' ' -f1)
version=$("$root/Engine/bin/craft-anything-cli" --version)
cat > "$root/Engine/bin/pin.txt" <<EOF
commit=$CRAFT_ANYTHING_COMMIT
version=$version
sha256=$sha
EOF
echo "Pinned $version ($CRAFT_ANYTHING_COMMIT) at Engine/bin/craft-anything-cli"
