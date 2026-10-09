# Release maintenance

[README](../README.md) · [Development checks](development.md) · [Untested channel](candidate-channel.md)

## Release policy

Release automation remains disabled until the owner configures its App and protection settings and completes controlled remote checks. Read-only CI runs independently. See [CI runs](https://github.com/evertonstz/homebrew-moonshine-tap/actions/workflows/ci.yml) for current results.

When enabled, the detector checks daily, on manual request, or after successful checked-main CI. Eligible recipes update only the untested channel. Stable promotion remains disabled pending protected workflow wiring and separate activation. It downloads official stable RPMs, calculates SHA-256 and checks the current pin. SHA-256 binds the downloaded bytes to a digest. It is not an independent publisher signature. The detector inspects headers, scriptlets, triggers, dependencies, inventory and protected integration content without executing package code.

Only the server and WSI binary contents can differ automatically. Packaging changes require review.

Read-only CI loads all offered casks with Homebrew. It inspects and extracts retained RPMs and runs regression tests without unexpected skips. Before an automatic merge, the controller also checks actual job and step results. A successful aggregate check alone is insufficient.

## Publication and protected merging

The publisher reconstructs the exact patch from trusted base source with a short-lived repository-scoped App token. It creates one bot branch and PR. Repeated detection reuses an unchanged expected PR. It never updates an existing branch by force or overwrites unexpected commits.

CI completion triggers the merge controller. The controller uses current trusted `main`. It never executes PR code or artifacts. It checks the repository, bot identity, one-commit patch, current base, exact head and latest CI attempt.

The protected REST squash request includes the checked head SHA. Server-side current-base protection remains required. The controller does not bypass administrator protection or push directly to `main`.

Local YAML, shell and fixture checks do not prove Homebrew loading or GitHub-runner execution. CI cannot establish native installation or downgrade acceptance.

## Owner activation checklist

App setup, protection changes and activation require separate owner approval.

1. Install a dedicated GitHub App only on this tap.

   Grant Contents write, Pull requests write, Actions read, Administration read and mandatory Metadata read. Administration read permits protection inspection only. Do not grant settings-write permission, workflow-write permission or bypass allowances.

   The publisher token requests Contents and Pull requests write plus Actions read to check main-triggered CI. The merge token also requests Administration read. Tokens expire, and the pinned action revokes them after each job.

2. Add `MOONSHINE_APP_PRIVATE_KEY` as a repository secret.

   Set repository variables `MOONSHINE_APP_ID`, `MOONSHINE_APP_SLUG`, `MOONSHINE_BOT_ID` and `MOONSHINE_CHECK_APP_ID`. Check the numeric bot identity and GitHub Actions check-provider identity from GitHub. Keep `MOONSHINE_RELEASE_UPDATES_ENABLED` and `MOONSHINE_RELEASE_SCHEDULE_ENABLED` absent or `false` initially.

3. Configure merging and protection.

   Enable squash merging. Enable auto-merge availability. Enable automatic deletion of merged branches. Protect `main` with a classic PR rule, administrator enforcement and strict up-to-date checks. Require exactly `Moonshine required validation`, bound to the verified GitHub Actions App ID.

   If you intend unattended untested publication, require PRs with zero mandatory reviews. Owner rollback still requires exact-head owner approval enforced by the controller. Stable promotion is not unattended. Disable force pushes. Disable branch deletion. Configure no bypass users, teams or apps. The controller refuses automatic merging for unknown required-check names, uninspectable settings or ruleset-only protection.

4. Do not start supervised manual tests without separate operational approval.

   Enable `MOONSHINE_RELEASE_UPDATES_ENABLED` only for those tests. Keep the schedule variable `false`. Use a bot-owned PR to test failed, skipped, missing, changed-head and changed-base cases. Check that the controller refuses each case and preserves the accepted state.

   Never relax package policy to fabricate an eligible candidate. If no eligible candidate exists, keep scheduled automation disabled until those checks can complete.

5. Set `MOONSHINE_RELEASE_SCHEDULE_ENABLED=true` only after controlled tests pass.

   Scheduled detection runs at 04:23 UTC. GitHub can delay runs or disable schedules after public-repository inactivity. Use the default-branch manual trigger for operator recovery.

   Disable `MOONSHINE_RELEASE_UPDATES_ENABLED` to stop new automated writes and merges. Review any existing PR separately.

A changed base, changed branch or closed update PR requires owner review, fresh detection and validation. The bot never automatically deletes or force-rewrites the branch or PR. Cached recovery is a host operation. It never runs in response to a tap release PR.

## References

- [Head-bound protected PR merge API](https://docs.github.com/en/rest/pulls/pulls#merge-a-pull-request)
- [Branch protection API](https://docs.github.com/en/rest/branches/branch-protection#get-branch-protection)
- [Pinned App-token action](https://github.com/actions/create-github-app-token/tree/fee1f7d63c2ff003460e3d139729b119787bc349)
- [GitHub schedule behavior](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)
