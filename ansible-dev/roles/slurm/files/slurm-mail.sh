#!/bin/bash
# Slurm MailProg wrapper.
#
# Slurm invokes us as:    slurm-mail.sh -s "<subject>" <recipient>
# (with the message body on stdin)
#
# bsd-mailx /usr/bin/mail qualifies bare usernames with the local
# hostname, which means a Slurm job with `--mail-user=Nick.Tailor`
# would end up addressed to Nick.Tailor@insiiukcpu01.insmed.local
# (and fail local-delivery). This wrapper qualifies with
# @insmed.com before handing to /usr/bin/mail.
set -e

SUBJECT=
RECIPIENT=
while [ $# -gt 0 ]; do
    case "$1" in
        -s) SUBJECT="$2"; shift 2 ;;
        -*) shift ;;
        *)  RECIPIENT="$1"; shift ;;
    esac
done

case "$RECIPIENT" in
    *@*) ;;
    *)   RECIPIENT="${RECIPIENT}@insmed.com" ;;
esac

exec /usr/bin/mail -s "$SUBJECT" "$RECIPIENT"
