// The package-private constructor must be inaccessible from this dependency.
module witness_attacker::attacker;

public fun forge(): composition_royalty_pool_plugin::witness::Witness {
    composition_royalty_pool_plugin::witness::new()
}
