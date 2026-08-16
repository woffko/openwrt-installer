#!/bin/sh

set -eu

project_dir="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"

for script in \
	"$project_dir"/scripts/*.sh \
	"$project_dir"/files-installer/etc/rc.local \
	"$project_dir"/files-installer/usr/libexec/owrt-installer-autostart \
	"$project_dir"/files-installer/usr/libexec/owrt-installer-local-mouse \
	"$project_dir"/files-installer/usr/libexec/owrt-installer-ui \
	"$project_dir"/files-installer/usr/libexec/owrt-installer-config-import \
	"$project_dir"/files-installer/usr/libexec/owrt-installer-storage \
	"$project_dir"/files-installer/usr/sbin/owrt-hardware-report \
	"$project_dir"/files-installer/usr/sbin/owrt-install \
	"$project_dir"/files-target/etc/uci-defaults/98-installer-network \
	"$project_dir"/files-target/etc/owrt-installer/upgrade-guard \
	"$project_dir"/files-target/etc/owrt-installer/sysupgrade-wrapper \
	"$project_dir"/files-target/etc/owrt-installer/install-upgrade-guard \
	"$project_dir"/files-target/etc/init.d/owrt-installer-guard
do
	sh -n "$script"
done

printf 'POSIX shell syntax checks passed.\n'
