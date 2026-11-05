//! Binary resolution helpers: asset naming, paths, PATH selection, checksums, texts.

use sha2::{Digest, Sha256};
use std::path::PathBuf;

pub const PROXY_VERSION: &str = "0.1.0";
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
    for byte in digest.iter() {
        out.push(DIGITS[(byte >> 4) as usize] as char);
        out.push(DIGITS[(byte & 0x0f) as usize] as char);
    }
    out
}

pub fn verify_sha256(bytes: &[u8], expected_hex: &str) -> Result<(), String> {
    let actual = sha256_hex(bytes);
    if actual.eq_ignore_ascii_case(expected_hex.trim()) {
        Ok(())
    } else {
        Err(format!(
            "The downloaded flutter_run does not match its pinned checksum (expected {}, got {actual}).",
            expected_hex.trim().to_ascii_lowercase()
        ))
    }
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
        assert!(err.contains(good), "{err}");
        assert!(err.contains(&sha256_hex(b"abd")), "{err}");
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

    #[test]
    fn part_files() {
        assert!(is_part_file("flutter_run.part-12"));
        assert!(is_part_file("flutter_run.exe.part-12"));
        assert!(!is_part_file("flutter_run"));
        assert!(!is_part_file("other.part-1"));
    }
}
