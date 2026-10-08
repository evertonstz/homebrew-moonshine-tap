# Integration and security

[README](../README.md) · [Compatibility](compatibility.md) · [Operations](operations.md)

## Host integration

| Resource | Location |
| --- | --- |
| Host-labeled EROFS extension | `/var/lib/extensions/moonshine-homebrew.raw` |
| Binary, wrapper and WSI/Vulkan resources | Official RPM paths under `/usr`, exposed through sysext |
| Service template, sysusers, modules, udev and polkit definitions | Owned paths under `/etc` |
| Sysext boot dependency | `/etc/systemd/system/moonshine@.service.d/10-homebrew-sysext.conf` |
| Private journal, retained RPM/images and recovery helper | `/var/lib/moonshine-homebrew` |

The system manager supervises `moonshine@ACCOUNT.service` with `User=%i`. Homebrew fetches packages and runs public hooks. The privileged Ruby helper checks integration and builds the extension. It preserves the independent enablement and running choices for existing template instances.

## Why not `brew services`?

`brew services` manages formulas, not this cask. Its normal-user systemd mode uses the user manager. Its root mode writes units under `/usr/lib/systemd/system`, which conflicts with the targeted read-only Atomic `/usr`. This tap installs its system template under writable `/etc/systemd/system`.

## Conversion tools and privileges

Homebrew installs the `libarchive` and `erofs-utils` formula dependencies. Hooks pass explicit formula-owned paths for `bsdtar`, `mkfs.erofs` and `fsck.erofs`. Privileged host commands use `/usr/sbin:/usr/bin:/sbin:/bin`, not the operator's PATH.

The helper rejects unsafe conversion-tool paths, modes and file types. If an explicitly supplied tool is missing, the helper stops without a fallback. These checks do not authenticate the tool's executable or libraries. Execution with sudo still trusts the Homebrew owner, accounts that can change its prefix and the selected formula code.

Never run Homebrew itself with sudo. Its hooks request sudo for checked host integration.

## Host policy and preservation

The helper does not layer host RPMs, relax SELinux, force sysext merging or use a wildcard host ID. It applies existing host-policy labels to private staging and checks the mounted image before activation. It refuses installation when prerequisites are missing or ownership is unsafe.

The tap never enables lingering or adds account memberships. Device and session access remain the administrator's responsibility. Do not weaken SELinux to conceal a failure.

Ordinary uninstall preserves pairing, personal configuration, account groups, lingering, administrator files and unrelated extensions. It retains cached recovery material and the saved service choices. See [ordinary uninstall](operations.md#upgrade-and-ordinary-uninstall) for cleanup and recovery behavior.

A sysext refresh briefly unmerges and remerges shared hierarchies. Other extensions' resources can disappear during that interval. The helper checks that unrelated extensions remain merged afterward. It cannot guarantee that unrelated processes remain unaffected.

## Scriptlet review

The development helper binds each approved scriptlet to its role, SHA-256 and exact `/bin/sh` interpreter arguments. Review removes trailing newline bytes before hashing. It does not automatically approve a changed digest or authenticate the publisher.

Installation executes only the checked package-extracted script. Cached extracted scripts remain necessary for uninstall and recovery. Frozen legacy recipes retain their original reviewed inputs. New candidate snapshots store approval data instead of maintained upstream script copies. See [candidate identity](candidate-channel.md#candidate-identity).

## References

- [Homebrew tap maintenance](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)
- [Homebrew cask conventions](https://docs.brew.sh/Cask-Cookbook)
- [Upstream Moonshine](https://github.com/hgaiser/moonshine)
- [License for reviewed upstream references](../reference/LICENSE)
