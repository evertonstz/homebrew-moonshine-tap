# Release maintenance

[README](../README.md) · [Development checks](development.md) · [Untested channel](candidate-channel.md)

## Release policy

Release automation remains disabled until the owner configures the read-only protection credential and protection settings and completes controlled remote checks. Read-only CI runs independently. See [CI runs](https://github.com/evertonstz/homebrew-moonshine-tap/actions/workflows/ci.yml) for current results.

When enabled, the detector checks daily, on manual request, or after successful checked-main CI. Eligible recipes update only the untested channel. Stable promotion remains disabled pending separate operational activation. It downloads official stable RPMs, calculates SHA-256 and checks the current pin. SHA-256 binds the downloaded bytes to a digest. It is not an independent publisher signature. The detector inspects headers, scriptlets, triggers, dependencies, inventory and protected integration content without executing package code.

Only the server and WSI binary contents can differ automatically. Packaging changes require review.

New protected stable deliveries use `UPSTREAM_VERSION+FULL_RECIPE_SHA256` and exact tokens `moonshine@UPSTREAM_VERSION-FULL_RECIPE_SHA256`. The accepted catalog keeps current and previous recipes independently, including same-upstream-version fixes. Legacy numeric tokens remain fixed until their recipes expire. Installed receipts and cached recovery are not renamed or removed by catalog expiry.

Accepted-catalog schema 2 records bounded delivery style, recipe identity and modern source SHA for each slot. It checks modern sources against compact candidate history. Same-version promotion also checks strict accepted-source ancestry and current-main ancestry. A legacy seed records no invented source SHA. Its complete frozen stable snapshot must match the target source tree. Delivery metadata does not change canonical recipe bytes or RPM pins.

Read-only CI loads all offered casks with Homebrew. It inspects and extracts retained RPMs and runs regression tests without unexpected skips. Before an automatic merge, the controller also checks actual job and step results. A successful aggregate check alone is insufficient.

## Publication and protected merging

The publisher reconstructs the exact patch from trusted base source with the short-lived repository-scoped built-in `GITHUB_TOKEN`. It creates one `github-actions[bot]` branch and PR. No custom App, private key or custom bot account is required. Repeated detection reuses an unchanged expected PR. It never updates an existing branch by force or overwrites unexpected commits.

Built-in-token writes do not automatically start push CI. Token-created PR checks can require human approval. After creating a PR, the publisher explicitly dispatches the read-only `ci.yml` workflow on its checked branch; no manual approval of the token-created PR workflow is used as a prerequisite. Dispatch returns a numeric run receipt, not successful validation.

CI completion triggers the merge controller. The controller uses current trusted `main`. It never executes PR code or artifacts. It checks the repository, bot identity, one-commit patch, current base, exact head and latest CI attempt. For dispatched CI, it independently checks the tested commit belongs to the exact owned PR. Missing, foreign or incomplete associations refuse merging. Actual successful mandatory jobs and steps remain required, not merely a green run receipt.

The protected REST squash request includes the checked head SHA. Server-side current-base protection remains required. The controller does not bypass administrator protection or push directly to `main`.

After a successful squash, the controller explicitly dispatches read-only CI on the actual merged main. If that dispatch fails, the CLI reports `status:merged` with `main_ci_dispatch:failed` and exits nonzero. The merge has already happened; do not retry it or assume the accepted pins are unchanged. Owner review and a separately authorized manual CI dispatch are required. A failed PR dispatch likewise requires owner review; repeated publication does not automatically retry dispatch or overwrite a branch. GitHub reads remain mutable snapshots, not atomic transactions.

Local YAML, shell and fixture checks do not prove Homebrew loading or GitHub-runner execution. CI cannot establish native installation or downgrade acceptance.

## Owner activation checklist

Credential setup, repository settings and activation require separate owner approval. These are future operator steps, not actions performed by this implementation.

1. Create a fine-grained personal token for protection inspection only.

   Select only `evertonstz/homebrew-moonshine-tap`. Grant Administration read and mandatory Metadata read. Grant no write permission and no other repository access. Use an explicit expiry and arrange rotation. Do not paste the token into chat, command arguments, environment files or logs.

   Store it as repository secret `MOONSHINE_PROTECTION_TOKEN` only after separate approval. The controller routes it only to the fixed `GET /repos/evertonstz/homebrew-moonshine-tap/branches/main/protection` endpoint. It cannot authenticate branch, PR, CI-dispatch or merge writes. Expiry or a refused inspection stops automation; it does not relax protection.

2. Authorize built-in bot publication separately.

   The write jobs request Contents, Pull requests and Actions write using `GITHUB_TOKEN`. Actions write permits explicit CI dispatch. Package/prerequisite jobs remain read-only and receive no protection secret. Keep repository default token permissions restricted. The repository must separately permit GitHub Actions to create and approve pull requests before the built-in token can create a PR. This setting does not replace the controller's exact-head owner-review requirement for rollback or promotion.

   Bot identity is fixed to `github-actions[bot]`, numeric ID `41898282`. The GitHub Actions check provider is fixed to `15368`; it is not a user-created App. No App ID, slug, private-key or bot/check-provider variable is required. Keep `MOONSHINE_RELEASE_UPDATES_ENABLED`, `MOONSHINE_RELEASE_SCHEDULE_ENABLED` and `MOONSHINE_STABLE_PROMOTION_ENABLED` absent or `false` initially.

3. Configure merging and protection.

   Enable squash merging. Enable auto-merge availability. Enable automatic deletion of merged branches. Protect `main` with a classic PR rule, administrator enforcement and strict up-to-date checks. Require exactly `Moonshine required validation`, bound to the fixed GitHub Actions check-provider ID `15368`.

   If you intend unattended untested publication, require PRs with zero mandatory reviews. Owner rollback still requires exact-head owner approval enforced by the controller. Stable promotion is not unattended. Disable force pushes. Disable branch deletion. Configure no bypass users, teams or apps. The controller refuses automatic merging for unknown required-check names, uninspectable settings or ruleset-only protection.

4. Do not start supervised manual tests without separate operational approval.

   Enable `MOONSHINE_RELEASE_UPDATES_ENABLED` only for those tests. Keep the schedule variable `false`. Use a bot-owned PR to test failed, skipped, missing, changed-head and changed-base cases. Check that the controller refuses each case and preserves the accepted state.

   Never relax package policy to fabricate an eligible candidate. If no eligible candidate exists, keep scheduled automation disabled until those checks can complete.

5. Set `MOONSHINE_RELEASE_SCHEDULE_ENABLED=true` only after controlled tests pass.

   Scheduled detection runs at 04:23 UTC. GitHub can delay runs or disable schedules after public-repository inactivity. Use the default-branch manual trigger for operator recovery.

   Disable `MOONSHINE_RELEASE_UPDATES_ENABLED` to stop candidate writes and merges. Disable `MOONSHINE_STABLE_PROMOTION_ENABLED` to stop promotion writes and merges. Review any existing PR separately.

Stable promotion uses the separate owner-dispatched workflow and [native report contract](native-evidence.md). Its read-only job checks offered casks, retained packages and the bound source before a write job runs. Keep `MOONSHINE_STABLE_PROMOTION_ENABLED` absent or `false` until separately authorized operational checks complete. Candidate activation does not authorize stable publication. Stable-promotion activation does not authorize candidate publication.

A changed base, changed branch or closed update PR requires owner review, fresh detection and validation. The bot never automatically removes or force-rewrites the branch or PR. Cached recovery is a host operation. It never runs in response to a tap release PR.

## References

- [Head-bound protected PR merge API](https://docs.github.com/en/rest/pulls/pulls#merge-a-pull-request)
- [Branch protection API](https://docs.github.com/en/rest/branches/branch-protection#get-branch-protection)
- [Built-in token event behavior](https://docs.github.com/en/actions/concepts/security/github_token)
- [Workflow dispatch API and run receipts](https://docs.github.com/en/rest/actions/workflows#create-a-workflow-dispatch-event)
- [Repository token and PR permissions](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository)
- [GitHub schedule behavior](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)
