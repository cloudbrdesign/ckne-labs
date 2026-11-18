#!/usr/bin/env bash
# Runs the given labs one after another (run, then delete the cluster) and prints a summary. Usage: bash run-all.sh labs/m01/1.3-ipam ...
cd "$(dirname "$0")"; sum=""
for l in "$@"; do
  echo; echo "################ $l ################"; s=$SECONDS
  bash "$l/lab.sh" run; rc=$?
  sum="$sum$(printf '%-34s %s  %ss' "$l" "$([ $rc = 0 ] && echo PASS || echo FAIL)" $((SECONDS-s)))\n"
  bash "$l/lab.sh" down >/dev/null 2>&1
done
printf '\n==== summary\n%b' "$sum"
