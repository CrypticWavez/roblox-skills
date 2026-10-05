---
name: roblox-persistence-and-commerce
description: Design, audit and fix player data and commerce - DataStore schemas, versioned migrations, session locking, retry/backoff, rewards and idempotent ProcessReceipt with a receipt ledger, developer products/game passes/subscriptions in sandbox - with tests that simulate failures. Use for saves, data loss, duplication, migrations, rewards, shops and purchase flows.
---

# Persistence and commerce

## Purpose
Player data that survives failures and purchases that grant exactly once. **Gate:** production skill. It acts on a game repository only after an explicit game-build request (AGENTS.md, Boundary); in this factory repo run it only against fixtures. Live products, prices and real purchases always need Ethan's explicit approval.

## Triggers
Saves, data loss, duplication, schema migrations, rewards and currency, shops, developer products, game passes, subscriptions, purchase flows.

## Inputs
Current schema(s) and their historic versions, write paths, product catalogue, reward rules, known incidents.

## Required context
`packages/Runtime/ReceiptLedger.luau` (`ReceiptLedger.new({ store, namespace, universeId, products })`, `ledger:process(receipt)`), `packages/Runtime/RobloxReceiptAdapter.luau` (`Adapter.store(dataStore)`, `Adapter.callback(ledger, onResult)` for `ProcessReceipt`), `packages/Runtime/CommerceCatalog.luau`, `knowledge/records/analytics-release-policy.json`, `references/legacy-datastore-migration.md`.

## Tools
Lune specs with a fake store (pattern: `tests/inherited.spec.luau`, `tests/runtime/run.luau`); Studio MCP `execute_luau` on the diagnostic place only (DataStore writes and purchase prompts in Luau are gated by the hooks).

## Procedure
1. Schema inventory: keys, version field, defaults, size, write frequency, writers. Every profile has `schemaVersion` and a forward-only migration chain with a test per step.
2. Session safety: one writer per player (session lock, or UpdateAsync with a lock token), retries with backoff on throttling, save on leave and in BindToClose, never save partially loaded data.
3. Rewards and currency: server-only grants, idempotency keys, caps; a ledger entry for anything bought or earned.
4. ProcessReceipt: return `PurchaseGranted` only after a durable grant; dedupe by PurchaseId through the ledger; return `NotProcessedYet` when the player left or the grant failed.
5. Test with failure injection: DataStore errors and throttles, leave mid-save, duplicate receipts, migration from every historic version. Studio API access only on the diagnostic place; never production data.

## Outputs
Schema and migration table, specs for each migration and failure case, the fixed persistence/receipt code.

## Acceptance
Migration tests from every historic version; a duplicate-receipt test grants once; failed saves never overwrite good data.

## Failure
- A test needs real DataStores: put the logic behind an adapter (`Adapter.store` pattern) and test it in Lune with a fake store.
- A hook asked about or denied a DataStore write or purchase prompt: it is gated on purpose. Proceed only on the unpublished diagnostic place in a Studio test session, and never work around a deny.

## Related
roblox-multiplayer-integrity, roblox-release-pass, roblox-luau-testing.
