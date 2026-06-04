# QEMU smoke tests

Build the installer before starting QEMU:

```sh
make all
```

Start the live installer with UEFI:

```sh
./scripts/test-qemu-uefi.sh install
```

Or start the BIOS variant:

```sh
./scripts/test-qemu-bios.sh install
```

The live image is the first virtio disk (`/dev/vda`). The empty installation
target is the second virtio disk (`/dev/vdb`). Two emulated Intel e1000 NICs
are attached. Run `owrt-install --list-nics` in the guest and pass their MAC
addresses to `owrt-install`.

After installation, stop QEMU and boot the installed disk:

```sh
./scripts/test-qemu-uefi.sh boot
./scripts/test-qemu-bios.sh boot
```

