# Contributing to Aether

## License

This repository is licensed under the **Apache License, Version 2.0**.
By contributing, you agree that your contributions are licensed under the
same terms. See [LICENSE](./LICENSE) and [NOTICE](./NOTICE).

Redistributions of source or binary form **must** include `LICENSE` and
`NOTICE` (Apache License §4).

## Security

Report vulnerabilities privately via [SECURITY.md](./SECURITY.md)
(HackerOne). Do not open public issues for security reports.

## Product policies (Grok / Aether)

- **No product telemetry** in this tree (`telemetry/` is an inert stub).
- **Privacy:** `/privacy` persists a local opt-in only; default is opt-out.
- **Secrets:** never commit API keys, `auth.json`, or session dumps.
- **Trademarks:** “Grok”, “xAI”, “SpaceXAI”, and “Aether” are marks of their
  owners; Apache-2.0 does not grant trademark rights (see NOTICE).

## Development checks

```bash
make check-license   # Apache-2.0 hygiene
make build vet test
```

Keep first-party `.odin` files with:

```
// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0
```
