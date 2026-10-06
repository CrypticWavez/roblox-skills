# Release-check fixtures

Inputs for the starter's release checker (`templates/starter/tools/release_check.py`, owned by G8) and its tests (`tests/test_release_check.py`).

| Entry | What it will hold |
|---|---|
| `good/` | A minimal generated-project tree that passes every automated A-check; owner items (S, O, P) report OWNER_REQUIRED, never pass |
| `bad/<case>/` | One minimal tree per A-check, each tripping exactly that check |

Owner: G8 (starter, release readiness and production pipeline). The trees are synthetic and SETUP_ONLY: no real product ids, prices, owner answers or asset ids. Empty until G8 fills it.
