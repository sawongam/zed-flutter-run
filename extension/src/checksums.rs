//! Pinned SHA-256 checksums of the release binaries.
//!
//! Generated at release time by `.github/scripts/pin-checksums.sh`.
//! Empty in dev builds, which means "never download".

/// `(asset name, lower-case hex sha256)` pairs.
pub const PINNED_SHA256: &[(&str, &str)] = &[];

/// Returns the pinned checksum for a release asset, if any.
pub fn pinned_sha256(asset: &str) -> Option<&'static str> {
    PINNED_SHA256
        .iter()
        .find(|(name, _)| *name == asset)
        .map(|(_, hash)| *hash)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dev_build_has_no_pins() {
        assert!(PINNED_SHA256.is_empty());
        assert_eq!(pinned_sha256("flutter_run-v0.1.0-linux-x64"), None);
    }
}
