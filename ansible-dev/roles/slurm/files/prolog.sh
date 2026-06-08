#!/bin/bash
# Slurm Prolog dispatcher — iterates /etc/slurm/prolog.d/ in lex order.
# Slurm 23.11's Prolog= directive expects a single executable, not a
# directory (despite docs being ambiguous; execv() on the dir itself
# returns EACCES). This script is what slurm.conf points at; the real
# prolog logic lives in /etc/slurm/prolog.d/*.sh.
#
# If any sub-script fails, the whole prolog fails — Slurm drains the
# node, which is the correct signal for "this node can't honor new jobs".
for script in /etc/slurm/prolog.d/*.sh; do
    [ -x "$script" ] || continue
    if ! "$script"; then
        rc=$?
        echo "prolog: $script FAILED with exit $rc" >&2
        exit "$rc"
    fi
done
exit 0
