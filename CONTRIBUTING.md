# Contributing to Molly

Thanks for taking the time to contribute to Molly. 🖤

Molly is a Lua/Luvit Discord bot with moderation, staff-management, economy, music, and SeaWorld-backed persistence. Contributions should preserve reliability, security, and the boundaries between Molly and the services she depends on.

## Before you start

- Search existing issues and pull requests before opening a duplicate.
- Keep changes focused. Unrelated refactors should be separate work.
- Never commit Discord tokens, Lavalink credentials, environment files, database data, private keys, or other secrets.
- Do not use production data or production credentials in tests.
- Changes to persistence, economy, moderation, interaction acknowledgement, or deployment paths need especially careful testing.

For substantial behavior or architecture changes, open an issue first so the design can be discussed before implementation.

## Development setup

Molly targets Lua 5.1/LuaJIT through Luvit. See `README.md` and `.env.example` for the current runtime and configuration contract.

Run the self-contained test suite with:

```sh
lua5.1 tests/test.lua
```

Before submitting a change, also run:

```sh
git diff --check
```

GitHub Actions runs the repository CI for pushes and pull requests targeting `main`.

## Pull requests

1. Create a focused branch from the current `main`.
2. Make the smallest coherent change that solves the problem.
3. Add or update tests for changed behavior.
4. Update documentation when public behavior, configuration, architecture, or operational requirements change.
5. Complete the pull-request template accurately.
6. Wait for CI to pass and address review feedback before merge.

A pull request should explain **what** changed, **why** it changed, and any relevant operational or compatibility impact.

## Code and reliability expectations

- Prefer explicit failure over silently pretending an operation succeeded.
- Preserve per-guild isolation and concurrency expectations.
- Discord interactions must be acknowledged within Discord's timing constraints.
- Persistence changes must respect SeaWorld's public API and transport boundary; Molly must not open SeaWorld storage files directly.
- Do not introduce automatic retries for writes unless idempotency semantics make them safe.
- Keep logs useful but free of credentials and sensitive values.
- Keep optional integrations optional: an unused integration should not break unrelated Molly features.

## Testing

Tests should be deterministic and should not require Molly's real Discord token or production services. Use mocks, fixtures, or isolated test services where appropriate.

When a change affects SeaWorld integration, use an isolated test database/service. Never point tests at Molly's production dataset.

## Commit messages

Use short, descriptive commit messages. Conventional-style prefixes such as `feat:`, `fix:`, `test:`, `docs:`, `ci:`, and `refactor:` are encouraged.

## Security issues

Do **not** disclose suspected vulnerabilities, leaked credentials, authentication bypasses, or other sensitive security issues in a public GitHub issue. Follow `SECURITY.md` instead.

## License

By contributing, you agree that your contribution will be licensed under the repository's GNU Affero General Public License v3.0 (`AGPL-3.0`).
