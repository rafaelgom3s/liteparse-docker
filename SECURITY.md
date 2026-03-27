# Security Policy

## Supported Versions

| Version | Supported |
|---|---|
| Latest semver (currently 1.3.x) | Yes |
| Older semver releases | No |

Only the most recent version tracked in `.liteparse-version` receives updates. Older image tags remain available on GHCR but are not patched.

## Reporting a Vulnerability

**Do not open a public GitHub Issue for security vulnerabilities.**

Instead, please use [GitHub's private vulnerability reporting](https://github.com/rafaelgom3s/liteparse-docker/security/advisories/new) to submit a report. This ensures the issue is triaged privately before any public disclosure.

In your report, please include:

- Description of the vulnerability
- Steps to reproduce
- Which image flavour and version is affected (e.g. `liteparse:1.3.1-full`)
- Potential impact

## Response

- You will receive an acknowledgment within **48 hours**
- A fix or mitigation will be prioritized based on severity
- Once resolved, a new image version will be published and the advisory disclosed

## Scope

This project provides **Docker packaging** for LiteParse. Vulnerabilities may relate to:

- Dockerfile configuration (exposed ports, permissions, privilege escalation)
- API server implementation (`api-server/server.js`)
- OCR sidecar implementation (`ocr-server/server.py`)
- CI/CD workflow security (secret leakage, injection)
- Dependency supply chain (outdated base images, npm/pip packages)

For vulnerabilities in **LiteParse itself**, please report to the [upstream project](https://github.com/run-llama/liteparse/security).
