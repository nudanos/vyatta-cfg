#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# cliexec templates (#!/opt/vyatta/bin/cliexec) are written for bash: DANOS's
# /bin/sh was bash. On Debian 13 /bin/sh is dash, so cliexec must run the
# expanded template with bash ("service snmp" failed: "[[: not found").
set -eu
fail=0
for f in src/cliexec/cliexec.cpp src/cliexec/cli_new.c; do
    if grep -n '"/bin/sh"' "$f"; then
        echo "cliexec-shell: $f runs templates with /bin/sh" >&2
        fail=1
    fi
done
[ $fail = 0 ] && echo "cliexec-shell: OK"
exit $fail
