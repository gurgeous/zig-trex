# Required for codex shell sessions where mise PATH hooks may not be active.
export PATH := env("HOME") + "/.local/share/mise/installs/zig/0.15.2/bin:" + env("PATH")# Use mise shims without hardcoding a specific install path.

default:
  just --list

check: lint test
  just banner "✓ check ✓"

clean:
  rm -rf zig-out .zig-cache

examples:
  zig run examples.zig

fmt:
  zig fmt *.zig
  just banner "✓ fmt ✓"

lint:
  zig fmt --check *.zig
  just banner "✓ lint ✓"

run *ARGS:
  zig build run -- {{ARGS}}

test:
  zig build test --summary all
  just banner "✓ test ✓"

test-watch:
  watchexec --clear=clear --stop-timeout=0 just test

#
# banner
#

set quiet

banner +ARGS:  (_banner '\e[48;2;064;160;043m' ARGS)
warning +ARGS: (_banner '\e[48;2;251;100;011m' ARGS)
fatal +ARGS:   (_banner '\e[48;2;210;015;057m' ARGS)
  exit 1
_banner BG +ARGS:
  printf '\e[38;5;231m{{BOLD+BG}}[%s] %-72s {{NORMAL}}\n' "$(date +%H:%M:%S)" "{{ARGS}}" ; \
