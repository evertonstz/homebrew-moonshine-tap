# Native report contract

The initial policy requires fresh owner-run checks on real Bazzite x86_64 with enforcing SELinux, an OSTree boot and systemd 257 or newer. Other eligible Atomic images remain untested. OS and SELinux-policy update compatibility remains under observation through normal updates. The policy does not require a forced update.

The current validator checks report claims as data. It does not collect observations, contact a host, read private logs or authenticate the report's origin. A matching result reports `publication_enabled:false`, `native_acceptance_verified:false` and `host_installation:false`. The promotion gate still exits unsuccessfully because the protected publisher is not implemented. No report creates a patch or rotates either channel.

## Identity and provenance

The policy is `reference/native-policy.json`, schema 2, profile `bazzite-owner-v1`. A report uses schema 1 and these identity fields:

| Fields | Required binding |
| --- | --- |
| `profile`, `policy_sha256` | Selected profile and SHA-256 of the exact policy-file bytes. Policy changes require a matching report. |
| `recipe_sha256`, `rpm` | Explicit retained candidate and exact RPM `version`, `filename` and `sha256`. Never substitute the moving candidate. |
| `installed_token`, `installed_version` | `moonshine@untested` and `UPSTREAM_VERSION+RECIPE_SHA256` for that exact candidate. |
| `baseline_recipe_sha256` | Current accepted stable recipe used for native upgrade/recovery testing. A changed baseline invalidates the report's upgrade-path claims. |
| `provenance` | Exactly `kind:owner-run-native` and `owner:evertonstz`. These are claims, not proof of authentication. |

The read-only promotion entrypoint requires an owner workflow dispatch on trusted main and an owner rerun actor. The protected publisher must authenticate the request/report origin. It must check the exact report digest and owner approval of the final promotion head. A locally fabricated GitHub environment or owner name cannot authorize publication. That authenticated publication path remains unfinished.

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

The output's `report_sha256` binds the canonical parsed report, including host, log and baseline claims. Object-key order and whitespace do not change it. It is distinct from a raw-file or artifact SHA-256. A future authenticated publisher must check the recorded report rather than trust an arbitrary matching summary.

Repository tests contain synthetic reports to exercise these rules. They are not native acceptance records. Existing historical Bazzite results do not approve a different recipe hash. Stable promotion and same-upstream-version replacement remain disabled pending their separate protected-publication and delivery contracts.
