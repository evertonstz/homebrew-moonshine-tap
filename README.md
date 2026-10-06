# Unofficial Moonshine Homebrew tap

This user-owned tap packages Moonshine for Fedora-family Atomic Linux x86_64 hosts. It is experimental. Moonshine and Universal Blue do not maintain or endorse it. The executable payload comes from pinned official [Moonshine releases](https://github.com/hgaiser/moonshine/releases).

The repository is `evertonstz/homebrew-moonshine-tap`, separate from the Moonshine source fork. Report packaging problems in [this tap's issue tracker](https://github.com/evertonstz/homebrew-moonshine-tap/issues). Do not report tap packaging problems to Moonshine's upstream tracker.

## Eligibility and tested coverage

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

Bazzite is the only lifecycle-tested platform. An earlier installed recipe passed real 0.16.0-to-0.16.1 upgrades across four combinations of independent enablement and running states. It also passed recovery after an injected setup failure, ordinary uninstall, cached recovery and reinstall.

The user reported successful streaming, audio, keyboard and mouse input, reboot and headless streaming. Headless acceptance used pre-existing lingering. The installer did not enable lingering.

Native installation acceptance remains unproved for the expanded eligibility source and new exact-version recipes. Package checks do not prove streaming, safe downgrade or application-data compatibility. Other images, gamepad input and simultaneous multi-account lifecycles remain untested. VM automation remains deferred.

Compatibility with OS and SELinux policy updates remains unproved. Observation continues during normal host updates. A successful reboot does not prove update compatibility. A change to policy or host compatibility metadata can require rebuilding the extension.

## Prerequisites and trust

Installation also requires enforcing targeted SELinux, systemd 257+, Xwayland, compatible runtime dependencies and virtual-input modules. Required host commands include `rpm`, `readelf`, `ldconfig`, `mount`, `umount`, `setfiles`, `matchpathcon`, `restorecon`, `getenforce`, `systemctl`, `systemd-sysext`, `systemd-sysusers`, `udevadm` and `modprobe`.

The cask requires Homebrew portable Ruby and support for public generated scripts and flight steps. Historical lifecycle checks used Homebrew 7.0.7 and portable Ruby 4.0.7. Current CI targets Ruby 4.0.6. Runtime tools use Ruby standard libraries. Only tests require Minitest.

Homebrew installs the `libarchive` and `erofs-utils` formula dependencies. Hooks pass explicit formula-owned paths for `bsdtar`, `mkfs.erofs` and `fsck.erofs`. Privileged host commands use `/usr/sbin:/usr/bin:/sbin:/bin`, not the operator's PATH.

The helper rejects unsafe conversion-tool paths, modes and file types. If an explicitly supplied tool is missing, the helper stops without a fallback. These checks do not authenticate the tool's executable or libraries. Execution with sudo still trusts the Homebrew owner, accounts that can change its prefix and the selected formula code.

The helper does not layer host RPMs, relax SELinux, force sysext merging or use a wildcard host ID. It applies existing host-policy labels to private staging and checks the mounted image before activation. It refuses installation when prerequisites are missing or ownership is unsafe.

## Installation and account selection

Install the moving latest token.

```sh
brew install --cask evertonstz/moonshine-tap/moonshine
```

Never run Homebrew itself with sudo. Its hooks request sudo for checked host integration.

A fresh installation does not enable or start Moonshine. Existing administrator enablement links and retained service choices can take effect during installation. Select the actual account explicitly before starting its system service.

```sh
sudo systemctl enable --now moonshine@ACCOUNT.service
```

Replace `ACCOUNT` with the selected account. The upstream template expects a matching account group and `/home/ACCOUNT/.config/moonshine/config.toml`. Check those assumptions against the account's home directory. Device and session access remain the administrator's responsibility.

The tap never enables lingering or adds account memberships. If headless operation needs lingering, treat that as a separate administrator decision. Lingering does not guarantee device access. Do not weaken SELinux to conceal a failure.

### Host integration

| Resource | Location |
| --- | --- |
| Host-labeled EROFS extension | `/var/lib/extensions/moonshine-homebrew.raw` |
| Binary, wrapper and WSI/Vulkan resources | Official RPM paths under `/usr`, exposed through sysext |
| Service template, sysusers, modules, udev and polkit definitions | Owned paths under `/etc` |
| Sysext boot dependency | `/etc/systemd/system/moonshine@.service.d/10-homebrew-sysext.conf` |
| Private journal, retained RPM/images and recovery helper | `/var/lib/moonshine-homebrew` |

The system manager supervises `moonshine@ACCOUNT.service` with `User=%i`. Homebrew fetches packages and runs public hooks. The privileged Ruby helper checks integration and builds the extension. It preserves the independent enablement and running choices for existing template instances.

`brew services` manages formulas, not this cask. Its normal-user systemd mode uses the user manager. Its root mode writes units under `/usr/lib/systemd/system`, which conflicts with the targeted read-only Atomic `/usr`. This tap installs its system template under writable `/etc/systemd/system`.

### Upgrade and ordinary uninstall

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

An ordinary uninstall preserves pairing, personal configuration, account groups, lingering, administrator files and unrelated extensions. It does not automatically activate a recovery image. A later install can restore retained choices and resume previously running instances.

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

### Cached recovery

Inspect or explicitly recover cached host material.

```sh
sudo /var/lib/moonshine-homebrew/helper.rb status
sudo /var/lib/moonshine-homebrew/helper.rb recover
```

Recovery can interrupt services and resume previously running instances. It checks the host and policy fingerprint before acting. Recovery needs retained material, host-management tools and the recorded Ruby interpreter. It does not require new conversion. The helper refuses recovery if the fingerprint is incompatible. Recovery does not run automatically at boot or during uninstall.

Recovery may leave Homebrew's receipt different from the active host bundle. When service interruption is acceptable, use ordinary `brew reinstall --cask` of the installed token to reconcile the receipt and bundle. Selecting an older token after uninstall can require rebuilding its image. Cached recovery does not retain every offered version indefinitely.

## Release checks and owner activation

The detector runs daily or manually. It downloads official stable RPMs, calculates SHA-256 and checks the current pin. SHA-256 binds the downloaded bytes to a digest. It is not an independent publisher signature. The detector inspects headers, scriptlets, triggers, dependencies, inventory and protected integration content without executing package code.

Only the server and WSI binary contents can differ automatically. Packaging changes require review.

Read-only CI loads all offered casks with Homebrew. It inspects and extracts retained RPMs and runs regression tests without unexpected skips. Before an automatic merge, the controller also checks actual job and step results. A successful aggregate check alone is insufficient.

The publisher reconstructs the exact patch from trusted base source with a short-lived repository-scoped App token. It creates one bot branch and PR. Repeated detection reuses an unchanged expected PR. It never updates an existing branch by force or overwrites unexpected commits.

CI completion triggers the merge controller. The controller uses current trusted `main`. It never executes PR code or artifacts. It checks the repository, bot identity, one-commit patch, current base, exact head and latest CI attempt.

The protected REST squash request includes the checked head SHA. Server-side current-base protection remains required. The controller does not bypass administrator protection or push directly to `main`.

Release automation remains disabled until the owner configures its App and protection settings and completes controlled remote checks. Read-only CI runs independently. See [CI runs](https://github.com/evertonstz/homebrew-moonshine-tap/actions/workflows/ci.yml) for current results.

Local YAML, shell and fixture checks do not prove Homebrew loading or GitHub-runner execution. CI cannot establish native installation or downgrade acceptance.

### Owner activation checklist

App setup, protection changes and activation require separate owner approval.

1. Install a dedicated GitHub App only on this tap.

   Grant Contents write, Pull requests write, Actions read, Administration read and mandatory Metadata read. Administration read permits protection inspection only. Do not grant settings-write permission, workflow-write permission or bypass allowances.

   The publisher token requests only Contents and Pull requests write. The merge token also requests Actions and Administration read. Tokens expire, and the pinned action revokes them after each job.

2. Add `MOONSHINE_APP_PRIVATE_KEY` as a repository secret.

   Set repository variables `MOONSHINE_APP_ID`, `MOONSHINE_APP_SLUG`, `MOONSHINE_BOT_ID` and `MOONSHINE_CHECK_APP_ID`. Check the numeric bot identity and GitHub Actions check-provider identity from GitHub. Keep `MOONSHINE_RELEASE_UPDATES_ENABLED` and `MOONSHINE_RELEASE_SCHEDULE_ENABLED` absent or `false` initially.

3. Configure merging and protection.

   Enable squash merging. Enable auto-merge availability. Enable automatic deletion of merged branches. Protect `main` with a classic PR rule, administrator enforcement and strict up-to-date checks. Require exactly `Moonshine required validation`, bound to the verified GitHub Actions App ID.

   If you intend unattended acceptance, require PRs with zero mandatory reviews. Disable force pushes. Disable branch deletion. Configure no bypass users, teams or apps. The controller refuses automatic merging for unknown required-check names, uninspectable settings or ruleset-only protection.

4. Do not start supervised manual tests without separate operational approval.

   Enable `MOONSHINE_RELEASE_UPDATES_ENABLED` only for those tests. Keep the schedule variable `false`. Use a bot-owned PR to test failed, skipped, missing, changed-head and changed-base cases. Check that the controller refuses each case and preserves the accepted state.

   Never relax package policy to fabricate an eligible candidate. If no eligible candidate exists, keep scheduled automation disabled until those checks can complete.

5. Set `MOONSHINE_RELEASE_SCHEDULE_ENABLED=true` only after controlled tests pass.

   Scheduled detection runs at 04:23 UTC. GitHub can delay runs or disable schedules after public-repository inactivity. Use the default-branch manual trigger for operator recovery.

   Disable `MOONSHINE_RELEASE_UPDATES_ENABLED` to stop new automated writes and merges. Review any existing PR separately.

A changed base, changed branch or closed update PR requires owner review, fresh detection and validation. The bot never automatically deletes or force-rewrites the branch or PR. Cached recovery is a host operation. It never runs in response to a tap release PR.

### Local package-only checks

```sh
ruby tools/generate_cask.rb --check
ruby tools/check_releases.rb --bsdtar /absolute/path/to/bsdtar --package-dir /private/checked-rpms --compare
MOONSHINE_TEST_RPM=/private/checked-rpms/moonshine-0.16.1-1.x86_64.rpm MOONSHINE_TEST_BSDTAR=/absolute/path/to/bsdtar ruby tools/run_tests.rb --no-skips
```

Install Minitest 6.0.0 as a test dependency. The mandatory test gate fails when extraction is missing, skipped or excluded by a test filter. Keep downloaded RPMs, images, credentials and private acceptance evidence outside the shipping tree. Native host acceptance requires separate approval.

## License and references

Tap code uses [BSD-2-Clause](LICENSE). Retain the Everton Correia 2026 and Hans Gaiser 2024 notices. Reviewed upstream references retain [their license](reference/LICENSE).

- [Moonshine](https://github.com/hgaiser/moonshine) and [official releases](https://github.com/hgaiser/moonshine/releases).
- [Homebrew tap maintenance](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap) and [cask conventions](https://docs.brew.sh/Cask-Cookbook).
- [Head-bound protected PR merge API](https://docs.github.com/en/rest/pulls/pulls#merge-a-pull-request) and [branch protection API](https://docs.github.com/en/rest/branches/branch-protection#get-branch-protection).
- [Pinned App-token action](https://github.com/actions/create-github-app-token/tree/fee1f7d63c2ff003460e3d139729b119787bc349).
- [GitHub schedule behavior](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule).
