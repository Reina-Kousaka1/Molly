# Security Policy

Security reports are welcome and should be handled privately whenever disclosure could put users, servers, credentials, or data at risk.

## Supported version

Molly is under active development. Security fixes are applied to the current `main` line unless a separately supported release line is documented in the future.

## Reporting a vulnerability

Please **do not open a public GitHub issue** for vulnerabilities involving, for example:

- exposed or recoverable credentials, tokens, or secrets;
- authentication or authorization bypasses;
- moderation permission bypasses;
- unsafe command execution;
- data corruption, cross-guild data exposure, or persistence isolation failures;
- vulnerabilities that could compromise Molly's host, Discord account, SeaWorld data, or connected services.

Use GitHub's private vulnerability reporting / Security interface for this repository when available. Include enough information to reproduce and assess the issue without including unrelated private data.

A useful report contains:

- affected component and revision;
- impact;
- reproducible steps or a minimal proof of concept;
- relevant redacted logs;
- suggested mitigation, if known.

Do not test vulnerabilities against servers, accounts, or datasets you do not own or have explicit permission to test.

## Secrets

Molly's real Discord token, Lavalink/Spotify credentials, environment files, private keys, and production data must never be committed to the repository or pasted into issues, pull requests, logs, or screenshots.

If a real credential is accidentally exposed, treat it as compromised and rotate/revoke it rather than relying only on deleting it from Git history.

## Scope

Reports about Molly's own code and deployment configuration belong here. Vulnerabilities in third-party projects should normally be reported to their respective maintainers unless Molly's use of the dependency creates a Molly-specific vulnerability.

Thank you for helping keep Molly and the communities using her safe. 🖤
