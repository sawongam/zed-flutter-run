//! Binary resolution helpers: asset naming, paths, PATH selection, checksums, texts.

use sha2::{Digest, Sha256};
use std::path::PathBuf;

pub const PROXY_VERSION: &str = "0.1.0"; // x-release-please-version
pub const REPO: &str = "sawongam/zed-flutter-run";
/// Flipped by the release steps once `dart pub global activate flutter_run` works.
pub const PUBLISHED_ON_PUB: bool = false;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Os {
    Mac,
    Linux,
    Windows,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Arch {
    Aarch64,
    X8664,
    X86,
}

/// Release asset name, e.g. `flutter_run-v0.1.0-linux-x64`.
/// Windows on ARM uses the x64 binary (runs under emulation).
pub fn asset_name(version: &str, os: Os, arch: Arch) -> Result<String, String> {
    let (os_part, ext) = match os {
        Os::Mac => ("macos", ""),
        Os::Linux => ("linux", ""),
        Os::Windows => ("windows", ".exe"),
    };
    let arch_part = match (os, arch) {
        (Os::Windows, Arch::Aarch64) | (_, Arch::X8664) => "x64",
        (_, Arch::Aarch64) => "arm64",
        (_, Arch::X86) => {
            return Err(
                "32-bit systems are not supported by the flutter_run release binaries.".to_string(),
            );
        }
    };
    Ok(format!("flutter_run-v{version}-{os_part}-{arch_part}{ext}"))
}

pub fn download_url(version: &str, asset: &str) -> String {
    format!("https://github.com/{REPO}/releases/download/v{version}/{asset}")
}

pub fn install_dir(version: &str) -> String {
    format!("flutter_run-{version}")
}

fn exe_name(os: Os) -> &'static str {
    if os == Os::Windows {
        "flutter_run.exe"
    } else {
        "flutter_run"
    }
}

/// Relative path of the installed binary inside the extension work dir.
pub fn binary_path(version: &str, os: Os) -> PathBuf {
    PathBuf::from(install_dir(version)).join(exe_name(os))
}

/// Relative path of a temporary download file (`.part-<n>` next to the binary).
pub fn part_path(version: &str, os: Os, n: u128) -> PathBuf {
    PathBuf::from(install_dir(version)).join(format!("{}.part-{n}", exe_name(os)))
}

/// True for `flutter_run-*` directories that are not the current version's.
pub fn is_stale_install_dir(name: &str, current_version: &str) -> bool {
    name.starts_with("flutter_run-") && name != install_dir(current_version)
}

fn is_batch_shim(path: &str) -> bool {
    let lower = path.to_ascii_lowercase();
    lower.ends_with(".bat") || lower.ends_with(".cmd")
}

/// Picks the proxy command: user setting, then PATH. On Windows `.bat`/`.cmd` shims are
/// ignored (Zed would kill only `cmd.exe` and orphan the real proxy) and `.exe` is preferred.
pub fn pick_command(
    user: Option<String>,
    which_exe: Option<String>,
    which_plain: Option<String>,
    os: Os,
) -> Option<String> {
    if let Some(user) = user.filter(|u| !u.is_empty()) {
        return Some(user);
    }
    match os {
        Os::Windows => which_exe
            .filter(|p| !is_batch_shim(p))
            .or_else(|| which_plain.filter(|p| !is_batch_shim(p))),
        _ => which_plain.or(which_exe),
    }
}

/// The `.bat`/`.cmd` shim that `pick_command` ignored on Windows, if any.
pub fn ignored_shim(
    which_exe: Option<&String>,
    which_plain: Option<&String>,
    os: Os,
) -> Option<String> {
    if os != Os::Windows {
        return None;
    }
    [which_exe, which_plain]
        .into_iter()
        .flatten()
        .find(|p| is_batch_shim(p))
        .cloned()
}

pub fn batch_shim_message(path: &str) -> String {
    format!(
        "Found {path}, but Zed cannot supervise a .bat wrapper (stopping a debug session would leave the real flutter_run running). Install the release flutter_run.exe on your PATH (see the README section \"Install\"), or set \"dap\": {{\"FlutterRun\": {{\"binary\": \"<path to flutter_run.exe>\"}}}} in Zed settings."
    )
}

/// True for leftover download files (`flutter_run[.exe].part-<n>`).
pub fn is_part_file(name: &str) -> bool {
    name.starts_with("flutter_run") && name.contains(".part-")
}

/// Lower-case hex SHA-256 (hex written by hand; `{:x}` does not work with sha2 0.11).
pub fn sha256_hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let digest = Sha256::digest(bytes);
    let mut out = String::with_capacity(digest.len() * 2);
    for byte in &digest {
        out.push(DIGITS[(byte >> 4) as usize] as char);
        out.push(DIGITS[(byte & 0x0f) as usize] as char);
    }
    out
}

/// Why the proxy binary could not be provided. Converted to text only at the Zed API boundary.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InstallError {
    /// Nothing on PATH, no setting, and no download is possible for this platform.
    NotFound,
    /// This build has an empty checksum table, so it never downloads.
    NoPinnedChecksum,
    /// A `.bat`/`.cmd` wrapper was found on Windows and ignored.
    BatchShim(String),
    /// The platform has no release binary (for example 32-bit).
    UnsupportedPlatform(String),
    DownloadFailed {
        version: String,
        detail: String,
    },
    ChecksumMismatch {
        expected: String,
        actual: String,
    },
    Io(String),
}

impl std::fmt::Display for InstallError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotFound => f.write_str(&not_found_message()),
            Self::NoPinnedChecksum => f.write_str(&no_pinned_checksum_message()),
            Self::BatchShim(path) => f.write_str(&batch_shim_message(path)),
            Self::UnsupportedPlatform(text) | Self::Io(text) => f.write_str(text),
            Self::DownloadFailed { version, detail } => {
                f.write_str(&download_failed_message(version, detail))
            }
            Self::ChecksumMismatch { expected, actual } => write!(
                f,
                "The downloaded flutter_run does not match its pinned checksum (expected {expected}, got {actual})."
            ),
        }
    }
}

impl std::error::Error for InstallError {}

impl From<InstallError> for String {
    fn from(e: InstallError) -> Self {
        e.to_string()
    }
}

pub fn verify_sha256(bytes: &[u8], expected_hex: &str) -> Result<(), InstallError> {
    let actual = sha256_hex(bytes);
    if actual.eq_ignore_ascii_case(expected_hex.trim()) {
        Ok(())
    } else {
        Err(InstallError::ChecksumMismatch {
            expected: expected_hex.trim().to_ascii_lowercase(),
            actual,
        })
    }
}

/// What the build knows about downloading a binary for this platform.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DownloadSupport {
    /// `asset_name` failed (unsupported architecture); carries its message.
    Unsupported(String),
    /// The pinned checksum table is empty (dev build).
    NoPins,
    /// The table has pins, but none for this asset.
    NotPinned,
    /// A pinned lower-case hex SHA-256 for this asset.
    Pinned(String),
}

/// State of the previously downloaded binary, as observed by the thin I/O layer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CachedBinary {
    Missing,
    /// Exists but its checksum differs (truncated, tampered or from another build).
    Corrupt,
    /// Exists and matches the pinned checksum (checked now).
    Verified,
    /// Already verified earlier in this extension instance and still on disk.
    VerifiedThisSession,
}

pub struct PlanInput {
    pub user: Option<String>,
    pub which_exe: Option<String>,
    pub which_plain: Option<String>,
    pub os: Os,
    pub download: DownloadSupport,
    pub cached: CachedBinary,
}

/// The decision of what to run; computed without any I/O.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InstallPlan {
    /// Use this command as is (user setting or PATH).
    UseCommand(String),
    /// Use the downloaded binary; `make_executable` is false when it was already prepared.
    UseCached {
        make_executable: bool,
    },
    /// Remove leftovers, download, verify against `expected`, move into place.
    Download {
        expected: String,
    },
    Fail(InstallError),
}

pub fn plan_install(input: PlanInput) -> InstallPlan {
    let PlanInput {
        user,
        which_exe,
        which_plain,
        os,
        download,
        cached,
    } = input;
    let shim = ignored_shim(which_exe.as_ref(), which_plain.as_ref(), os);
    if let Some(found) = pick_command(user, which_exe, which_plain, os) {
        return InstallPlan::UseCommand(found);
    }
    let expected = match download {
        DownloadSupport::Pinned(sum) => sum,
        other => {
            // A rejected wrapper explains the problem better than "not found".
            if let Some(shim) = shim {
                return InstallPlan::Fail(InstallError::BatchShim(shim));
            }
            return InstallPlan::Fail(match other {
                DownloadSupport::Unsupported(text) => InstallError::UnsupportedPlatform(text),
                DownloadSupport::NoPins => InstallError::NoPinnedChecksum,
                DownloadSupport::NotPinned | DownloadSupport::Pinned(_) => InstallError::NotFound,
            });
        }
    };
    match cached {
        CachedBinary::VerifiedThisSession => InstallPlan::UseCached {
            make_executable: false,
        },
        CachedBinary::Verified => InstallPlan::UseCached {
            make_executable: true,
        },
        CachedBinary::Missing | CachedBinary::Corrupt => InstallPlan::Download { expected },
    }
}

/// Names (from a directory listing) of `flutter_run-*` directories to delete.
pub fn stale_install_dirs<'a>(names: &[&'a str], current_version: &str) -> Vec<&'a str> {
    names
        .iter()
        .copied()
        .filter(|n| is_stale_install_dir(n, current_version))
        .collect()
}

/// Names of leftover download files to delete from the install directory.
pub fn leftover_part_files<'a>(names: &[&'a str]) -> Vec<&'a str> {
    names.iter().copied().filter(|n| is_part_file(n)).collect()
}

pub fn not_found_message() -> String {
    not_found_message_with(PUBLISHED_ON_PUB)
}

fn not_found_message_with(published_on_pub: bool) -> String {
    let pub_hint = if published_on_pub {
        ", or \"dart pub global activate flutter_run\""
    } else {
        ""
    };
    format!(
        "flutter_run was not found. Install it from the README section \"Install\" (release binary on your PATH{pub_hint}), or set \"dap\": {{\"FlutterRun\": {{\"binary\": \"<path>\"}}}} in Zed settings."
    )
}

pub fn no_pinned_checksum_message() -> String {
    "This build of the extension has no pinned release checksums, so it cannot download flutter_run. Install flutter_run on your PATH (see the README section \"Install\") or set \"dap\": {\"FlutterRun\": {\"binary\": \"<path>\"}} in Zed settings.".to_string()
}

pub fn download_failed_message(version: &str, err: &str) -> String {
    format!(
        "Could not download flutter_run v{version} from GitHub ({err}). Download the file for your system from https://github.com/{REPO}/releases and put it on your PATH, or set \"dap\": {{\"FlutterRun\": {{\"binary\": \"<path>\"}}}} in Zed settings."
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn asset_names() {
        let n = |os, arch| asset_name("0.1.0", os, arch).unwrap();
        assert_eq!(n(Os::Linux, Arch::X8664), "flutter_run-v0.1.0-linux-x64");
        assert_eq!(
            n(Os::Linux, Arch::Aarch64),
            "flutter_run-v0.1.0-linux-arm64"
        );
        assert_eq!(n(Os::Mac, Arch::X8664), "flutter_run-v0.1.0-macos-x64");
        assert_eq!(n(Os::Mac, Arch::Aarch64), "flutter_run-v0.1.0-macos-arm64");
        assert_eq!(
            n(Os::Windows, Arch::X8664),
            "flutter_run-v0.1.0-windows-x64.exe"
        );
        assert_eq!(
            n(Os::Windows, Arch::Aarch64),
            "flutter_run-v0.1.0-windows-x64.exe"
        );
    }

    #[test]
    fn x86_is_an_error() {
        for os in [Os::Linux, Os::Mac, Os::Windows] {
            assert!(asset_name("0.1.0", os, Arch::X86).is_err());
        }
    }

    #[test]
    fn exe_suffix_only_on_windows() {
        for os in [Os::Linux, Os::Mac] {
            assert!(
                !asset_name("0.1.0", os, Arch::X8664)
                    .unwrap()
                    .ends_with(".exe")
            );
        }
        assert!(
            asset_name("0.1.0", Os::Windows, Arch::X8664)
                .unwrap()
                .ends_with(".exe")
        );
    }

    #[test]
    fn url_and_paths() {
        assert_eq!(
            download_url("0.1.0", "flutter_run-v0.1.0-linux-x64"),
            "https://github.com/sawongam/zed-flutter-run/releases/download/v0.1.0/flutter_run-v0.1.0-linux-x64"
        );
        assert_eq!(install_dir("0.1.0"), "flutter_run-0.1.0");
        assert_eq!(
            binary_path("0.1.0", Os::Linux),
            PathBuf::from("flutter_run-0.1.0").join("flutter_run")
        );
        assert_eq!(
            binary_path("0.1.0", Os::Windows),
            PathBuf::from("flutter_run-0.1.0").join("flutter_run.exe")
        );
        assert_eq!(
            part_path("0.1.0", Os::Windows, 7),
            PathBuf::from("flutter_run-0.1.0").join("flutter_run.exe.part-7")
        );
    }

    #[test]
    fn stale_dirs() {
        assert!(is_stale_install_dir("flutter_run-0.0.9", "0.1.0"));
        assert!(!is_stale_install_dir("flutter_run-0.1.0", "0.1.0"));
        assert!(!is_stale_install_dir("something-else", "0.1.0"));
    }

    fn s(v: &str) -> Option<String> {
        Some(v.to_string())
    }

    #[test]
    fn user_path_wins() {
        assert_eq!(
            pick_command(s("/u/fr"), s("a.exe"), s("b"), Os::Windows),
            s("/u/fr")
        );
        assert_eq!(
            pick_command(s("/u/fr"), None, s("b"), Os::Linux),
            s("/u/fr")
        );
    }

    #[test]
    fn windows_ignores_bat_and_cmd() {
        assert_eq!(
            pick_command(None, None, s("C:\\p\\flutter_run.bat"), Os::Windows),
            None
        );
        assert_eq!(
            pick_command(None, None, s("C:\\p\\FLUTTER_RUN.CMD"), Os::Windows),
            None
        );
        assert_eq!(
            pick_command(
                None,
                s("C:\\p\\flutter_run.exe"),
                s("C:\\p\\flutter_run.bat"),
                Os::Windows
            ),
            s("C:\\p\\flutter_run.exe")
        );
        assert_eq!(
            pick_command(None, None, s("C:\\p\\flutter_run"), Os::Windows),
            s("C:\\p\\flutter_run")
        );
    }

    #[test]
    fn posix_uses_plain() {
        assert_eq!(
            pick_command(None, None, s("/usr/bin/flutter_run"), Os::Linux),
            s("/usr/bin/flutter_run")
        );
        assert_eq!(pick_command(None, None, None, Os::Mac), None);
    }

    #[test]
    fn sha256_vectors() {
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn verify_good_and_bad() {
        let good = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
        assert!(verify_sha256(b"abc", good).is_ok());
        assert!(verify_sha256(b"abc", &good.to_uppercase()).is_ok());
        let err = verify_sha256(b"abd", good).unwrap_err();
        assert_eq!(
            err,
            InstallError::ChecksumMismatch {
                expected: good.to_string(),
                actual: sha256_hex(b"abd"),
            }
        );
        let text = err.to_string();
        assert!(
            text.contains(good) && text.contains(&sha256_hex(b"abd")),
            "{text}"
        );
    }

    #[test]
    fn messages() {
        let nf = not_found_message_with(false);
        assert!(nf.contains("README"));
        assert!(nf.contains("\"binary\""));
        assert!(!nf.contains("pub global"));
        assert!(not_found_message_with(true).contains("dart pub global activate flutter_run"));
        let df = download_failed_message("0.1.0", "boom");
        assert!(df.contains("v0.1.0") && df.contains("boom") && df.contains("\"binary\""));
        assert!(df.contains("https://github.com/sawongam/zed-flutter-run/releases"));
    }

    #[test]
    fn shim_detection_and_message() {
        let bat = "C:\\p\\flutter_run.bat".to_string();
        assert_eq!(
            ignored_shim(None, Some(&bat), Os::Windows),
            Some(bat.clone())
        );
        assert_eq!(ignored_shim(None, Some(&bat), Os::Linux), None);
        let exe = "C:\\p\\flutter_run.exe".to_string();
        assert_eq!(ignored_shim(Some(&exe), None, Os::Windows), None);
        let m = batch_shim_message(&bat);
        assert!(
            m.contains(&bat)
                && m.contains(".bat")
                && m.contains("flutter_run.exe")
                && m.contains("\"binary\"")
        );
    }

    const SUM: &str = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

    fn input(os: Os, download: DownloadSupport, cached: CachedBinary) -> PlanInput {
        PlanInput {
            user: None,
            which_exe: None,
            which_plain: None,
            os,
            download,
            cached,
        }
    }

    fn pinned() -> DownloadSupport {
        DownloadSupport::Pinned(SUM.to_string())
    }

    #[test]
    fn plan_user_setting_beats_everything() {
        let mut i = input(Os::Linux, pinned(), CachedBinary::Verified);
        i.user = s("/u/fr");
        i.which_plain = s("/usr/bin/flutter_run");
        assert_eq!(plan_install(i), InstallPlan::UseCommand("/u/fr".into()));
    }

    #[test]
    fn plan_path_beats_download() {
        let mut i = input(Os::Linux, pinned(), CachedBinary::Missing);
        i.which_plain = s("/usr/bin/flutter_run");
        assert_eq!(
            plan_install(i),
            InstallPlan::UseCommand("/usr/bin/flutter_run".into())
        );
    }

    #[test]
    fn plan_empty_checksum_table_has_its_own_error() {
        let plan = plan_install(input(
            Os::Linux,
            DownloadSupport::NoPins,
            CachedBinary::Missing,
        ));
        assert_eq!(plan, InstallPlan::Fail(InstallError::NoPinnedChecksum));
        let text = InstallError::NoPinnedChecksum.to_string();
        assert!(text.contains("no pinned release checksums"), "{text}");
        assert!(
            text.contains("PATH") && text.contains("\"binary\""),
            "{text}"
        );
        assert_ne!(text, InstallError::NotFound.to_string());
    }

    #[test]
    fn plan_missing_pin_for_this_asset_is_not_found() {
        let plan = plan_install(input(
            Os::Mac,
            DownloadSupport::NotPinned,
            CachedBinary::Missing,
        ));
        assert_eq!(plan, InstallPlan::Fail(InstallError::NotFound));
    }

    #[test]
    fn plan_unsupported_platform_keeps_its_text() {
        let plan = plan_install(input(
            Os::Linux,
            DownloadSupport::Unsupported("32-bit".into()),
            CachedBinary::Missing,
        ));
        assert_eq!(
            plan,
            InstallPlan::Fail(InstallError::UnsupportedPlatform("32-bit".into()))
        );
    }

    #[test]
    fn plan_windows_shim_explains_itself_instead_of_not_found() {
        let bat = "C:\\p\\flutter_run.bat".to_string();
        for download in [
            DownloadSupport::NoPins,
            DownloadSupport::NotPinned,
            DownloadSupport::Unsupported("x".into()),
        ] {
            let mut i = input(Os::Windows, download, CachedBinary::Missing);
            i.which_plain = Some(bat.clone());
            assert_eq!(
                plan_install(i),
                InstallPlan::Fail(InstallError::BatchShim(bat.clone()))
            );
        }
    }

    #[test]
    fn plan_windows_shim_loses_to_a_usable_download() {
        let mut i = input(Os::Windows, pinned(), CachedBinary::Missing);
        i.which_plain = Some("C:\\p\\flutter_run.cmd".into());
        assert_eq!(
            plan_install(i),
            InstallPlan::Download {
                expected: SUM.into()
            }
        );
    }

    #[test]
    fn plan_shim_is_not_reported_on_posix() {
        let mut i = input(Os::Linux, DownloadSupport::NoPins, CachedBinary::Missing);
        i.which_plain = None;
        assert_eq!(
            plan_install(i),
            InstallPlan::Fail(InstallError::NoPinnedChecksum)
        );
    }

    #[test]
    fn plan_cache_states() {
        let plan = |c| plan_install(input(Os::Linux, pinned(), c));
        assert_eq!(
            plan(CachedBinary::VerifiedThisSession),
            InstallPlan::UseCached {
                make_executable: false
            }
        );
        assert_eq!(
            plan(CachedBinary::Verified),
            InstallPlan::UseCached {
                make_executable: true
            }
        );
        let download = InstallPlan::Download {
            expected: SUM.into(),
        };
        assert_eq!(plan(CachedBinary::Missing), download);
        // A corrupt cached file is replaced, never executed.
        assert_eq!(plan(CachedBinary::Corrupt), download);
    }

    #[test]
    fn plan_cache_is_ignored_without_a_pin() {
        // Even a "verified" cache cannot be trusted when the build has no pin.
        let plan = plan_install(input(
            Os::Linux,
            DownloadSupport::NoPins,
            CachedBinary::Verified,
        ));
        assert_eq!(plan, InstallPlan::Fail(InstallError::NoPinnedChecksum));
    }

    #[test]
    fn stale_dirs_and_leftovers_are_selected() {
        let names = [
            "flutter_run-0.0.9",
            "flutter_run-0.1.0",
            "other",
            "flutter_run-0.2.0",
        ];
        assert_eq!(
            stale_install_dirs(&names, "0.1.0"),
            ["flutter_run-0.0.9", "flutter_run-0.2.0"]
        );
        assert!(stale_install_dirs(&[], "0.1.0").is_empty());
        let files = [
            "flutter_run",
            "flutter_run.part-1",
            "flutter_run.exe.part-9",
            "x.part-2",
        ];
        assert_eq!(
            leftover_part_files(&files),
            ["flutter_run.part-1", "flutter_run.exe.part-9"]
        );
    }

    #[test]
    fn error_texts() {
        let mismatch = InstallError::ChecksumMismatch {
            expected: "aa".into(),
            actual: "bb".into(),
        };
        let text = String::from(mismatch);
        assert!(text.contains("aa") && text.contains("bb"));
        assert_eq!(
            InstallError::Io("disk full".into()).to_string(),
            "disk full"
        );
        let df = InstallError::DownloadFailed {
            version: "0.1.0".into(),
            detail: "boom".into(),
        };
        assert_eq!(df.to_string(), download_failed_message("0.1.0", "boom"));
    }

    #[test]
    fn part_files() {
        assert!(is_part_file("flutter_run.part-12"));
        assert!(is_part_file("flutter_run.exe.part-12"));
        assert!(!is_part_file("flutter_run"));
        assert!(!is_part_file("other.part-1"));
    }
}
