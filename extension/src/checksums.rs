//! Pinned SHA-256 checksums of the release binaries.
//!
//! Generated at release time by `.github/scripts/pin-checksums.sh`.
//! EMPTY in dev builds, which means "never download".

/// `(asset name, lower-case hex sha256)` pairs.
pub const PINNED_SHA256: &[(&str, &str)] = &[];

/// Returns the pinned checksum for a release asset, if any.
pub fn pinned_sha256(asset: &str) -> Option<&'static str> {
    pinned_in(PINNED_SHA256, asset)
}

fn pinned_in(table: &'static [(&'static str, &'static str)], asset: &str) -> Option<&'static str> {
    table
        .iter()
        .find(|(name, _)| *name == asset)
        .map(|(_, sum)| *sum)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dev_build_has_no_pins() {
        assert!(PINNED_SHA256.is_empty());
        assert_eq!(pinned_sha256("flutter_run-v0.1.0-linux-x64"), None);
    }

    #[test]
    fn lookup_finds_exact_asset() {
        static TABLE: &[(&str, &str)] = &[("a", "1"), ("b", "2")];
        assert_eq!(pinned_in(TABLE, "b"), Some("2"));
        assert_eq!(pinned_in(TABLE, "c"), None);
    }
}
