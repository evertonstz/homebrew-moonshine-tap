# Operations

[README](../README.md) · [Compatibility](compatibility.md) · [Integration and security](integration-and-security.md)

## Account and service management

Install the moving latest token.

```sh
brew install --cask evertonstz/moonshine-tap/moonshine
```

Never run Homebrew itself with sudo. Its hooks request sudo for checked host integration. Read the [conversion-tool trust assumptions](integration-and-security.md#conversion-tools-and-privileges) before installation.

A fresh installation does not enable or start Moonshine. Existing administrator enablement links and retained service choices can take effect during installation. Select the actual account explicitly before starting its system service.

```sh
sudo systemctl enable --now moonshine@ACCOUNT.service
```

Replace `ACCOUNT` with the selected account. The upstream template expects a matching account group and `/home/ACCOUNT/.config/moonshine/config.toml`. Check those assumptions against the account's home directory. Device and session access remain the administrator's responsibility.

The tap never enables lingering or adds account memberships. If headless operation needs lingering, treat that as a separate administrator decision. Lingering does not guarantee device access. Do not weaken SELinux to conceal a failure.

The system manager supervises `moonshine@ACCOUNT.service` with `User=%i`. Use `systemctl` for the instance. See [why this cask does not use `brew services`](integration-and-security.md#why-not-brew-services).

## Upgrade and ordinary uninstall

```sh
brew upgrade --cask evertonstz/moonshine-tap/moonshine
brew uninstall --cask evertonstz/moonshine-tap/moonshine
```

An upgrade interrupts running streams. Public hooks perform these steps.

1. Save the independent service choices.
2. Perform an ordinary uninstall of owned integration.
3. Build and check the replacement.
4. Activate the replacement.
5. Restore the service choices.

If an upgrade fails, the helper attempts cached predecessor recovery. It reports any remaining recovery failure.

An ordinary uninstall preserves pairing, personal configuration, account groups, lingering, administrator files and unrelated extensions. It retains the saved service choices and cached recovery material. It does not automatically activate a recovery image. A later install can restore retained choices and resume previously running instances.

Successful ordinary uninstall also clears retained failed state for recorded, stopped Moonshine instances after owned host cleanup succeeds. The helper checks that each definition is missing or retains its recorded administrator mask. It does not clear unrelated failures or remove masks. Inspection or reset errors stop cleanup and retain its service snapshot and recovery material for retry.

This cleanup does not change Moonshine's upstream SIGTERM exit behavior. It does not remove journal history. Hooks already cached in installed casks do not change automatically when tap source changes. See [acceptance limits](compatibility.md#unproved-coverage).

A sysext refresh briefly unmerges and remerges shared hierarchies. Other extensions' resources can disappear during that interval. The helper checks that unrelated extensions remain merged afterward. It cannot guarantee that unrelated processes remain unaffected.

## Exact versions and bounded rollback

The tap offers `moonshine`, `moonshine@0.16.1` and `moonshine@0.16.0`. The initial 0.16.0 snapshot contains newly reviewed compatible source. It differs from the current helper only in its exact RPM identity. This review does not establish a historical deployment of that helper.

`moonshine` follows the latest accepted release. Exact-version tokens keep their pinned RPM and independent reviewed helper. The tap offers only the latest and immediate previous accepted releases. Acceptance history determines the predecessor, even if the tap skipped upstream releases.

You can install only one Moonshine-family cask. Retained tokens declare conflicts. A guard runs as the normal user to detect installed variants before privileged changes, including expired and foreign Moonshine variants. The guard never silently replaces them.

To switch an installed moving token to the retained previous token, follow these steps.

1. Approve service interruption.
2. Make an independent backup of personal state.
3. Perform an ordinary uninstall of the installed token.
4. Install the selected retained token.

```sh
brew uninstall --cask evertonstz/moonshine-tap/moonshine
brew install --cask evertonstz/moonshine-tap/moonshine@0.16.0
```

Use the actual installed token in the uninstall command. Do not use `--zap` for version switching. When a token expires, Homebrew still uses its installed receipt for ordinary uninstall. Removing an offered definition does not change user hosts or cached recovery.

Preserving files does not guarantee that an older application can read newer configuration or pairing data. Older binaries can lack security fixes. Upstream assets may disappear. Host requirements may change, and formula dependencies are not frozen. Fixtures test cross-token downgrade. Native downgrade acceptance and application-data safety remain unproved.

## Cached recovery

Inspect or explicitly recover cached host material.

```sh
sudo /var/lib/moonshine-homebrew/helper.rb status
sudo /var/lib/moonshine-homebrew/helper.rb recover
```

Recovery can interrupt services and resume previously running instances. It checks the host and policy fingerprint before acting. Recovery needs retained material, host-management tools and the recorded Ruby interpreter. It does not require new conversion. The helper refuses recovery if the fingerprint is incompatible. Recovery does not run automatically at boot or during uninstall.

Recovery may leave Homebrew's receipt different from the active host bundle. When service interruption is acceptable, use ordinary `brew reinstall --cask` of the installed token to reconcile the receipt and bundle. Selecting an older token after uninstall can require rebuilding its image. Cached recovery does not retain every offered version indefinitely.

Cached recovery is a host operation. It never runs in response to a tap release PR.
