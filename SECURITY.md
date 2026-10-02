# Security policy

## Reporting a vulnerability

Please report vulnerabilities by email to **[security@rabinapps.com](mailto:security@rabinapps.com?subject=kinhin%20security%20report)**,
not in a public issue or discussion.

Include:

- the kinhin version (`kinhin version`) and your macOS version
- which forge and runtime you use, if relevant (for example GitHub Actions with Tart)
- steps to reproduce, and what an attacker could gain
- a redacted `kinhin doctor --bundle` report if it helps (it masks tokens, but check it before sending)

Never send real tokens, passwords or private keys.

## What to expect

- We aim to acknowledge your report within 3 business days.
- We will confirm the issue, keep you updated, and tell you when a fix is released.
- We ask that you give us reasonable time to fix the issue before you disclose it publicly. We are happy to credit you
  in the release notes unless you prefer to stay anonymous.

kinhin is in beta; only the latest release is supported with security fixes.

The threat model, hardening settings, and what kinhin enforces are described in [docs/security.md](docs/security.md).
