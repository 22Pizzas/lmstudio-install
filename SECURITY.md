# Security Policy

## Supported versions

Security fixes are applied to the latest commit on the default branch (`master` / `main`).

There are no long-term support branches. If you rely on a pinned commit, rebase onto the latest default branch for patches.

## What this project does

These scripts download and install **LM Studio** from official hosts:

- `https://lmstudio.ai/...`
- `https://installers.lmstudio.ai/...`

They validate downloads with lightweight checks only (ELF/PE magic and minimum size). **LM Studio does not publish official installer checksums**, so cryptographic signature verification of the app itself is not available here.

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
- Keep your system packages (`curl`, etc.) updated.
