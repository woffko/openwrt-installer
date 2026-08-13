SHELLCHECK ?= $(if $(wildcard build/host-tools/usr/bin/shellcheck),build/host-tools/usr/bin/shellcheck,shellcheck)

.PHONY: all download target installer iso iso-host-tools mouse-packages clean test smoke ui-smoke local-mouse-smoke hardware-report-smoke mouse-qemu-smoke install-flow-smoke iso-smoke vga-smoke install-smoke shellcheck syntax-check

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

mouse-packages: iso-host-tools
	./scripts/build-mouse-packages.sh

test:
	./scripts/test-qemu-uefi.sh
	./scripts/test-qemu-bios.sh

smoke:
	$(MAKE) syntax-check
	$(MAKE) shellcheck
	$(MAKE) ui-smoke
	$(MAKE) local-mouse-smoke
	$(MAKE) hardware-report-smoke
	$(MAKE) install-flow-smoke

ui-smoke:
	./tests/smoke/test-ui-smoke.sh

local-mouse-smoke:
	./tests/smoke/test-local-mouse-smoke.sh

hardware-report-smoke:
	./tests/smoke/test-hardware-report-smoke.sh

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

shellcheck:
	$(SHELLCHECK) -x scripts/*.sh files-installer/usr/sbin/owrt-install \
		files-installer/usr/libexec/owrt-installer-ui \
		files-installer/usr/libexec/owrt-installer-local-mouse \
		files-installer/usr/sbin/owrt-hardware-report \
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
