//! Zed extension `flutter-run-debugger`: finds the `flutter_run` proxy and describes how to run it.
//! All logic lives in the plain modules below so it can be unit-tested on the host.
#![cfg_attr(
    test,
    allow(clippy::unwrap_used, clippy::expect_used, clippy::assert_is_empty)
)]

mod checksums;
mod install;
mod locator;
mod proxy_args;

use install::{PROXY_VERSION, Selection};
use proxy_args::LaunchSpec;
use std::path::Path;
use zed_extension_api::{self as zed, Result};

#[derive(Default)]
struct FlutterRunExtension {
    /// Path of the downloaded binary whose checksum was already verified in this instance.
    verified: Option<String>,
}

fn io_error(what: &str, e: &std::io::Error) -> String {
    format!("{what}: {e}.")
}

/// The extension's working directory is the only place it may write, so paths are made absolute
/// against it before they are handed to Zed.
fn absolute(path: &Path) -> Result<String> {
    let cwd =
        std::env::current_dir().map_err(|e| io_error("Cannot read the working directory", &e))?;
    Ok(cwd.join(path).to_string_lossy().into_owned())
}

/// Release asset for this platform and the checksum pinned for it.
fn pinned_download(os: zed::Os, arch: zed::Architecture) -> Result<(String, &'static str)> {
    let asset = install::asset_name(PROXY_VERSION, os, arch)?;
    match checksums::pinned_sha256(&asset) {
        Some(sum) => Ok((asset, sum)),
        None => Err(install::missing_pin_message(
            checksums::PINNED_SHA256.is_empty(),
        )),
    }
}

/// Names of the entries of `dir` (none when it cannot be read).
fn entry_names(dir: &str) -> impl Iterator<Item = String> {
    std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| entry.file_name().into_string().ok())
}

/// Downloads `asset` to `part` and checks it against `expected`.
fn fetch_verified(asset: &str, part: &str, expected: &str) -> Result<()> {
    let url = install::download_url(PROXY_VERSION, asset);
    zed::download_file(&url, part, zed::DownloadedFileType::Uncompressed)
        .map_err(|detail| install::download_failed_message(PROXY_VERSION, &detail))?;
    let bytes = std::fs::read(part).map_err(|e| io_error(&format!("Cannot read {part}"), &e))?;
    install::verify_sha256(&bytes, expected)
}

/// Downloads, verifies and installs the binary; removes the temp file on every failure.
fn download_and_install(
    os: zed::Os,
    binary: &Path,
    binary_str: &str,
    asset: &str,
    expected: &str,
) -> Result<()> {
    let dir = install::install_dir(PROXY_VERSION);
    std::fs::create_dir_all(&dir).map_err(|e| io_error(&format!("Cannot create {dir}"), &e))?;
    for name in entry_names(&dir).filter(|n| install::is_part_file(n)) {
        let _ = std::fs::remove_file(Path::new(&dir).join(name));
    }
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos());
    let part = install::part_path(PROXY_VERSION, os, nanos);
    let result = fetch_verified(asset, &part.to_string_lossy(), expected).and_then(|()| {
        std::fs::rename(&part, binary)
            .map_err(|e| io_error("Cannot move the downloaded file into place", &e))
    });
    if result.is_err() {
        let _ = std::fs::remove_file(&part);
    }
    result?;
    zed::make_file_executable(binary_str)?;
    // Older versions' directories are no longer needed.
    let stale: Vec<String> = entry_names(".")
        .filter(|n| install::is_stale_install_dir(n, PROXY_VERSION))
        .collect();
    for name in stale {
        let _ = std::fs::remove_dir_all(name);
    }
    Ok(())
}

impl FlutterRunExtension {
    /// Finds the proxy: the user setting, then PATH, then the pinned download.
    fn resolve_command(
        &mut self,
        user: Option<String>,
        worktree: &zed::Worktree,
    ) -> Result<String> {
        let (os, arch) = zed::current_platform();
        let path_hits: Vec<String> = install::path_lookup_names(os)
            .iter()
            .filter_map(|name| worktree.which(name))
            .collect();
        let shim = match install::select_command(user, &path_hits, os) {
            Selection::Use(command) => return Ok(command),
            Selection::OnlyBatchShim(path) => Some(path),
            Selection::Nothing => None,
        };
        // A rejected wrapper explains the problem better than "not found".
        let (asset, expected) = pinned_download(os, arch)
            .map_err(|e| shim.map_or(e, |path| install::batch_shim_message(&path)))?;

        let binary = install::binary_path(PROXY_VERSION, os);
        let binary_str = absolute(&binary)?;
        if binary.exists() {
            if self.verified.as_deref() == Some(&binary_str) {
                return Ok(binary_str);
            }
            let intact = std::fs::read(&binary)
                .is_ok_and(|bytes| install::verify_sha256(&bytes, expected).is_ok());
            if intact {
                zed::make_file_executable(&binary_str)?;
                self.verified = Some(binary_str.clone());
                return Ok(binary_str);
            }
            // A truncated or tampered file is replaced, never executed.
        }
        download_and_install(os, &binary, &binary_str, &asset, expected)?;
        self.verified = Some(binary_str.clone());
        Ok(binary_str)
    }
}

impl zed::Extension for FlutterRunExtension {
    fn new() -> Self {
        Self::default()
    }

    fn get_dap_binary(
        &mut self,
        _adapter_name: String,
        config: zed::DebugTaskDefinition,
        user_provided_debug_adapter_path: Option<String>,
        worktree: &zed::Worktree,
    ) -> Result<zed::DebugAdapterBinary> {
        let cfg = proxy_args::parse_config(&config.config)?;
        let cwd = proxy_args::resolve_cwd(cfg.cwd.as_deref(), &worktree.root_path());
        let command = self.resolve_command(user_provided_debug_adapter_path, worktree)?;
        let is_windows = zed::current_platform().0 == zed::Os::Windows;
        Ok(zed::DebugAdapterBinary {
            command: Some(command),
            arguments: proxy_args::build_proxy_args(&cfg, &cwd, PROXY_VERSION),
            envs: proxy_args::merge_env(&worktree.shell_env(), &cfg.env, is_windows),
            cwd: Some(cwd),
            connection: None,
            request_args: zed::StartDebuggingRequestArguments {
                configuration: config.config,
                request: cfg.request,
            },
        })
    }

    fn dap_request_kind(
        &mut self,
        _adapter_name: String,
        config: zed::serde_json::Value,
    ) -> Result<zed::StartDebuggingRequestArgumentsRequest> {
        proxy_args::request_kind(&config)
    }

    fn dap_config_to_scenario(&mut self, config: zed::DebugConfig) -> Result<zed::DebugScenario> {
        let launch = match &config.request {
            zed::DebugRequest::Launch(l) => Some(LaunchSpec {
                program: &l.program,
                cwd: l.cwd.as_deref(),
                args: &l.args,
                envs: &l.envs,
            }),
            zed::DebugRequest::Attach(_) => None,
        };
        let scenario = proxy_args::config_to_scenario(launch, config.stop_on_entry)?;
        Ok(zed::DebugScenario {
            label: config.label,
            adapter: locator::ADAPTER_NAME.to_string(),
            build: None,
            config: scenario.to_string(),
            tcp_connection: None,
        })
    }

    fn dap_locator_create_scenario(
        &mut self,
        locator_name: String,
        build_task: zed::TaskTemplate,
        resolved_label: String,
        debug_adapter_name: String,
    ) -> Option<zed::DebugScenario> {
        if locator_name != locator::LOCATOR_NAME || debug_adapter_name != locator::ADAPTER_NAME {
            return None;
        }
        let config = locator::scenario_config(
            &build_task.command,
            &build_task.args,
            &build_task.env,
            build_task.cwd.as_deref(),
        )?;
        Some(zed::DebugScenario {
            label: resolved_label,
            adapter: debug_adapter_name,
            // No build step: the config is complete, so `run_dap_locator` is never needed.
            build: None,
            config: config.to_string(),
            tcp_connection: None,
        })
    }
}

zed::register_extension!(FlutterRunExtension);

#[cfg(test)]
mod tests {
    use serde_json::Value;

    /// Keys handled by the Dart proxy's launch rewriter and features, not read by the extension.
    const PROXY_KEYS: &[&str] = &[
        "adapter",
        "label",
        "flutterMode",
        "deviceId",
        "reloadOnSave",
        "reloadOnSaveGlobs",
        "reloadOnSaveDebounceMs",
        "openDevTools",
    ];

    fn schema() -> Value {
        serde_json::from_str(include_str!("../debug_adapter_schemas/FlutterRun.json")).unwrap()
    }

    fn properties(schema: &Value) -> &serde_json::Map<String, Value> {
        schema["properties"].as_object().unwrap()
    }

    #[test]
    fn schema_is_valid_json_with_adapter_enum() {
        let schema = schema();
        assert_eq!(schema["$schema"], "http://json-schema.org/draft-07/schema#");
        assert!(
            schema["$id"]
                .as_str()
                .unwrap()
                .ends_with("/FlutterRun.json")
        );
        assert_eq!(schema["properties"]["adapter"]["enum"][0], "FlutterRun");
        // Open on purpose, so Dart-Code launch.json entries can be pasted; the reason is documented.
        assert_eq!(schema["additionalProperties"], true);
        assert!(
            schema["description"]
                .as_str()
                .unwrap()
                .contains("Dart-Code")
        );
    }

    #[test]
    fn every_key_the_extension_reads_is_in_the_schema() {
        let schema = schema();
        let props = properties(&schema);
        for key in crate::proxy_args::READ_KEYS {
            assert!(
                props.contains_key(*key),
                "{key} is read but not in the schema"
            );
            assert_eq!(
                props[*key]["x-support"], "implemented",
                "{key} is read by the extension, so it must be marked implemented"
            );
        }
    }

    #[test]
    fn every_property_is_documented_and_classified() {
        let schema = schema();
        for (key, prop) in properties(&schema) {
            let description = prop["description"].as_str().unwrap_or_default();
            assert!(
                description.len() > 20,
                "{key}: description is missing or too short"
            );
            assert!(
                !description.to_lowercase().contains("passed through"),
                "{key}: say what the key does, not 'passed through'"
            );
            let support = prop["x-support"].as_str().unwrap_or_default();
            assert!(
                matches!(support, "implemented" | "passthrough" | "ignored"),
                "{key}: x-support is {support:?}"
            );
        }
    }

    #[test]
    fn keys_marked_implemented_are_the_ones_we_know_about() {
        // Keys handled by the extension (READ_KEYS) or by the Dart proxy's launch rewriter and
        // reload/DevTools features. The Dart side checks the proxy list in schema_test.dart.
        let schema = schema();
        let props = properties(&schema);
        for (key, prop) in props {
            if prop["x-support"] == "implemented" {
                assert!(
                    crate::proxy_args::READ_KEYS.contains(&key.as_str())
                        || PROXY_KEYS.contains(&key.as_str()),
                    "{key} is marked implemented but nothing is known to read it"
                );
            }
        }
        for key in PROXY_KEYS {
            assert_eq!(props[*key]["x-support"], "implemented", "{key}");
        }
        assert_eq!(props["platform"]["x-support"], "ignored");
    }

    #[test]
    fn proxy_keys_match_the_dart_rewriter() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../cli/lib/src/dap/launch_rewriter.dart"
        );
        let Ok(source) = std::fs::read_to_string(path) else {
            eprintln!("SKIPPED: {path} not found (crate built outside the repository)");
            return;
        };
        let start = source
            .find("ownKeys = {")
            .expect("ownKeys not found in launch_rewriter.dart");
        let body = &source[start..];
        let body = &body[body.find('{').unwrap() + 1..];
        let body = &body[..body.find('}').unwrap()];
        let mut own: Vec<&str> = body.split('\'').skip(1).step_by(2).collect();
        own.sort_unstable();
        // Keys that the extension reads itself, or that are ignored, are not in PROXY_KEYS.
        let mut expected: Vec<&str> = own
            .iter()
            .copied()
            .filter(|k| !crate::proxy_args::READ_KEYS.contains(k) && *k != "platform")
            .collect();
        expected.sort_unstable();
        let mut ours = PROXY_KEYS.to_vec();
        ours.sort_unstable();
        assert_eq!(ours, expected, "PROXY_KEYS drifted from ownKeys ({own:?})");
        // Every ownKey must at least exist in the schema.
        let schema = schema();
        for key in own {
            assert!(properties(&schema).contains_key(key), "{key} not in schema");
        }
    }

    #[test]
    fn attach_requires_a_vm_service_address() {
        let schema = schema();
        let rule = &schema["allOf"][0];
        assert_eq!(rule["if"]["properties"]["request"]["const"], "attach");
        let needed: Vec<&str> = rule["then"]["anyOf"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c["required"][0].as_str().unwrap())
            .collect();
        assert_eq!(needed, ["vmServiceUri", "vmServiceInfoFile"]);
    }

    #[test]
    fn key_fields_have_markdown_and_examples() {
        let schema = schema();
        let props = properties(&schema);
        for key in [
            "program",
            "toolArgs",
            "deviceId",
            "vmServiceUri",
            "request",
            "type",
        ] {
            assert!(props[key]["markdownDescription"].is_string(), "{key}");
        }
        for key in ["toolArgs", "deviceId", "vmServiceUri"] {
            assert!(props[key]["examples"].is_array(), "{key}");
        }
        let program = props["program"]["markdownDescription"].as_str().unwrap();
        assert!(program.contains("Launch only"), "{program}");
    }

    #[test]
    fn extension_toml_matches_constants() {
        let toml = include_str!("../extension.toml");
        assert!(toml.contains(&format!("version = \"{}\"", crate::install::PROXY_VERSION)));
        assert!(toml.contains("[debug_adapters.FlutterRun]"));
        assert!(
            include_str!("../Cargo.toml")
                .contains(&format!("version = \"{}\"", crate::install::PROXY_VERSION))
        );
    }
}
