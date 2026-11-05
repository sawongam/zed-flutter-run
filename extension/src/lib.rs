//! Zed extension `flutter-run-debugger`: finds the `flutter_run` proxy and describes how to run it.
//! All logic lives in the plain modules below so it can be unit-tested on the host.

mod checksums;
mod install;
mod proxy_args;

use install::{Arch, Os};
use proxy_args::{LaunchSpec, Request};
use std::path::Path;
use zed_extension_api::{self as zed, Result};

#[derive(Default)]
struct FlutterRunExtension {
    /// Path of the downloaded binary whose checksum was already verified in this instance.
    verified: Option<String>,
}

fn host_os() -> Os {
    match zed::current_platform().0 {
        zed::Os::Mac => Os::Mac,
        zed::Os::Linux => Os::Linux,
        zed::Os::Windows => Os::Windows,
    }
}

fn host_arch() -> Arch {
    match zed::current_platform().1 {
        zed::Architecture::Aarch64 => Arch::Aarch64,
        zed::Architecture::X8664 => Arch::X8664,
        zed::Architecture::X86 => Arch::X86,
    }
}

fn to_request_kind(request: Request) -> zed::StartDebuggingRequestArgumentsRequest {
    match request {
        Request::Launch => zed::StartDebuggingRequestArgumentsRequest::Launch,
        Request::Attach => zed::StartDebuggingRequestArgumentsRequest::Attach,
    }
}

fn absolute(path: &Path) -> Result<String> {
    let cwd =
        std::env::current_dir().map_err(|e| format!("Cannot read the working directory: {e}."))?;
    Ok(cwd.join(path).to_string_lossy().into_owned())
}

impl FlutterRunExtension {
    /// Returns the path of a verified, executable downloaded binary.
    fn download_binary(&mut self, os: Os, arch: Arch) -> Result<String> {
        let version = install::PROXY_VERSION;
        let asset = install::asset_name(version, os, arch)?;
        let Some(expected) = checksums::pinned_sha256(&asset) else {
            return Err(install::not_found_message());
        };
        let dir = install::install_dir(version);
        let binary = install::binary_path(version, os);
        let binary_str = absolute(&binary)?;

        if self.verified.as_deref() == Some(binary_str.as_str()) && binary.exists() {
            return Ok(binary_str);
        }
        if let Ok(bytes) = std::fs::read(&binary)
            && install::verify_sha256(&bytes, expected).is_ok()
        {
            zed::make_file_executable(&binary_str)?;
            self.verified = Some(binary_str.clone());
            return Ok(binary_str);
        }

        std::fs::create_dir_all(&dir).map_err(|e| format!("Cannot create {dir}: {e}."))?;
        if let Ok(entries) = std::fs::read_dir(&dir) {
            for entry in entries.flatten() {
                if entry
                    .file_name()
                    .to_str()
                    .is_some_and(install::is_part_file)
                {
                    let _ = std::fs::remove_file(entry.path());
                }
            }
        }
        let n = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let part = install::part_path(version, os, n);
        let part_str = part.to_string_lossy().into_owned();
        let url = install::download_url(version, &asset);

        if let Err(e) = zed::download_file(&url, &part_str, zed::DownloadedFileType::Uncompressed) {
            let _ = std::fs::remove_file(&part);
            return Err(install::download_failed_message(version, &e));
        }
        let bytes = std::fs::read(&part).map_err(|e| {
            let _ = std::fs::remove_file(&part);
            format!("Cannot read {part_str}: {e}.")
        })?;
        if let Err(e) = install::verify_sha256(&bytes, expected) {
            let _ = std::fs::remove_file(&part);
            return Err(e);
        }
        std::fs::rename(&part, &binary).map_err(|e| {
            let _ = std::fs::remove_file(&part);
            format!("Cannot move the downloaded file into place: {e}.")
        })?;
        zed::make_file_executable(&binary_str)?;

        if let Ok(entries) = std::fs::read_dir(".") {
            for entry in entries.flatten() {
                if let Some(name) = entry.file_name().to_str()
                    && install::is_stale_install_dir(name, version)
                {
                    let _ = std::fs::remove_dir_all(entry.path());
                }
            }
        }
        self.verified = Some(binary_str.clone());
        Ok(binary_str)
    }

    fn resolve_command(
        &mut self,
        user: Option<String>,
        worktree: &zed::Worktree,
    ) -> Result<String> {
        let os = host_os();
        let (which_exe, which_plain) = if os == Os::Windows {
            (
                worktree.which("flutter_run.exe"),
                worktree.which("flutter_run"),
            )
        } else {
            (None, worktree.which("flutter_run"))
        };
        let shim = install::ignored_shim(which_exe.as_ref(), which_plain.as_ref(), os);
        if let Some(found) = install::pick_command(user, which_exe, which_plain, os) {
            return Ok(found);
        }
        match (self.download_binary(os, host_arch()), shim) {
            (Err(e), Some(shim)) if e == install::not_found_message() => {
                Err(install::batch_shim_message(&shim))
            }
            (result, _) => result,
        }
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
        Ok(zed::DebugAdapterBinary {
            command: Some(command),
            arguments: proxy_args::build_proxy_args(&cfg, &cwd, install::PROXY_VERSION),
            envs: proxy_args::merge_env(&worktree.shell_env(), &cfg.env, host_os() == Os::Windows),
            cwd: Some(cwd),
            connection: None,
            request_args: zed::StartDebuggingRequestArguments {
                configuration: config.config,
                request: to_request_kind(cfg.request),
            },
        })
    }

    fn dap_request_kind(
        &mut self,
        _adapter_name: String,
        config: zed::serde_json::Value,
    ) -> Result<zed::StartDebuggingRequestArgumentsRequest> {
        proxy_args::request_kind(&config).map(to_request_kind)
    }

    fn dap_config_to_scenario(&mut self, config: zed::DebugConfig) -> Result<zed::DebugScenario> {
        let spec = match &config.request {
            zed::DebugRequest::Launch(l) => proxy_args::config_to_scenario(
                &config.label,
                Some(LaunchSpec {
                    program: &l.program,
                    cwd: l.cwd.as_deref(),
                    args: &l.args,
                    envs: &l.envs,
                }),
                config.stop_on_entry,
            ),
            zed::DebugRequest::Attach(_) => {
                proxy_args::config_to_scenario(&config.label, None, config.stop_on_entry)
            }
        };
        Ok(zed::DebugScenario {
            label: spec.label,
            adapter: spec.adapter,
            build: None,
            config: spec.config.to_string(),
            tcp_connection: None,
        })
    }
}

zed::register_extension!(FlutterRunExtension);

#[cfg(test)]
mod tests {
    #[test]
    fn schema_is_valid_json_with_adapter_enum() {
        let schema: serde_json::Value =
            serde_json::from_str(include_str!("../debug_adapter_schemas/FlutterRun.json")).unwrap();
        assert_eq!(schema["$schema"], "http://json-schema.org/draft-07/schema#");
        assert_eq!(schema["properties"]["adapter"]["enum"][0], "FlutterRun");
        assert_eq!(schema["additionalProperties"], true);
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
