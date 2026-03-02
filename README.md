# Azuke

A generic staking primitive for locking fungible assets on Sui.

## Overview

Azuke provides a minimal abstraction for locking balances and attaching extensions. It's designed to be a building block for reward pools, governance systems, access control, and other protocols that require locked positions.

## Design Philosophy

### Immutable Balance

Each `Azuke` has a fixed balance set at creation. This ensures correct accounting when an azuke is registered to multiple extensions (e.g., multiple reward pools tracking the same position).

To add more tokens, create additional azukes rather than modifying existing ones. This mirrors Sui's native staking model where each validator delegation is a separate `StakedSui` object.

### Multiple Positions

Users can hold multiple `Azuke` objects. This enables:

- **Partial withdrawals**: Destroy individual azukes without affecting others
- **Flexible UX**: Frontends can split large deposits into chunks for granular control
- **Independent registration**: Each azuke can be registered to different combinations of extensions

### Extension Sandboxing

Extensions attach to azukes via a witness pattern. Each extension module defines a witness type and can only read/write its own config. This prevents unintended coupling—Extension A cannot access Extension B's state, even on the same azuke.

### Owned Object Model

`Azuke` is an owned object. Possession of `&mut Azuke` implies authorization. No capability is required.

If shared access is needed, wrap `Azuke` in a shared object with capability-based authorization.

## Architecture

```
┌─────────────────────────────────────────────────┐
│                   Azuke<Share>                   │
├─────────────────────────────────────────────────┤
│  balance: Balance<Share>     (immutable)        │
│  extensions: VecSet<TypeName> (tracking)        │
│                                                 │
│  ┌─────────────────┐  ┌─────────────────┐       │
│  │ Extension A     │  │ Extension B     │       │
│  │ (dynamic field) │  │ (dynamic field) │       │
│  │                 │  │                 │       │
│  │ ConfigA { ... } │  │ ConfigB { ... } │       │
│  └─────────────────┘  └─────────────────┘       │
└─────────────────────────────────────────────────┘
```

Extensions are stored as dynamic fields keyed by `ExtensionKey<Extension>`. The `extensions` set tracks which types are attached for enumeration and destroy-time validation.

## Usage

### Creating an Azuke

```move
use azuke::azuke;

let balance = coin::into_balance(coin);
let azuke = azuke::new(balance, ctx);
transfer::transfer(azuke, ctx.sender());
```

### Implementing an Extension

```move
module example::reward_pool;

use azuke::azuke::{Self, Azuke};

/// Witness type - only this module can construct it
public struct RewardPoolExtension has drop {}

/// Config stored on the azuke
public struct RewardPoolConfig has store, drop {
    pool_id: ID,
    last_claim_index: u256,
}

/// Register an azuke with a reward pool
public fun register<Share>(
    pool: &mut RewardPool<Share>,
    azuke: &mut Azuke<Share>,
) {
    let config = RewardPoolConfig {
        pool_id: object::id(pool),
        last_claim_index: pool.cumulative_index(),
    };
    azuke.add_extension(RewardPoolExtension {}, config);
}

/// Read registration data
public fun get_config<Share>(azuke: &Azuke<Share>): &RewardPoolConfig {
    azuke::borrow_extension(RewardPoolExtension {}, azuke)
}

/// Update registration data
public fun update_claim_index<Share>(
    azuke: &mut Azuke<Share>,
    new_index: u256,
) {
    let config = azuke::borrow_extension_mut(RewardPoolExtension {}, azuke);
    config.last_claim_index = new_index;
}

/// Unregister from the pool
public fun unregister<Share>(azuke: &mut Azuke<Share>) {
    let _config = azuke::remove_extension<Share, RewardPoolExtension, RewardPoolConfig>();
    // Config is dropped; add cleanup logic here if needed
}
```

### Destroying an Azuke

```move
// Must unregister from all extensions first
reward_pool::unregister(&mut azuke);
governance::unregister(&mut azuke);

// Now destroy and reclaim balance
let balance = azuke::destroy(azuke);
let coin = coin::from_balance(balance, ctx);
```

## API Reference

### Core Functions

| Function | Description |
|----------|-------------|
| `new<Share>(balance, ctx)` | Create an azuke with the given balance |
| `destroy<Share>(azuke)` | Destroy azuke and return balance (requires no extensions) |

### Extension Functions

| Function | Description |
|----------|-------------|
| `add_extension<S, E, C>(azuke, witness, config)` | Attach an extension |
| `borrow_extension<S, E, C>(witness, azuke)` | Read extension config |
| `borrow_extension_mut<S, E, C>(witness, azuke)` | Modify extension config |
| `remove_extension<S, E, C>(azuke)` | Remove and return extension config |

### Accessors

| Function | Description |
|----------|-------------|
| `id<Share>(azuke)` | Get azuke's object ID |
| `balance<Share>(azuke)` | Get reference to staked balance |
| `extensions<Share>(azuke)` | Get set of attached extension types |
| `has_extension<S, E>(azuke)` | Check if extension type is attached |

## Extension Architecture

Azuke uses **isolated Bag storage** rather than exposing raw `&mut UID` to extensions. This is a deliberate choice driven by Azuke's role as a generic primitive.

### Why Isolated Storage

Azuke is designed to be a building block that any third-party module can extend. The azuke owner doesn't control which extensions exist in the ecosystem or how they interact. If extensions received `&mut UID`, a registered extension could read, modify, or remove dynamic fields belonging to other extensions on the same azuke — since dynamic field keys like `ExtensionKey<phantom E>` are constructible by any module that knows the type parameter.

Isolated Bag storage makes cross-extension interference structurally impossible. Each extension gets its own `Bag`, and only the module that defines the witness type can access it. This is analogous to Rust's ownership model: rather than handing out `&mut self` to every plugin, each plugin gets `&mut its_own_field`.

### Why Cooperative Removal

Extensions control their own data lifecycle through the Bag. The azuke owner can remove an extension only when its storage is empty — the extension module decides when cleanup happens. This prevents two failure modes:

- **Orphaned state**: The owner force-removes an extension that has active registrations (e.g., staked in a reward pool), leaving dangling references.
- **Hostage-taking**: An extension refuses to release an azuke, permanently locking the user's funds.

The result is a clean separation — the extension controls its data, the owner controls their azuke, and neither party can force the other into an inconsistent state.

### Comparison with Other Models

| Model | UID Access | Isolation | Best For |
|-------|-----------|-----------|----------|
| **Azuke (Bag)** | None — extensions get `&mut Bag` | Structural | Generic primitives with untrusted extensions |
| **MusicOS (raw UID)** | `&mut UID` via witness + registration | By convention | Permissionless protocols needing full Sui primitive access |
| **Sona Player (registry)** | `&mut UID` via witness + Settings | By convention | Managed systems with centralized extension control |

## Type Parameters

- `Share`: The fungible token type being staked
- `Extension`: Witness type identifying the extension (must have `drop`)
- `Config`: Data stored for the extension (must have `store + drop`)

The `drop` requirement on `Config` ensures azuke owners can always remove extensions, even if the extension module doesn't implement graceful cleanup.

## License

Apache-2.0
