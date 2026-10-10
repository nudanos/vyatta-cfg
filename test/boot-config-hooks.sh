#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# vyatta-boot-config-loader runs every executable regular file in
# BOOT_CONFIG_HOOK_DIR (LC_ALL=C order) as "<hook> <boot file>" before
# loading the boot configuration, logs each result and never aborts on a
# hook failure.
set -u
here=$(cd "$(dirname "$0")" && pwd)
loader=$here/../scripts/vyatta-boot-config-loader
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/hooks" "$tmp/bin"
fail=0

hook() { printf '#!/bin/sh\n%s\n' "$2" > "$tmp/hooks/$1"; }
hook 10-a "printf a >> $tmp/marker; echo \"hook 10-a \$1\" >> $tmp/order"
hook 20-b "printf b >> $tmp/marker; echo 'hook 20-b' >> $tmp/order"
hook 30-fail "exit 3"
hook 40-skip "printf x >> $tmp/marker"
chmod +x "$tmp/hooks/10-a" "$tmp/hooks/20-b" "$tmp/hooks/30-fail"

# cli-shell-api records what it is asked; cfgcli (commit) succeeds
printf '#!/bin/sh\n[ "$1" = loadFile ] && echo "loadFile $2" >> %s/order\nexit 0\n' "$tmp" > "$tmp/capi"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/cfgcli"
chmod +x "$tmp/capi" "$tmp/bin/cfgcli"

PATH=$tmp/bin:$PATH BOOT_CONFIG_CAPI=$tmp/capi BOOT_CONFIG_HOOK_DIR=$tmp/hooks \
    bash "$loader" "$tmp/config.boot" > "$tmp/out" 2>&1

check() { if ! eval "$2"; then echo "boot-config-hooks: $1" >&2; fail=1; fi; }
check "hooks did not run in order (marker '$(cat "$tmp/marker" 2>/dev/null)', want 'ab')" \
    '[ "$(cat "$tmp/marker" 2>/dev/null)" = ab ]'
check "the hook did not get the boot file" \
    'grep -qx "hook 10-a $tmp/config.boot" "$tmp/order"'
check "no log line for the failing hook" \
    'grep -q "boot-config hook 30-fail: failed (3)" "$tmp/out"'
check "no log line for a succeeding hook" \
    'grep -q "boot-config hook 10-a: ok" "$tmp/out"'
check "loadFile was not called after a hook failure" \
    'grep -qx "loadFile $tmp/config.boot" "$tmp/order"'
check "hooks did not run before loadFile" \
    '[ "$(head -1 "$tmp/order")" = "hook 10-a $tmp/config.boot" ] && [ "$(tail -1 "$tmp/order")" = "loadFile $tmp/config.boot" ]'
if [ $fail != 0 ]; then
    sed 's/^/    /' "$tmp/out" >&2
    exit 1
fi
echo "boot-config-hooks: OK"
