# Release-check fixtures

Inputs for the starter's release checker ([templates/starter/tools/release_check.py](../../templates/starter/tools/release_check.py)) and its tests ([tests/test_release_check.py](../../tests/test_release_check.py)). Owner: G8 (starter, release readiness and production pipeline).

| Entry | What it holds |
|---|---|
| [good/](good/) | A minimal generated-project tree (only the files the checker reads) that passes every automated item A01-A18; owner items (S, O, P) report OWNER_REQUIRED, never pass |
| [bad/](bad/) | One case per automated item: `bad/<case>/case.json` names the item it must trip (`expect`), why, and how it differs from `good/`: `json_set` (dotted paths), `replace`, `append`, `delete`, `images` and an optional `files/` overlay |

The tests build each tree in a temporary directory: they copy `good/`, apply the case, strip `.tmpl` (Luau sources are stored as `*.luau.tmpl` so the factory's Rojo and StyLua checks leave them alone), fill `{{SYNTHETIC_ASSET_ID}}` and `{{UPLOAD_VERB}}`, and write the store art listed in `good/images.json` as blank PNGs. Everything is synthetic and SETUP_ONLY: product ids 900000101-900000104 and asset id 900000001 name nothing real, the genre and every brief value are placeholders that decide nothing, there are no prices, owner answers or real asset ids, and the fixture code is static input that never runs. `good/src/shared/catalog.json` is also a valid GameKit catalog: [tests/release_fixture_commerce.spec.luau](../../tests/release_fixture_commerce.spec.luau) loads it through `Catalog.define` and checks that its paid random product (tag `paid_random_item`, GameKit `Commerce.RANDOM_TAG`) needs PolicyGate `paidRandomItems`.
