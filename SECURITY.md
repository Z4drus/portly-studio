# Security policy

## Supported versions

Security fixes are provided for the latest published Portly Studio release.

## Report a vulnerability

Do not open a public issue for a security vulnerability. Open a
[private security advisory](https://github.com/Z4drus/portly-studio/security/advisories/new) with:

- the affected version;
- clear reproduction steps;
- the expected and observed behavior;
- the practical impact;
- any suggested mitigation.

Please allow time for a fix and coordinated disclosure before publishing details.

## Security model

Portly Studio starts and stops local processes and opens interactive shells, so its control API
binds only to `127.0.0.1`. Changes that expose the API to the network or execute untrusted commands
require explicit security review.

AI usage readings are taken from credentials the assistants already store on the machine
(Claude Code's keychain token, and the opt-in Codex, Cursor and Grok credentials). They are read
locally, sent only to each vendor's own usage endpoint, and never forwarded anywhere else. The app
ships no telemetry and no auto-updater.
