# Compatibility and tested coverage

[README](../README.md) · [Installation](../README.md#install-and-select-an-account)

## Eligibility

The helper requires all three conditions.

1. Linux x86_64.
2. `/etc/os-release` declares `ID=fedora` or an exact `fedora` token in `ID_LIKE`. It excludes `centos`, `rhel`, `rocky`, `almalinux` and `ol` in either field.
3. `/run/ostree-booted` exists as a regular, non-symlink file.

For example, `ID=bluefin` with `ID_LIKE=fedora` passes the family check. `ID=centos` with `ID_LIKE="rhel fedora"` fails it. An installed `bootc` or `rpm-ostree` command does not establish an eligible boot.

OSTree deployments that use composefs can qualify when the boot marker and other checks pass. Non-OSTree bootc backends fail without that marker. The helper does not query the backend directly. Conventional Fedora installations and ARM are outside this scope.

These commands inspect the identity and marker without sudo or host changes.

```sh
grep -E '^(ID|ID_LIKE)=' /etc/os-release
stat /run/ostree-booted
```

Declared metadata and a boot marker do not prove image ancestry or compatibility. Fedora Atomic desktops, Fedora-based Bluefin, Aurora and other qualifying UBlue images remain eligible but untested. The helper excludes CentOS-based Bluefin LTS.

## Host prerequisites

Installation also requires enforcing targeted SELinux, systemd 257+, Xwayland, compatible runtime dependencies and virtual-input modules. Required host commands include `rpm`, `readelf`, `ldconfig`, `mount`, `umount`, `setfiles`, `matchpathcon`, `restorecon`, `getenforce`, `systemctl`, `systemd-sysext`, `systemd-sysusers`, `udevadm` and `modprobe`.

The helper does not layer host RPMs, relax SELinux, force sysext merging or use a wildcard host ID. It applies existing host-policy labels to private staging and checks the mounted image before activation. It refuses installation when prerequisites are missing or ownership is unsafe.

The cask requires Homebrew portable Ruby and support for public generated scripts and flight steps. Historical lifecycle checks used Homebrew 7.0.7 and portable Ruby 4.0.7. Current CI targets Ruby 4.0.6. Runtime tools use Ruby standard libraries. Only tests require Minitest.

Homebrew installs the `libarchive` and `erofs-utils` formula dependencies. See [conversion-tool trust](integration-and-security.md#conversion-tools-and-privileges) before installation.

## Historical Bazzite acceptance

Bazzite is the only lifecycle-tested platform. An earlier installed recipe passed real 0.16.0-to-0.16.1 upgrades across four combinations of independent enablement and running states. It also passed recovery after an injected setup failure, ordinary uninstall, cached recovery and reinstall.

The user reported successful streaming, audio, keyboard and mouse input, reboot and headless streaming. Headless acceptance used pre-existing lingering. The installer did not enable lingering.

This is historical acceptance of an earlier recipe, not native proof for every change in the current source.

## Unproved coverage

Native installation acceptance remains unproved for the expanded eligibility source and new exact-version recipes. Package checks do not prove streaming, safe downgrade or application-data compatibility. Other images, gamepad input and simultaneous multi-account lifecycles remain untested. VM automation remains deferred.

The uninstall failed-state cleanup has fixture coverage, not native lifecycle acceptance. Changes to tap source do not automatically rewrite hooks already cached in installed casks.

Compatibility with OS and SELinux policy updates remains unproved. Observation continues during normal host updates. A successful reboot does not prove update compatibility. A change to policy or host compatibility metadata can require rebuilding the extension.
