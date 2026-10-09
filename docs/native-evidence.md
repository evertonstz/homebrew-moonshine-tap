# Native report contract

The initial policy requires fresh owner-run checks on real Bazzite x86_64 with enforcing SELinux, an OSTree boot and systemd 257 or newer. Other eligible Atomic images remain untested. OS and SELinux-policy update compatibility remains under observation through normal updates. The policy does not require a forced update.

Offline validation checks report claims as data and reports `owner_report_authenticated:false`. The source-checking mode reads an explicit owner-authored PR comment through GitHub's API. It checks the owner's numeric account identity and exact report record, then reports `owner_report_authenticated:true`. This authenticates an owner attestation without collecting observations, contacting a host or reading private logs.

Both modes report `publication_enabled:false`, `native_acceptance_verified:false` and `host_installation:false`. Report-only requests exit unsuccessfully. Package-check mode can export checked scalar inputs. The default controller refuses stable promotion. Operational activation remains unfinished. Report assessment does not rotate either channel.

## Identity and provenance

The policy is `reference/native-policy.json`, schema 2, profile `bazzite-owner-v1`. A report uses schema 1 and these identity fields:

| Fields | Required binding |
| --- | --- |
| `profile`, `policy_sha256` | Selected profile and SHA-256 of the exact policy-file bytes. Policy changes require a matching report. |
| `recipe_sha256`, `rpm` | Explicit retained candidate and exact RPM `version`, `filename` and `sha256`. Never substitute the moving candidate. |
| `installed_token`, `installed_version` | `moonshine@untested` and `UPSTREAM_VERSION+RECIPE_SHA256` for that exact candidate. |
| `baseline_recipe_sha256` | Current accepted stable recipe used for native upgrade/recovery testing. A changed baseline invalidates the report's upgrade-path claims. |
| `provenance` | Exactly `kind:owner-run-native` and `owner:evertonstz`. These are claims, not proof of authentication. |

The read-only promotion entrypoint requires an owner workflow dispatch on trusted main and an owner rerun actor. Source-checking mode requires a GitHub-authenticated owner comment independently of those environment values. A locally fabricated GitHub environment or owner name cannot authorize publication. The controller checks owner approval of the exact final promotion head. The publisher requires successful read-only prerequisites and separate stable-promotion activation.

## Authenticated owner record

The selected source is an explicit comment on an existing PR in `evertonstz/homebrew-moonshine-tap`. No issue creation, signing key or environment approval is required. The owner posts truthful report fields only when native tests are authorized and complete. These fields are public. Raw evidence logs, credentials, pairing data and host addresses must stay private.

The raw comment body starts with `Moonshine native report v1`, two newline bytes, then the schema 1 report JSON. Do not wrap the body in Markdown fences. Bind the request to these three scalar inputs:

| Workflow input | Meaning |
| --- | --- |
| `comment_id` | Positive GitHub comment ID. It is not the PR number. |
| `comment_sha256` | SHA-256 of the exact `body` string from the GitHub response, including any trailing newline. |
| `comment_updated_at` | Exact GitHub `updated_at` timestamp in UTC. |

Calculate the body digest from the JSON response's `body` value. Do not hash the entire API response or a CLI rendering that adds newline bytes. The workflow also requires the exact candidate `target` and `expected_stable` recipe hashes.

The reader uses bounded, certificate-checked HTTPS requests to `api.github.com` without redirects. It uses only `GET` requests. The workflow token has contents-read and pull-requests-read permissions, with no App write token or stored checkout credential.

GitHub's repository owner and comment author must both be the selected `evertonstz` user with the same positive integer account ID. The requested comment ID, repository, PR and body digest must match. Missing, deleted, malformed, edited or foreign records refuse. Local cask and expected-recipe checks precede source access.

After local report validation, the reader checks the source again. The receipt records the repository ID, owner ID, comment/PR IDs, body digest and creation/update timestamps. Future publication and merge must recheck that bound source with the trusted live API client. A previously printed receipt or `owner_report_authenticated:true` value is not authorization by itself.

This receipt is a snapshot of the current record, not an immutable history of every edit. It cannot prove that the owner executed the reported observations or that a private log matches its digest. The controller checks exact-head approval, current base and repository protection before merge. These checks do not prove the reported host observations.

## Protected controller contract

The controller supports an explicit `promote` manifest with trusted base SHA, exact retained target, expected stable identity, raw comment origin and canonical report digest. It authenticates the source again and reconstructs the permitted patch from frozen inputs. It never executes PR code, a generated cask or a package with write credentials.

The patch preserves candidate selection/history, development inputs and unrelated files. Stable receives the exact candidate snapshot. The former stable becomes the accepted predecessor, and generated stable casks retain numeric upstream versions. Same-version or backwards replacement still requires a separate delivery policy and refuses.

The publisher requires scoped App credentials and strict current-base protection. It creates one bot commit, branch and PR without replacing a ref. It rechecks the source before branch and PR creation. Repeated requests reuse the same checked PR. A changed source or baseline refuses. Failed writes do not change local recipes.

Merge requires the exact reconstructed tree, base/head, bot identity, latest actual mandatory CI work and the owner's latest approval of that head. It rechecks approval and live report source before requesting a head-bound protected squash. GitHub enforces head and strict-base checks at merge. Source and review reads are current snapshots, not an atomic transaction across all mutable GitHub records.

The controller defaults to `promotions_enabled:false`. The CLI enables it only when `MOONSHINE_STABLE_PROMOTION_ENABLED` is exactly `true`. Candidate activation cannot enable it. The read-only prerequisite job cannot mint write credentials. The workflow and CLI contracts have synthetic boundary tests. Separately authorized App, protection and operational activation checks remain unfinished. No production candidate or genuine native acceptance report is selected.

## Workflow data exchange

The owner dispatch selects the target, expected stable hash and three comment-origin scalars. The prerequisite job uses trusted main with no retained checkout credentials. It loads every offered cask with Homebrew without installation. It inspects and extracts every retained official RPM through that recipe's helper and compares protected packaging contracts.

After package checks, it rechecks the live source, unchanged checkout and current main. It exports only status, base SHA, target, expected stable, comment ID/digest/time and canonical report digest. It exports no package paths, report bodies or executable artifacts. Failed checks produce no positive outputs.

The publisher checks out that bound trusted base. It requires `MOONSHINE_STABLE_PROMOTION_ENABLED=true` independently of candidate activation. Only then can it request a short-lived App token for this repository. That token grants Contents/PR write and Actions/Administration read. Administration read permits protection inspection, not settings changes. The publisher never loads a cask, extracts an RPM or executes a package helper with write credentials.

The CLI reauthenticates the source and reconstructs the exact patch from trusted inputs. It cannot accept an offline receipt or foreign candidate-publication fields as promotion authority. The merge controller distinguishes candidate and promotion activation and requires current exact-head owner approval. If CI completes before approval, the owner must approve that head and rerun its CI to trigger another protected merge check. A rerun cannot reuse approval for a different head.

Operational activation, authentic native observations and same-version delivery remain separate gates. No repository variable, App credential or setting is configured by this implementation.

## Recorded host

The `host` object contains only the following fields. Do not include account names, host addresses, pairing data, passwords or tokens.

| Fields | Required values |
| --- | --- |
| `os_id`, `image`, `version` | `bazzite`, a Bazzite image identifier and its observed version. |
| `architecture`, `ostree_booted` | `x86_64` and literal `true` from a real native boot. |
| `selinux`, `selinux_policy_sha256` | `Enforcing` and the observed host policy's SHA-256. |
| `systemd`, `kernel` | Recorded numeric systemd version of at least 257 and the observed kernel version. |
| `gpu_driver` | Recorded driver identifier/version. Coverage applies to the tested environment, not every GPU. |

The owner must collect truthful native observations. JSON declarations do not prove that OSTree, SELinux, the installed recipe or the driver actually had those values.

## Required observations

Each named entry in `checks` must be the literal string `passed`. A failed, skipped, missing or additional entry refuses validation.

| Group | Required entries |
| --- | --- |
| Installation | `install`, `start` |
| Streaming | `video`, `audio`, `keyboard_mouse` |
| Lifecycle | `upgrade`, `uninstall`, `recovery` |
| User state | `personal_data`, `groups`, `lingering` |
| Host state | `administrator_state`, `unrelated_extensions` |

The `service_states` object separately records the upgrade checks for `enabled_running`, `enabled_stopped`, `disabled_running` and `disabled_stopped`. All four must be `passed`. Recovery means the retained predecessor/cache path, not a replacement download that bypasses recovery checks. Ordinary uninstall must preserve pairing and configuration data. These requirements do not establish simultaneous multi-account or gamepad acceptance.

Record `observed_at` as a valid UTC timestamp such as `YYYY-MM-DDTHH:MM:SSZ`. Future times refuse. `log_sha256` identifies the owner's private evidence log. Keep that log private and redact credentials. The validator checks digest syntax but does not fetch the log or match its contents to that digest. Exact hashes and timestamps bind claims. They do not establish their truth or fresh execution by themselves.

The `os_policy_updates` value remains `ongoing`. Record outcomes of normal real updates separately without converting this caveat into a forced-update gate.

## Validation and publication limits

Input is at most 32 KiB with nesting limited to ten levels. The validator rejects duplicate or unknown fields, invalid identities, unsafe policy paths and mismatched observations. JSON parser errors use static categories instead of printing raw report snippets.

The output's `report_sha256` binds the canonical parsed report, including host, log and baseline claims. Object-key order and whitespace do not change it. It is distinct from a raw-file or artifact SHA-256. The controller checks the recorded report through the live API. An arbitrary matching summary cannot approve a patch.

Repository tests contain synthetic reports to exercise these rules. They are not native acceptance records. Existing historical Bazzite results do not approve a different recipe hash. Stable promotion remains disabled pending separate operational activation. Same-upstream-version replacement refuses until the owner selects its delivery contract.
