#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Refuse to ship a prebuilt module whose vermagic does not match the kernel we
# are building against.  The vendor modules were linked against 6.18.44 and the
# only reason they load on this tree is that the version field was rewritten.
# If that rewrite is ever lost -- or the kernel moves -- fail loudly here
# instead of producing an image with modules that modprobe will reject.
#
# usage: verify-vermagic.sh <ko-dir> <linux-version> <module.ko>...

set -e

dir="$1"
version="$2"
shift 2

status=0

for ko in "$@"; do
	[ -f "$dir/$ko" ] || {
		echo "airoha-pon: $ko is missing from $dir" >&2
		status=1
		continue
	}

	count=$(strings -a "$dir/$ko" |
		grep -c "^vermagic=$version " || true)

	if [ "$count" -ne 1 ]; then
		got=$(strings -a "$dir/$ko" | grep '^vermagic=' || true)
		echo "airoha-pon: $ko vermagic mismatch: want 'vermagic=$version ...', got '${got:-none}'" >&2
		status=1
		continue
	fi

	echo "airoha-pon: $ko vermagic ok (vermagic=$version)"
done

exit $status
