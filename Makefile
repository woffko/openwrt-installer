SHELLCHECK ?= $(if $(wildcard build/host-tools/usr/bin/shellcheck),build/host-tools/usr/bin/shellcheck,shellcheck)

.PHONY: all download target installer iso iso-host-tools clean test shellcheck syntax-check

all: target installer

download:
	./scripts/download-openwrt.sh

target:
	./scripts/build-target.sh

installer:
	./scripts/build-installer.sh

iso: installer
	./scripts/build-hybrid-iso.sh

iso-host-tools:
	./scripts/bootstrap-iso-host-tools.sh

test:
	./scripts/test-qemu-uefi.sh
	./scripts/test-qemu-bios.sh

shellcheck:
	$(SHELLCHECK) -x scripts/*.sh files-installer/usr/sbin/owrt-install \
		files-installer/usr/libexec/owrt-installer-ui \
		files-installer/etc/rc.local \
		files-installer/usr/libexec/owrt-installer-autostart \
		files-target/etc/uci-defaults/98-installer-network

syntax-check:
	./scripts/syntax-check.sh

clean:
	rm -rf build/ output/
	rm -f files-installer/usr/share/owrt-installer/manifest.json
	rm -f files-installer/usr/share/owrt-installer/target.img.gz
