# Security policy

## Report a vulnerability

Report a vulnerability privately through GitHub: open the Security tab of this repository and
choose "Report a vulnerability". Do not open a public issue for a security problem.

Include the version (`agent-balancer --version`), the steps to reproduce, and what you expected.
Do not include a real token, an email address or any other personal data in the report.

## What the tool handles

The only credential the tool keeps is a setup-token that you make yourself. It lives in a file with
mode 0600 under `~/.agent-balancer/` and is never printed, logged or passed as an argument. A
leaked setup-token cannot be cancelled and works for up to a year, so treat that folder like a
password store. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) section 14 lists the threats the
design covers.
