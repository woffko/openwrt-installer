SHELLCHECK ?= $(if $(wildcard build/host-tools/usr/bin/shellcheck),build/host-tools/usr/bin/shellcheck,shellcheck)

.PHONY: all download target installer iso iso-host-tools mouse-packages clean test smoke build-env-smoke release-base-smoke ui-smoke config-import-smoke config-import-qemu-smoke local-mouse-smoke hardware-report-smoke online-install-smoke online-install-qemu-smoke local-disk-boot-smoke mouse-qemu-smoke install-flow-smoke iso-smoke vga-smoke install-smoke freeze-candidate release-gate release-gate-smoke shellcheck syntax-check

all: target installer

download:
	./scripts/download-openwrt.sh

target:
	./scripts/build-target.sh

installer: mouse-packages
	./scripts/build-installer.sh

iso: installer
	./scripts/build-hybrid-iso.sh

iso-host-tools:
	./scripts/bootstrap-iso-host-tools.sh

mouse-packages: target iso-host-tools
	./scripts/build-mouse-packages.sh

test:
	./scripts/test-qemu-uefi.sh
	./scripts/test-qemu-bios.sh

smoke:
	$(MAKE) syntax-check
	$(MAKE) shellcheck
	$(MAKE) build-env-smoke
	$(MAKE) release-base-smoke
	$(MAKE) ui-smoke
	$(MAKE) config-import-smoke
	$(MAKE) local-mouse-smoke
	$(MAKE) hardware-report-smoke
	$(MAKE) online-install-smoke
	$(MAKE) install-flow-smoke
	$(MAKE) release-gate-smoke

build-env-smoke:
	./tests/smoke/test-build-env-smoke.sh

release-base-smoke:
	./tests/smoke/test-release-base-smoke.sh

ui-smoke:
	./tests/smoke/test-ui-smoke.sh

config-import-smoke:
	./tests/smoke/test-config-import-smoke.sh

config-import-qemu-smoke:
	./scripts/test-qemu-iso-smoke.sh config-import

local-mouse-smoke:
	./tests/smoke/test-local-mouse-smoke.sh

hardware-report-smoke:
	./tests/smoke/test-hardware-report-smoke.sh

online-install-smoke:
	./tests/smoke/test-online-install-smoke.sh

online-install-qemu-smoke:
	./scripts/test-qemu-iso-smoke.sh online

local-disk-boot-smoke:
	./scripts/test-qemu-iso-smoke.sh local-disk

mouse-qemu-smoke:
	./scripts/test-qemu-local-mouse.sh

install-flow-smoke:
	./tests/smoke/test-install-flow-smoke.sh

iso-smoke:
	./scripts/test-qemu-iso-smoke.sh

vga-smoke:
	./scripts/test-qemu-iso-smoke.sh vga

install-smoke:
	./scripts/test-qemu-iso-smoke.sh install

freeze-candidate:
	./scripts/freeze-release-candidate.sh "$(VERSION)"

release-gate:
	./scripts/verify-release-candidate.sh "$(CANDIDATE)" "$(REPORT)"

release-gate-smoke:
	./tests/smoke/test-release-candidate-smoke.sh

shellcheck:
	$(SHELLCHECK) -x scripts/*.sh files-installer/usr/sbin/owrt-install \
		files-installer/usr/libexec/owrt-installer-ui \
		files-installer/usr/libexec/owrt-installer-config-import \
		files-installer/usr/libexec/owrt-installer-local-mouse \
		files-installer/usr/sbin/owrt-hardware-report \
		scripts/verify-physical-report.sh \
		files-installer/etc/rc.local \
		files-installer/usr/libexec/owrt-installer-autostart \
		files-target/etc/uci-defaults/98-installer-network \
		tests/smoke/*.sh

syntax-check:
	./scripts/syntax-check.sh

clean:
	rm -rf build/ output/
	rm -f files-installer/usr/share/owrt-installer/manifest.json
	rm -f files-installer/usr/share/owrt-installer/target.img.gz
	rm -f files-installer/usr/share/owrt-installer/98-installer-network
