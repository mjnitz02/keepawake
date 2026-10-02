# Security Policy

## Supported versions

This is a personal open-source project with no releases: `main` is the only
supported version, and security fixes land there.

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Report privately via GitHub's
[private vulnerability reporting](https://github.com/mjnitz02/keepawake/security/advisories/new),
which notifies the maintainer directly and keeps the report confidential until
a fix ships.

Expect an initial response within roughly a week. As a single-maintainer
project there is no formal SLA, but reports are taken seriously and credited
in the advisory unless you'd rather stay anonymous.

## Scope

In scope: this repository's shell scripts, the `keepawake-nudge` helper, the
launchd plists, and the GitHub Actions workflows.

Worth knowing before you report: by design, `install.sh` runs as root and
installs a root LaunchDaemon that holds the kernel's `SleepDisabled` flag, and
the nudge helper needs an Accessibility grant in order to post input events.
Those are the documented purpose of the tool, not findings in themselves — a
report about them wants to show a way for an *unprivileged* local user to
subvert the daemon, the helper, or the files they own.

Out of scope: issues that require an already compromised local machine or
pre-existing root, and vulnerabilities in macOS itself (report those to Apple).
