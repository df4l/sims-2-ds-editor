#!/bin/sh
# Launches the editor with the Godot 4.7+ Linux binary found next to this script
# (Godot_v4.x-stable_linux.x86_64), or with `godot` / `godot4` from the PATH.
DIR="$(cd "$(dirname "$0")" && pwd)"
for g in "$DIR"/Godot_v4*_linux.x86_64 "$DIR"/Godot_v4*_linux.arm64; do
	if [ -f "$g" ]; then
		chmod +x "$g" 2>/dev/null
		exec "$g" --path "$DIR" "$@"
	fi
done
for g in godot4 godot; do
	if command -v "$g" >/dev/null 2>&1; then
		exec "$g" --path "$DIR" "$@"
	fi
done
echo "Godot 4.7+ not found: put Godot_v4.7.x-stable_linux.x86_64 in $DIR (https://godotengine.org/download/linux/)" >&2
exit 1
