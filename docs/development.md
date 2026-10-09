# Development and package checks

[README](../README.md) · [Release maintenance](maintenance.md) · [Untested channel](candidate-channel.md)

## Runtime and test dependencies

Runtime tools use Ruby standard libraries. Only tests require Minitest. Install Minitest 6.0.0 as a test dependency. Current CI targets Ruby 4.0.6.

The cask requires Homebrew portable Ruby and support for public generated scripts and flight steps. Historical native lifecycle checks used Homebrew 7.0.7 and portable Ruby 4.0.7. Those checks do not establish native acceptance for every current source change.

## Local package-only checks

```sh
ruby tools/generate_cask.rb --check
ruby tools/check_releases.rb --bsdtar /absolute/path/to/bsdtar --package-dir /private/checked-rpms --compare
MOONSHINE_TEST_RPM=/private/checked-rpms/moonshine-0.16.1-1.x86_64.rpm MOONSHINE_TEST_BSDTAR=/absolute/path/to/bsdtar ruby tools/run_tests.rb --no-skips
```

The mandatory test gate fails when extraction is missing, skipped or excluded by a test filter. Keep downloaded RPMs, images, credentials and private acceptance evidence outside the shipping tree. Native host acceptance requires separate approval.

## Read-only CI and acceptance limits

Read-only [CI](https://github.com/evertonstz/homebrew-moonshine-tap/actions/workflows/ci.yml) loads all offered casks with Homebrew. It inspects and extracts retained official RPMs and runs regressions without unexpected skips. The Linux runner also loads isolated generated untested and stable-delivery fixtures. It checks complete hash versions, exact recipe tokens and official RPM pins. The checker restores the checkout and reports publication, native acceptance and host installation as false. These synthetic delivery fixtures cannot supply positive promotion prerequisites. CI does not install Moonshine on a native host.

Local YAML, shell and fixture checks do not prove Homebrew loading or GitHub-runner execution. A successful aggregate check alone is insufficient for automatic merging. The controller checks actual mandatory jobs and steps. See [protected merging](maintenance.md#publication-and-protected-merging).

Package checks do not prove streaming, native downgrade or application-data safety. See the [full acceptance limits](compatibility.md#unproved-coverage).
