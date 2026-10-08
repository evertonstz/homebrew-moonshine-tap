# Untested recipes and stable promotion

This channel is opt-in. The official RPM can be a stable upstream release while its Homebrew integration recipe is untested.

The implementation is under review. No untested cask is selected in the initial catalog. Automation remains disabled until the owner configures the App, required checks and protected merge behavior. Stable promotion is disabled because the native evidence policy is unconfigured.

## Candidate identity

A published `moonshine@untested` cask uses `UPSTREAM_VERSION+RECIPE_SHA256`. The full SHA-256 identifies the installation recipe. It covers the pinned RPM metadata, helper bytes, token guard, approved scriptlet roles and interpreters, dependency controls and lifecycle template. It excludes Git commit IDs, timestamps, unrelated documentation, test changes and mutable acceptance status.

The RPM URL uses the separate numeric upstream version. Its checksum remains mandatory. The recipe hash does not authenticate the publisher or approve a package script.

`brew update` refreshes the published cask. Homebrew compares its concrete version with the installed version. A helper-only fix changes the recipe hash even when the RPM does not change. Hashes do not define chronological order.

## Selecting the channel

After the owner publishes a candidate, ordinarily uninstall the installed Moonshine variant before selecting the channel:

```sh
env -u SUDO_ASKPASS brew uninstall --cask evertonstz/moonshine-tap/moonshine
env -u SUDO_ASKPASS brew install --cask evertonstz/moonshine-tap/moonshine@untested
```

Use the installed token in the uninstall command if you currently use an exact-version variant. Do not install variants together or use `--zap` to switch. The command-scoped askpass removal selects terminal authentication when a GUI askpass helper is configured.

An ordinary uninstall preserves personal configuration, pairing data, service choices, groups, lingering and cached recovery. Upgrades interrupt streaming. Retaining recovery does not guarantee that older binaries can read newer data or remain secure.

## Publication and retention

Read-only inspection checks official release identity, the pinned RPM, scriptlet approvals and the packaging contract. An eligible result supplies scalar data to a separately scoped publisher. The publisher reconstructs the exact patch from trusted main. It never consumes executable candidate artifacts.

Automatic selection allows a greater numeric upstream version or a new same-version recipe from verified main ancestry. Publication binds the source commit, recipe hash, expected current candidate, operation, base and PR head. A changed base or selection requires new validation. Unrelated commits and publication commits do not generate new recipes.

Only the current candidate and immediately previous candidate retain directly selectable payloads. Older payloads expire through checked PRs. Compact identity and selection records remain. Expiration does not remove an installed cask or host recovery cache. A request for an expired target refuses instead of substituting another recipe.

The owner can request a retained rollback through the release-update workflow, supplying the exact target and a reason. The rollback still requires safety checks, protected PR validation and the owner's approval of the exact PR head. Failed native testing does not trigger automatic rollback. Automatic discovery cannot restore a superseded recipe after owner rollback.

## Stable recipes and promotion

Stable and accepted predecessor snapshots contain their complete installation templates. Candidate helper, guard or dependency changes cannot rewrite those recipes. The generator permits only checked token, version and conflict presentation changes.

Promotion previews use the selected retained candidate's exact RPM, helper, scriptlet approvals and template. They rotate only the accepted predecessor. Candidate history and the untested selection remain independent.

Positive promotion is disabled. The owner must select the required native host matrix and evidence provenance before the promotion publisher can be completed. Package extraction, hosted CI and PR approval do not establish native lifecycle or streaming acceptance. Existing Bazzite results do not transfer to a different recipe hash.

Replacing stable with a different recipe for the same upstream version also refuses. The numeric stable version would not signal an ordinary Homebrew upgrade. This requires a separate delivery policy before publication.

OS and SELinux-policy update compatibility remains under observation through normal real updates. Reboot evidence alone is not update evidence.

## Validation boundary

Hosted CI loads the shipping casks and an isolated generated untested cask on Linux and macOS. It checks full Homebrew version strings, official URLs and RPM checksums, then extracts the selected official packages. The isolated check restores its checkout afterward. It does not install Moonshine, change a native host or select a production candidate.

The source scriptlet approvals use SHA-256 after removing trailing newline bytes. The helper checks exact role and `/bin/sh` interpreter arguments. It executes package-extracted scripts only during the authorized installation lifecycle. Cached extracted scripts remain necessary for uninstall and recovery.
