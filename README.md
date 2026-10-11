# Unofficial Moonshine Homebrew tap

This experimental tap installs Moonshine on eligible Fedora-family Atomic Linux x86_64 hosts. It uses pinned official [Moonshine release RPMs](https://github.com/hgaiser/moonshine/releases) to build a local, host-SELinux-labeled system extension.

Report packaging problems in [this tap's issue tracker](https://github.com/evertonstz/homebrew-moonshine-tap/issues), not Moonshine's upstream tracker. See [Moonshine](https://github.com/hgaiser/moonshine) for application documentation.

## Requirements and tested coverage

The helper requires all three conditions:

1. Linux x86_64.
2. `/etc/os-release` declares `ID=fedora` or an exact `fedora` token in `ID_LIKE`. It excludes `centos`, `rhel`, `rocky`, `almalinux` and `ol` in either field.
3. `/run/ostree-booted` exists as a regular, non-symlink file.

The host also needs enforcing targeted SELinux, systemd 257+, Xwayland, compatible runtime dependencies and virtual-input modules. Read the [full compatibility checks](docs/compatibility.md) before installation. Declared identity and a boot marker do not prove compatibility.

Bazzite is the only historically lifecycle-tested platform. An earlier recipe passed upgrades, recovery, uninstall and reinstall. The user also reported streaming, audio, keyboard/mouse input, reboot and headless streaming with pre-existing lingering.

Native installation acceptance remains unproved for the expanded eligibility source, exact-version recipes and latest uninstall cleanup. Other images, gamepad input, simultaneous multi-account lifecycles and native downgrade/data compatibility remain unproved. OS and SELinux-policy update compatibility also remains unproved. Observation continues during normal updates. A successful reboot is not update proof.

## Install and select an account

Homebrew installs `libarchive` and `erofs-utils` for local image construction. Hooks execute selected Homebrew-owned tools with sudo. This trusts the Homebrew owner, accounts that can change its prefix and the selected formula code. Read the [integration and security assumptions](docs/integration-and-security.md) first.

Never run Homebrew itself with sudo. Its hooks request sudo for checked host integration.

```sh
brew install --cask evertonstz/moonshine-tap/moonshine
```

A fresh installation does not enable or start Moonshine. Existing administrator enablement links and retained service choices can take effect during installation.

Replace `ACCOUNT` with the actual account before starting its system service:

```sh
sudo systemctl enable --now moonshine@ACCOUNT.service
```

The upstream template expects a matching account group and `/home/ACCOUNT/.config/moonshine/config.toml`. Check those assumptions against the account's home directory. Device and session access remain the administrator's responsibility. The tap does not add memberships or enable lingering. Do not weaken SELinux to conceal a failure.

Use `systemctl`, not `brew services`, for this cask. See [account and service management](docs/operations.md#account-and-service-management) for details.

## Upgrade and uninstall

An upgrade interrupts running streams. The helper saves independent enabled/running choices, removes owned integration, checks and activates the replacement, then restores those choices. On failure, it attempts cached predecessor recovery and reports any remaining recovery failure.

```sh
brew upgrade --cask evertonstz/moonshine-tap/moonshine
brew uninstall --cask evertonstz/moonshine-tap/moonshine
```

Ordinary uninstall preserves pairing, personal configuration, groups, lingering, administrator files, unrelated extensions and recovery material. It does not activate recovery. A later install can restore retained choices and resume previously running instances.

Sysext refresh briefly unmerges shared hierarchies. Other extensions' resources can disappear during that interval. The helper checks that unrelated extensions remain merged afterward, but cannot guarantee unaffected processes. See [upgrade and uninstall](docs/operations.md#upgrade-and-ordinary-uninstall).

## Versions and recovery

`moonshine` follows the latest accepted recipe. The legacy catalog offers `moonshine@0.16.1` and `moonshine@0.16.0`, with pinned RPMs and independent reviewed helpers.

New protected stable deliveries use `UPSTREAM_VERSION+FULL_RECIPE_SHA256`. Their exact tokens use `moonshine@UPSTREAM_VERSION-FULL_RECIPE_SHA256`. A recipe fix changes the offered stable version even when the upstream RPM version stays the same. Ordinary `brew upgrade` can detect that concrete version change.

Retention keeps the latest and immediate previous accepted recipes, including recipes with the same upstream version. Legacy numeric tokens keep their own recipes until expiry. Promotion does not rename installed receipts or remove cached recovery. Stable activation and native acceptance remain separately required.

Install only one Moonshine-family cask. To switch tokens, approve downtime, back up personal state, ordinarily uninstall the installed token and install the selected one. **Do not use `--zap` for version switching.** An older application may not read newer data and can lack security fixes. Follow the [version-switching procedure](docs/operations.md#exact-versions-and-bounded-rollback).

[Cached recovery](docs/operations.md#cached-recovery) requires compatible retained material and can resume services. It does not run automatically at boot or during uninstall.

## Documentation and maintenance

| Guide | Contents |
| --- | --- |
| [Compatibility](docs/compatibility.md) | Eligibility, prerequisites and acceptance limits |
| [Operations](docs/operations.md) | Accounts, upgrades, uninstall, switching and recovery |
| [Integration and security](docs/integration-and-security.md) | Host paths, service model, tool trust and SELinux |
| [Maintenance](docs/maintenance.md) | Release policy and owner activation checklist |
| [Development](docs/development.md) | Package-only checks, tests and CI |

Read-only [CI](https://github.com/evertonstz/homebrew-moonshine-tap/actions/workflows/ci.yml) runs independently of release automation. Release automation remains disabled pending separate owner-approved setup and controlled remote checks. CI does not prove native installation or downgrade safety.

## License

Tap code uses [BSD-2-Clause](LICENSE). Retain the Everton Correia 2026 and Hans Gaiser 2024 notices. Reviewed upstream references retain [their license](reference/LICENSE).
