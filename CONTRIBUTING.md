# Contributing to liteparse-docker

Thank you for your interest in contributing! This project provides Docker packaging for [LiteParse](https://developers.llamaindex.ai/liteparse/). We welcome bug reports, feature proposals, and pull requests.

Please note that this project follows the [Contributor Covenant Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold its terms.

For **security vulnerabilities**, do not open a public issue — see [SECURITY.md](SECURITY.md) instead.

## Reporting bugs

Open a [GitHub Issue](https://github.com/rafaelgom3s/liteparse-docker/issues/new) with:

- The image flavour and tag you're using (e.g. `liteparse:full`, `liteparse:1.3.1-ocr`)
- Steps to reproduce
- Expected vs actual behaviour
- Host OS, architecture, and Docker version (`docker version`)

## Proposing features

Open a GitHub Issue describing the feature before writing code. This lets us discuss scope and approach before you invest time.

## Submitting pull requests

1. **Fork** the repo and create a branch from `main`:
   ```bash
   git checkout -b feat/my-feature
   ```

2. **Make your changes.** Follow the conventions below.

3. **Test locally** — all flavours must pass:
   ```bash
   make test-base
   make test-ocr
   make test-full
   make test-api
   ```
   Or run all at once:
   ```bash
   make test
   ```

4. **Push** and open a PR against `main`. CI will build and test all flavours automatically.

## Local development

Prerequisites: Docker, Node.js (for test fixture generation), `make`.

```bash
# Build a single flavour
make base
make ocr LANGS="eng fra"
make full LANGS="eng"

# Run tests for a flavour
make test-base

# Run all tests
make test

# Generate test fixtures only
make fixtures
```

## Conventions

### Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/):

| Prefix | When |
|---|---|
| `feat:` | New feature (new build arg, new endpoint, etc.) |
| `fix:` | Bug fix |
| `docs:` | Documentation only |
| `deps:` | Dependency updates (upstream liteparse version bumps) |
| `ci:` | CI/CD workflow changes |
| `test:` | Test additions or fixes |
| `chore:` | Maintenance (gitignore, Makefile tweaks, etc.) |

### Dockerfile

- Keep all optional `apt-get install` calls inside a single `RUN` layer with shell conditionals
- Use `--no-install-recommends` for all `apt-get install` calls
- Clean up `apt` caches in the same layer: `rm -rf /var/lib/apt/lists/*`

### Shell scripts

- Use `set -euo pipefail`
- Quote all variables: `"${VAR}"`

### Tests

- All changes must pass `make test` before merging
- New features should include test assertions in `tests/test-flavour.sh`
- API endpoint changes should update the OpenAPI spec (`api-server/openapi.yaml`)

## Upstream version bumps

LiteParse version bumps are handled automatically by the **upstream-watch** workflow (`.github/workflows/upstream-watch.yml`). It runs daily, detects new `@llamaindex/liteparse` releases on npm, and opens a PR. **Do not manually edit `.liteparse-version`** — let the automation handle it.

If you need to test with a specific upstream version, pass it as a build arg:

```bash
make full VERSION=1.3.1
```

## License

By contributing, you agree that your contributions will be licensed under the [Apache License 2.0](LICENSE).
