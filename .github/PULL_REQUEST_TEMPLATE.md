## Summary

<!-- What does this pull request change? -->

## Why

<!-- What problem does it solve, or why is this change needed? -->

## Testing

- [ ] `lua5.1 tests/test.lua`
- [ ] `git diff --check`
- [ ] New or changed behavior has appropriate tests
- [ ] I did not use production data or credentials for testing

## Impact

Check every area affected by this PR:

- [ ] Discord interactions / commands
- [ ] Moderation
- [ ] Staff management
- [ ] Economy
- [ ] SeaWorld / persistence
- [ ] Music / Lavalink
- [ ] Configuration
- [ ] Docker / deployment
- [ ] Documentation only
- [ ] Other

## Safety & compatibility

- [ ] No secrets, tokens, private keys, `.env` files, or database data are included
- [ ] Logs do not expose credentials or sensitive values
- [ ] Existing behavior remains backward compatible, or the breaking change is clearly documented
- [ ] Persistence changes respect the SeaWorld public API/transport boundary
- [ ] Write retries were not added without safe idempotency semantics
- [ ] Optional integrations do not break unrelated Molly functionality

## Operational notes

<!-- Mention migrations, configuration changes, deployment steps, rollback considerations, or write "None". -->

## Screenshots / logs

<!-- Optional. Redact IDs, tokens, credentials, and other sensitive information. -->
