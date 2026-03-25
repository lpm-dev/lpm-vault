# LPM Vault — Native macOS App

SwiftUI menu bar + window app for managing LPM vault secrets and tokens.

## Quick Reference

- **Language:** Swift 5.9+
- **UI:** SwiftUI (macOS 14+ / Sonoma)
- **Architecture:** @Observable pattern (Observation framework)
- **Keychain:** Security framework, shared with LPM CLI (Rust)

## Build

```bash
cd LPMVault
swift build
swift test
```

Or open `LPMVault/Package.swift` in Xcode.

## Keychain Contract (shared with CLI)

Both the app and the Rust CLI read/write the same Keychain items:

```
kSecAttrService  = "dev.lpm.vault"         # All vault items share this
kSecAttrAccount  = "{vault-id}"            # UUID from project's lpm.json
kSecAttrLabel    = "{project-name}"        # Human-readable name
kSecAttrComment  = "{project-path}"        # Absolute path to project
kSecValueData    = {"KEY": "VALUE", ...}   # JSON-encoded secrets
```

## Key Patterns

- **Services are protocol-based** for testability (KeychainServiceProtocol, BiometricServiceProtocol)
- **VaultStore** is the central @Observable state manager, takes services via init
- **Menu bar app** using MenuBarExtra + Window scene
- **Face ID / Touch ID** via LocalAuthentication framework (cached for 5 min)

## Related

- [Implementation Plan](../a-package-manager/DOCS/new-features/40-vault-app-implementation-plan.md)
- [Phase 2 TODO](../a-package-manager/DOCS/new-features/40-vault-app-phase2-todo.md)
