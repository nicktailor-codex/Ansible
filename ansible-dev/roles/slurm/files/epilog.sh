#!/bin/bash
# Slurm Epilog dispatcher — iterates /etc/slurm/epilog.d/ in lex order.
# See prolog.sh for the rationale. Epilog runs after a job completes;
# cleanup scripts here free per-job state.
#
# Epilogs failing is less catastrophic than prologs failing, but still
# drains the node — fail-fast so failures are visible.
for script in /etc/slurm/epilog.d/*.sh; do
    [ -x "$script" ] || continue
    if ! "$script"; then
        rc=$?
        echo "epilog: $script FAILED with exit $rc" >&2
        exit "$rc"
    fi
done
exit 0
