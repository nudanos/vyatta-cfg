#!/bin/bash
# Tests for scripts/vyatta-cfg-notify with stub ps, getent and sudo: the
# other configuration sessions are told about a commit, the committing one
# is not.
#
# SPDX-License-Identifier: GPL-2.0-only

notify=$(dirname "$0")/../scripts/vyatta-cfg-notify
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"

# sessions: alice (uid 1000) commits from pid 12 on pts/1; bob (uid 1001,
# pid 123) has a configuration session on pts/9; carol (uid 1002) only a
# shell on pts/5
cat > "$tmp/bin/ps" <<'END'
#!/bin/bash
case "$*" in
"-o tty= -p 12") echo "pts/1" ;;
"-o tty= -p 123") echo "pts/9" ;;
"-a -o tty=,ruser=,args= n")
    printf '%s\n' "pts/1     1000 newgrp vyattacfg" "pts/9     1001 newgrp vyattacfg" \
        "pts/5     1002 -bash" ;;
# the forms the script used before
"-eo pid,tty=") printf '%s\n' "    PID" "    123 pts/9" "     12 pts/1" ;;
"-a -o args,tty,ruser n")
    printf '%-28s%s\n' "COMMAND" "TT        RUSER" "newgrp vyattacfg" "pts/1     1000" \
        "newgrp vyattacfg" "pts/9     1001" "-bash" "pts/5     1002" ;;
*) echo "ps: unexpected $*" >&2; exit 1 ;;
esac
END
cat > "$tmp/bin/getent" <<'END'
#!/bin/sh
case $2 in
1000|alice) echo "alice:x:1000:1000::/home/alice:/bin/bash" ;;
1001|bob) echo "bob:x:1001:1001::/home/bob:/bin/bash" ;;
1002|carol) echo "carol:x:1002:1002::/home/carol:/bin/bash" ;;
esac
END
printf '#!/bin/sh\necho "$*" >> %s/sudo.log\ncat >> %s/sudo.log\n' "$tmp" "$tmp" > "$tmp/bin/sudo"
chmod +x "$tmp/bin/ps" "$tmp/bin/getent" "$tmp/bin/sudo"

PATH=$tmp/bin:$PATH VYATTA_CFG_GROUP_NAME=vyattacfg bash "$notify" alice 12 2> "$tmp/err"

expected="write bob pts/9
Active configuration has been changed by user 'alice' on 'pts/1'.
Please make sure you do not have conflicting changes. You can also discard
the current changes by issuing 'exit discard'."
got=$(cat "$tmp/sudo.log" 2>/dev/null)
if [ "$got" != "$expected" ]; then
    echo "cfg-notify: notified" >&2
    sed 's/^/    /' "$tmp/sudo.log" "$tmp/err" >&2
    echo "  want" >&2
    while IFS= read -r line; do echo "    $line"; done <<< "$expected" >&2
    exit 1
fi
echo "cfg-notify: ok"
