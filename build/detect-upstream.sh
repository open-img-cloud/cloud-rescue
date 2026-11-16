#!/usr/bin/env bash
# Prints the latest upstream Rocky Linux 9 GenericCloud image version (cloud-rescue is built on it) on stdout.
#
# Parses the directory listing at
#   https://dl.rockylinux.org/pub/rocky/9/images/x86_64/
# for versioned image names and prints the highest version
# (e.g. 9.8-20260525.0). Runs in the upstream-watch reusable workflow
# (no KVM needed): keep it portable bash + curl + grep + sort only.

set -euo pipefail

URL='https://dl.rockylinux.org/pub/rocky/9/images/x86_64/'

listing=$(curl -fsL "$URL")
if [[ -z "$listing" ]]; then
  echo "::error::could not fetch $URL" >&2
  exit 1
fi

latest=$(printf '%s\n' "$listing" \
  | grep -oE 'Rocky-9-GenericCloud-Base-(9\.[0-9]+-[0-9]{8}\.[0-9]+)\.x86_64\.qcow2' \
  | sed -E 's#Rocky-9-GenericCloud-Base-(9\.[0-9]+-[0-9]{8}\.[0-9]+)\.x86_64\.qcow2#\1#' \
  | sort -uV \
  | tail -n1)

if [[ -z "$latest" ]]; then
  echo "::error::no versioned Rocky Linux 9 GenericCloud image found in $URL" >&2
  exit 1
fi

# A -rN rebuild of the current Rocky build is still current: keep VERSION as it is.
current=$(tr -d '[:space:]' < VERSION 2>/dev/null || true)
if [[ "${current%-r*}" == "$latest" ]]; then
  latest=$current
fi

printf '%s\n' "$latest"
