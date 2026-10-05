---
name: roblox-persistence-and-commerce
description: Design, audit and fix player data and commerce - DataStore schemas, versioned migrations, session locking, retry/backoff, rewards and idempotent ProcessReceipt with a receipt ledger, developer products/game passes/subscriptions in sandbox - with tests that simulate failures. Use for saves, data loss, duplication, migrations, rewards, shops and purchase flows.
---

# Persistence and commerce

**Gate.** Production skill: it acts on a game repository only after an explicit game-build request (see `FUTURE_GAME_BUILD_PROMPT.md` in the workbench). In this factory repo, run it only against fixtures. Never publish, spend Robux, create live products or touch production data without fresh approval. Live products, prices and real purchases always need Ethan's explicit approval.

**Required context.** `packages/Runtime/ReceiptLedger.luau`, `RobloxReceiptAdapter.luau`, `CommerceCatalog.luau` (inherited from the first pass; logic tested only in fixtures), `knowledge/records/analytics-release-policy.json`.

## Procedure
1. Schema inventory: keys, version field, defaults, size, write frequency, who writes. Every profile has `schemaVersion` and a forward-only migration chain with tests per step.
2. Session safety: one writer per player (session lock or UpdateAsync with a lock token), retries with backoff on throttling, save on leave and BindToClose, no saves of partially-loaded data.
3. Rewards/currency: server-only grants, idempotency keys, caps; ledger entries for anything bought or earned.
4. ProcessReceipt: return `PurchaseGranted` only after durable grant; dedupe by PurchaseId via the ledger; handle player-left and grant failures (`NotProcessedYet`).
5. Test with failure injection: DataStore errors/throttles, leave mid-save, duplicate receipts, migration from every historic version. Studio API access only on the diagnostic place; never production data.

**Acceptance.** Migration tests from every version; duplicate receipt test grants once; failed saves never overwrite good data.

**References.** `references/legacy-datastore-migration.md`.

**Related.** roblox-multiplayer-integrity, roblox-release-pass.
