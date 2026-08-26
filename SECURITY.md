# Security Policy

## Supported versions

Security fixes are applied to the latest commit on the default branch (`master` / `main`).

There are no long-term support branches. If you rely on a pinned commit, rebase onto the latest default branch for patches.

## What this project does

These scripts download and install **LM Studio** from official hosts:

- `https://lmstudio.ai/...`
- `https://installers.lmstudio.ai/...`

Every downloaded artifact must match LM Studio's official `<artifact>.sha512` sidecar. Linux also checks ELF magic and minimum size. Windows additionally requires a valid Authenticode signature whose publisher is `Element Labs Inc.`, plus PE/MZ and minimum-size checks. Missing, malformed, or mismatched sidecars and invalid/unexpected signatures stop installation before execution or extraction.

Linux canonicalizes the configured install path and rejects broad deletion targets, unowned install trees, and foreign launcher/desktop files. Upgrades remain transactional through system integration, and failures restore the prior managed tree. The privileged `chrome-sandbox` setup opens the target once and performs inode verification, ownership, mode changes, and post-verification through that file descriptor.

Windows treats its recorded version as a cache, not proof of installation. Discovery requires a live `LM Studio.exe` and an exact registry product match. Non-interactive mode never retries with a GUI, and failed or incomplete uninstall attempts retain installer state.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security problems that could lead to:

- Arbitrary code execution via the installer scripts
- Privilege escalation (e.g. unsafe `sudo` / SUID handling)
- Path traversal or overwrite of unexpected locations
- Supply-chain issues in how URLs or artifacts are resolved

### Preferred reporting channel

1. Use [GitHub Security Advisories](https://github.com/22Pizzas/lmstudio-install/security/advisories/new) for this repository (private report), **or**
2. Contact the repository owner via GitHub if advisories are unavailable.

Include:

- Affected script (`lm-studio-install.sh` / `lm-studio-install.ps1`) and commit/tag
- OS and architecture
- Clear reproduction steps
- Impact assessment (what an attacker could achieve)
- Optional patch or suggested fix

### Response expectations

- Acknowledgement when maintainers are available
- Coordinated disclosure after a fix is ready, when practical
- Credit for reporters who want it (unless you prefer anonymity)

## Out of scope

- Vulnerabilities in **LM Studio** itself (report to the LM Studio project / vendor)
- Issues that require already-compromised local accounts with write access to the install path
- Social engineering or phishing against end users

## Hardening tips for users

- Review the scripts before running them, especially when piped from the network.
- Prefer cloning this repo and running local files over `curl | bash` when possible.
- On Linux, understand that `chrome-sandbox` SUID setup uses `sudo`.
- Keep your system packages (`curl`, coreutils, etc.) updated.
- Treat checksum/signature failures as fatal; do not bypass them to force an install.
