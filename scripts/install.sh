#!/bin/sh
# Builds Revu.app, installs it to ~/Applications, links the `revu` launcher into ~/.local/bin,
# and installs the Claude Code skill into ~/.claude/skills/revu.
set -e
cd "$(dirname "$0")/.."

./scripts/build-app.sh

mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Revu.app"
cp -R build/Revu.app "$HOME/Applications/Revu.app"

# Exec the bundle binary directly (never `open`) so stdout and the exit code reach the caller.
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/revu" <<'LAUNCHER'
#!/bin/sh
exec "$HOME/Applications/Revu.app/Contents/MacOS/revu" "$@"
LAUNCHER
chmod +x "$HOME/.local/bin/revu"
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo "warning: $HOME/.local/bin is not on your PATH" >&2 ;;
esac

mkdir -p "$HOME/.claude/skills"
rm -rf "$HOME/.claude/skills/revu"
cp -R skill/revu "$HOME/.claude/skills/revu"

echo "Installed: ~/Applications/Revu.app, ~/.local/bin/revu, ~/.claude/skills/revu"
