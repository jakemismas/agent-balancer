# Security policy

## Report a vulnerability

Report a vulnerability privately through GitHub: open the Security tab of this repository and
choose "Report a vulnerability". Do not open a public issue for a security problem.

Include the version (`agent-balancer --version`), the steps to reproduce, and what you expected.
Do not include a real token, an email address or any other personal data in the report.

## What the tool handles

The only credential the tool keeps is a setup-token that you make yourself. It lives only in
`~/.agent-balancer/tokens/<label>.json` and in that label's launch files under
`~/.agent-balancer/launch/`, all mode 0600, and is never printed, logged or passed as an
argument. A write cut off part way can also leave a temporary copy in those folders, at mode
0600, until the tool deletes it; the guide's
[Where tokens live](docs/GUIDE.md#where-tokens-live) says when. A leaked setup-token can make
model requests on that subscription for up to a year, and no check has found a way to cancel
one, so treat that folder like a password store.
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) section 14 lists the threats the design covers.
