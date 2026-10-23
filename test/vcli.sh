#!/bin/bash
# Tests for scripts/vcli's option handling, run from a copy that sources a
# stub script-wrapper.
#
# SPDX-License-Identifier: GPL-2.0-only

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

cat > "$tmp/script-wrapper" <<END
setup_env() { echo "session \$1" >> $tmp/env.log; }
END
sed "s|/opt/vyatta/share/vyatta-cfg/functions/script-wrapper|$tmp/script-wrapper|" \
    "$here/../scripts/vcli" > "$tmp/vcli"

expect() {
    local name=$1 want_rc=$2 want_out=$3 out rc
    shift 3
    out=$(bash "$tmp/vcli" "$@" 2>&1 < "$tmp/stdin")
    rc=$?
    if [ "$rc" != "$want_rc" ] || [ "$out" != "$want_out" ]; then
        echo "vcli: $name: got rc $rc output '$out', want rc $want_rc '$want_out'" >&2
        fail=1
    fi
}

: > "$tmp/stdin"
expect "-c runs a command" 0 "hi" -c 'echo hi'
expect "-c with -i is refused" 1 "Invalid set of options" -c -i
cat > "$tmp/script" <<'END'
echo "file $1"
END
expect "-f runs a file with arguments" 0 "file one" -f "$tmp/script" one
cat > "$tmp/stdin" <<'END'
echo "stdin $1"
END
expect "a script on stdin runs with arguments" 0 "stdin two" -- two
expect "-s sets the session" 0 "stdin " -s 42
grep -qx "session 42" "$tmp/env.log" || { echo "vcli: -s 42 not passed to setup_env" >&2; fail=1; }

[ $fail = 0 ] && echo "vcli: OK"
exit $fail
