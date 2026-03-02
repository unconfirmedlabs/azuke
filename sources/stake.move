// Copyright (c) Unconfirmed Labs, LLC
// SPDX-License-Identifier: Apache-2.0

/// A generic staking primitive for locking fungible assets.
///
/// Stake provides a simple model for locking balances, collecting authority badges,
/// and attaching extensions. Each Stake is an independent position with immutable
/// balance — to increase total stake, create additional Stake objects. This mirrors
/// Sui's native staking model where each delegation is a separate `StakedSui` object.
///
/// ## Design Principles
///
/// - **Immutable balance**: Set at creation, never modified. Ensures correct
///   accounting when registered to multiple extensions (e.g., reward pools).
/// - **Multiple positions**: Instead of modifying existing positions, create new ones.
///   Enables partial withdrawals by destroying individual positions.
/// - **Authorities as credentials**: Permanent badges proving the position completed
///   specific interactions. Non-removable by design — a credential cannot be revoked
///   by the holder (e.g., you cannot un-burn tokens). Consumers like reward pools
///   can gate access based on these badges.
/// - **Extensions as isolated namespaces**: Each extension type gets its own isolated
///   `Bag` for storage, following the Sui Kiosk extension pattern. Access control is
///   enforced by `drop`-only witnesses — only the module defining the witness can
///   read or write its own extension data. Extensions can store multiple items in
///   their Bag (e.g., registrations with multiple reward pools).
/// - **Cooperative removal**: The owner can remove an extension only when its
///   storage is empty. The extension module controls cleanup of its own data.
/// - **Owned object model**: No capability required; object ownership provides
///   authorization. Wrap in a shared object with caps if shared access is needed.
module azuke::stake;

use std::type_name::{TypeName, with_defining_ids};
use sui::bag::{Self, Bag};
use sui::balance::Balance;
use sui::dynamic_field as df;
use sui::event::emit;
use sui::vec_set::{Self, VecSet};

// === Structs ===

/// A position holding a fixed balance of `Share` tokens.
///
/// The balance is immutable after creation. Authorities and extensions can be
/// attached to enable functionality like reward distribution or governance.
public struct Stake<phantom Share> has key, store {
    id: UID,
    /// Permanent badges proving the position completed specific interactions.
    /// Added by witness-gated modules, non-removable by the owner.
    authorities: VecSet<TypeName>,
    /// The staked balance. Immutable after creation.
    balance: Balance<Share>,
    /// Number of installed extensions. Must be 0 to destroy.
    extension_count: u64,
}

/// An extension installed on a Stake. Each extension type gets its own isolated
/// `Bag` for storage, allowing it to store multiple items keyed however it likes.
public struct Extension has store {
    storage: Bag,
}

/// Type-based dynamic field key for extensions. The phantom `Ext` type identifies
/// the extension and ensures one extension per type per Stake.
public struct ExtensionKey<phantom Ext: drop>() has copy, drop, store;

// === Events ===

/// Emitted when a stake is created.
public struct StakeCreatedEvent has copy, drop {
    stake_id: ID,
    amount: u64,
}

/// Emitted when a stake is destroyed.
public struct StakeDestroyedEvent has copy, drop {
    stake_id: ID,
    amount: u64,
}

/// Emitted when an authority is added to a stake.
public struct AuthorityAddedEvent<phantom Authority: drop> has copy, drop {
    stake_id: ID,
}

/// Emitted when an extension is installed on a stake.
public struct ExtensionInstalledEvent<phantom Ext: drop> has copy, drop {
    stake_id: ID,
}

/// Emitted when an extension is removed from a stake.
public struct ExtensionRemovedEvent<phantom Ext: drop> has copy, drop {
    stake_id: ID,
}

// === Errors ===

/// Cannot create stake with zero balance.
const EZeroBalance: u64 = 0;
/// Authority of this type is already attached.
const EAuthorityAlreadyExists: u64 = 1;
/// Cannot destroy stake with active extensions.
const EExtensionsNotEmpty: u64 = 2;
/// Extension of this type is already installed.
const EExtensionAlreadyInstalled: u64 = 3;
/// Extension of this type is not installed.
const EExtensionNotInstalled: u64 = 4;
/// Cannot remove extension with non-empty storage.
const EExtensionStorageNotEmpty: u64 = 5;

// === Public Functions ===

/// Create a new stake with the given balance.
///
/// Aborts if `balance` is zero.
public fun new<Share>(balance: Balance<Share>, ctx: &mut TxContext): Stake<Share> {
    assert!(balance.value() > 0, EZeroBalance);

    let stake = Stake {
        id: object::new(ctx),
        authorities: vec_set::empty(),
        balance,
        extension_count: 0,
    };

    emit(StakeCreatedEvent {
        stake_id: stake.id(),
        amount: stake.balance.value(),
    });

    stake
}

/// Add an authority badge to the stake.
///
/// Only the module defining the `Authority` witness type can call this, ensuring
/// that badges are only granted by the modules that control the underlying interaction
/// (e.g., a module that burns tokens before stamping the stake).
///
/// Aborts if the authority is already attached.
public fun add_authority<Share, Authority: drop>(self: &mut Stake<Share>, _: Authority) {
    let authority_type = with_defining_ids<Authority>();
    assert!(!self.authorities.contains(&authority_type), EAuthorityAlreadyExists);

    self.authorities.insert(authority_type);

    emit(AuthorityAddedEvent<Authority> {
        stake_id: self.id(),
    });
}

/// Destroy a stake and reclaim the balance.
///
/// Aborts if any extensions are still installed.
public fun destroy<Share>(stake: Stake<Share>): Balance<Share> {
    let Stake { id, balance, extension_count, .. } = stake;

    assert!(extension_count == 0, EExtensionsNotEmpty);

    emit(StakeDestroyedEvent {
        stake_id: id.to_inner(),
        amount: balance.value(),
    });

    id.delete();
    balance
}

/// Install an extension on the stake. Each extension type gets its own isolated
/// `Bag` for storage. Only the module defining `Ext` can install it.
///
/// Aborts if the extension is already installed.
public fun add_extension<Share, Ext: drop>(self: &mut Stake<Share>, _: Ext, ctx: &mut TxContext) {
    assert!(!has_extension<Share, Ext>(self), EExtensionAlreadyInstalled);

    df::add(
        &mut self.id,
        ExtensionKey<Ext>(),
        Extension {
            storage: bag::new(ctx),
        },
    );

    self.extension_count = self.extension_count + 1;

    emit(ExtensionInstalledEvent<Ext> {
        stake_id: self.id(),
    });
}

/// Remove an extension from the stake. Can only be performed when the
/// extension's storage is empty — the extension module must clean up first.
///
/// This enables cooperative removal: the extension controls its data lifecycle,
/// and the owner can reclaim the stake once all extensions are cleaned up.
public fun remove_extension<Share, Ext: drop>(self: &mut Stake<Share>) {
    assert!(has_extension<Share, Ext>(self), EExtensionNotInstalled);

    let Extension { storage } = df::remove(&mut self.id, ExtensionKey<Ext>());
    assert!(storage.is_empty(), EExtensionStorageNotEmpty);
    storage.destroy_empty();

    self.extension_count = self.extension_count - 1;

    emit(ExtensionRemovedEvent<Ext> {
        stake_id: self.id(),
    });
}

/// Get immutable access to the extension's storage. Can only be performed by
/// the extension module (requires witness).
public fun storage<Share, Ext: drop>(self: &Stake<Share>, _: Ext): &Bag {
    assert!(has_extension<Share, Ext>(self), EExtensionNotInstalled);
    &df::borrow<ExtensionKey<Ext>, Extension>(&self.id, ExtensionKey()).storage
}

/// Get mutable access to the extension's storage. Can only be performed by
/// the extension module (requires witness).
public fun storage_mut<Share, Ext: drop>(self: &mut Stake<Share>, _: Ext): &mut Bag {
    assert!(has_extension<Share, Ext>(self), EExtensionNotInstalled);
    &mut df::borrow_mut<ExtensionKey<Ext>, Extension>(&mut self.id, ExtensionKey()).storage
}

// === Accessors ===

/// Returns the stake's object ID.
public fun id<Share>(self: &Stake<Share>): ID {
    self.id.to_inner()
}

/// Returns a reference to the staked balance.
public fun balance<Share>(self: &Stake<Share>): &Balance<Share> {
    &self.balance
}

/// Returns the set of authority badges.
public fun authorities<Share>(self: &Stake<Share>): &VecSet<TypeName> {
    &self.authorities
}

/// Returns the number of installed extensions.
public fun extension_count<Share>(self: &Stake<Share>): u64 {
    self.extension_count
}

/// Check if an authority badge of the given type is attached.
public fun has_authority<Share, Authority: drop>(self: &Stake<Share>): bool {
    self.authorities.contains(&with_defining_ids<Authority>())
}

/// Check if an authority badge of the given type is attached.
public fun has_authority_by_type<Share>(self: &Stake<Share>, authority_type: &TypeName): bool {
    self.authorities.contains(authority_type)
}

/// Check if an extension is installed.
public fun has_extension<Share, Ext: drop>(self: &Stake<Share>): bool {
    df::exists_with_type<ExtensionKey<Ext>, Extension>(&self.id, ExtensionKey<Ext>())
}

/// Returns the value of the stake.
public fun value<Share>(self: &Stake<Share>): u64 {
    self.balance.value()
}
