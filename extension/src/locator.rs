//! Debug locator: turns a Zed task such as `flutter run -d linux` into a `FlutterRun` scenario.
//!
//! Matching is deliberately narrow. Anything that is not clearly "run a Flutter app" or
//! "run a Dart file" returns `None`, so tasks like `flutter build`, `flutter test` or
//! `dart pub get` never get a debug entry. See ADR 0009.

use serde_json::{Map, Value, json};

/// Name in `[debug_locators.FlutterRun]` of `extension.toml`.
pub const LOCATOR_NAME: &str = "FlutterRun";
/// Zed passes the adapter of the active buffer's language; only ours is served.
pub const ADAPTER_NAME: &str = "FlutterRun";

/// The parts of Zed's `TaskTemplate` that the locator looks at.
pub struct TaskInput<'a> {
    pub command: &'a str,
    pub args: &'a [String],
    pub env: &'a [(String, String)],
    pub cwd: Option<&'a str>,
}

/// Returns the JSON configuration for the scenario, or `None` when the task is not ours.
pub fn scenario_config(task: &TaskInput) -> Option<Value> {
    let tokens = tokens(task)?;
    let (head, rest) = tokens.split_first()?;
    let mut parsed = match program_name(head).as_str() {
        "flutter" => parse_flutter_run(rest)?,
        "fvm" | "puro" => {
            let (flutter, rest) = rest.split_first()?;
            if program_name(flutter) != "flutter" {
                return None;
            }
            let mut parsed = parse_flutter_run(rest)?;
            parsed.use_fvm = program_name(head) == "fvm";
            parsed
        }
        "dart" => parse_dart(rest)?,
        _ => return None,
    };
    parsed.cwd = task.cwd.map(str::to_string);
    parsed.env = task.env.to_vec();
    Some(parsed.into_config())
}

/// Command and args as one token list. A command that holds spaces (`flutter run`) is split
/// on whitespace only when there are no separate args and no quotes; otherwise it is not ours.
fn tokens(task: &TaskInput) -> Option<Vec<String>> {
    let command = task.command.trim();
    if command.is_empty() {
        return None;
    }
    if !command.contains(char::is_whitespace) {
        let mut all = vec![command.to_string()];
        all.extend(task.args.iter().cloned());
        return Some(all);
    }
    if !task.args.is_empty() || command.contains(['"', '\'', '\\']) {
        return None;
    }
    Some(command.split_whitespace().map(str::to_string).collect())
}

/// Lower-case file name without directory and without `.exe`/`.bat`/`.cmd`.
fn program_name(command: &str) -> String {
    let base = command.rsplit(['/', '\\']).next().unwrap_or(command);
    let lower = base.to_ascii_lowercase();
    for ext in [".exe", ".bat", ".cmd"] {
        if let Some(stem) = lower.strip_suffix(ext) {
            return stem.to_string();
        }
    }
    lower
}

#[derive(Default)]
struct Parsed {
    dart: bool,
    program: Option<String>,
    device_id: Option<String>,
    mode: Option<&'static str>,
    tool_args: Vec<String>,
    args: Vec<String>,
    use_fvm: bool,
    cwd: Option<String>,
    env: Vec<(String, String)>,
}

impl Parsed {
    fn into_config(self) -> Value {
        let mut config = Map::new();
        config.insert("request".into(), json!("launch"));
        config.insert(
            "type".into(),
            json!(if self.dart { "dart" } else { "flutter" }),
        );
        if let Some(program) = self.program {
            config.insert("program".into(), json!(program));
        }
        if let Some(device) = self.device_id {
            config.insert("deviceId".into(), json!(device));
        }
        if let Some(mode) = self.mode {
            config.insert("flutterMode".into(), json!(mode));
        }
        if !self.tool_args.is_empty() {
            config.insert("toolArgs".into(), json!(self.tool_args));
        }
        if !self.args.is_empty() {
            config.insert("args".into(), json!(self.args));
        }
        if self.use_fvm {
            config.insert("useFvm".into(), json!(true));
        }
        if let Some(cwd) = self.cwd {
            config.insert("cwd".into(), json!(cwd));
        }
        if !self.env.is_empty() {
            let env: Map<String, Value> = self
                .env
                .into_iter()
                .map(|(k, v)| (k, Value::String(v)))
                .collect();
            config.insert("env".into(), Value::Object(env));
        }
        Value::Object(config)
    }
}

/// Arguments after `flutter`. The first one must be `run`.
fn parse_flutter_run(rest: &[String]) -> Option<Parsed> {
    let (sub, rest) = rest.split_first()?;
    if sub != "run" {
        return None;
    }
    let mut out = Parsed::default();
    let mut it = rest.iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--" => {
                out.args.extend(it.by_ref().cloned());
            }
            // `--machine` takes over stdout for its own protocol; the debug adapter cannot share it.
            "--machine" => return None,
            "-d" | "--device-id" => out.device_id = Some(non_empty(it.next()?)?),
            "-t" | "--target" => out.program = Some(non_empty(it.next()?)?),
            "--profile" => out.mode = Some("profile"),
            "--release" => out.mode = Some("release"),
            "--debug" => out.mode = Some("debug"),
            other => {
                if let Some(value) = other.strip_prefix("--device-id=") {
                    out.device_id = Some(non_empty(value)?);
                } else if let Some(value) = other.strip_prefix("--target=") {
                    out.program = Some(non_empty(value)?);
                } else if let Some(value) = short_value(other, 'd') {
                    out.device_id = Some(non_empty(value)?);
                } else if let Some(value) = short_value(other, 't') {
                    out.program = Some(non_empty(value)?);
                } else {
                    out.tool_args.push(other.to_string());
                }
            }
        }
    }
    Some(out)
}

/// `-dlinux` style: a single dash, the letter, then the value.
fn short_value(arg: &str, letter: char) -> Option<&str> {
    let rest = arg.strip_prefix('-')?;
    if rest.starts_with('-') {
        return None;
    }
    rest.strip_prefix(letter).filter(|v| !v.is_empty())
}

fn non_empty(value: &str) -> Option<String> {
    let value = value.trim();
    (!value.is_empty()).then(|| value.to_string())
}

fn is_dart_file(arg: &str) -> bool {
    arg.to_ascii_lowercase().ends_with(".dart")
}

/// Arguments after `dart`: `run <file.dart> [args]` or `<file.dart> [args]`.
/// Flags before the file go to `toolArgs`; everything after the file is the program's own.
fn parse_dart(rest: &[String]) -> Option<Parsed> {
    let rest = match rest.first().map(String::as_str) {
        Some("run") => &rest[1..],
        _ => rest,
    };
    let mut out = Parsed {
        dart: true,
        ..Parsed::default()
    };
    let mut it = rest.iter();
    for arg in it.by_ref() {
        if arg.starts_with('-') {
            out.tool_args.push(arg.clone());
        } else if is_dart_file(arg) {
            out.program = Some(arg.clone());
            out.args.extend(it.by_ref().cloned());
            return Some(out);
        } else {
            // `dart run build_runner`, `dart test`, `dart pub get`, ...
            return None;
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(command: &str, args: &[&str]) -> Option<Value> {
        run_with(command, args, &[], None)
    }

    fn run_with(
        command: &str,
        args: &[&str],
        env: &[(&str, &str)],
        cwd: Option<&str>,
    ) -> Option<Value> {
        let args: Vec<String> = args.iter().map(ToString::to_string).collect();
        let env: Vec<(String, String)> = env
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        scenario_config(&TaskInput {
            command,
            args: &args,
            env: &env,
            cwd,
        })
    }

    #[test]
    fn plain_flutter_run() {
        assert_eq!(
            run("flutter", &["run"]),
            Some(json!({"request":"launch","type":"flutter"}))
        );
    }

    #[test]
    fn device_forms() {
        for args in [
            vec!["run", "-d", "linux"],
            vec!["run", "--device-id", "linux"],
            vec!["run", "--device-id=linux"],
            vec!["run", "-dlinux"],
        ] {
            let got = run("flutter", &args).unwrap();
            assert_eq!(got["deviceId"], "linux", "{args:?}");
            assert!(got.get("toolArgs").is_none(), "{args:?}");
        }
        // last one wins
        let got = run("flutter", &["run", "-d", "a", "-d", "b"]).unwrap();
        assert_eq!(got["deviceId"], "b");
    }

    #[test]
    fn target_forms() {
        for args in [
            vec!["run", "-t", "lib/main_dev.dart"],
            vec!["run", "--target", "lib/main_dev.dart"],
            vec!["run", "--target=lib/main_dev.dart"],
            vec!["run", "-tlib/main_dev.dart"],
        ] {
            let got = run("flutter", &args).unwrap();
            assert_eq!(got["program"], "lib/main_dev.dart", "{args:?}");
        }
    }

    #[test]
    fn mode_flags() {
        assert_eq!(
            run("flutter", &["run", "--profile"]).unwrap()["flutterMode"],
            "profile"
        );
        assert_eq!(
            run("flutter", &["run", "--release"]).unwrap()["flutterMode"],
            "release"
        );
        assert_eq!(
            run("flutter", &["run", "--debug"]).unwrap()["flutterMode"],
            "debug"
        );
        // no mode flag, no key
        assert!(
            run("flutter", &["run"])
                .unwrap()
                .get("flutterMode")
                .is_none()
        );
    }

    #[test]
    fn other_args_become_tool_args_in_order() {
        let got = run(
            "flutter",
            &[
                "run",
                "--flavor",
                "dev",
                "-d",
                "chrome",
                "--dart-define=A=1",
                "-v",
                "--release",
            ],
        )
        .unwrap();
        assert_eq!(
            got,
            json!({
                "request":"launch","type":"flutter","deviceId":"chrome","flutterMode":"release",
                "toolArgs":["--flavor","dev","--dart-define=A=1","-v"]
            })
        );
    }

    #[test]
    fn double_dash_args_go_to_the_app() {
        let got = run("flutter", &["run", "-d", "linux", "--", "--foo", "-d", "x"]).unwrap();
        assert_eq!(got["args"], json!(["--foo", "-d", "x"]));
        assert_eq!(got["deviceId"], "linux");
        assert!(got.get("toolArgs").is_none());
    }

    #[test]
    fn env_and_cwd_are_carried() {
        let got = run_with(
            "flutter",
            &["run"],
            &[("A", "1"), ("B", "two words")],
            Some("$ZED_WORKTREE_ROOT/app"),
        )
        .unwrap();
        assert_eq!(got["cwd"], "$ZED_WORKTREE_ROOT/app");
        assert_eq!(got["env"], json!({"A":"1","B":"two words"}));
        let bare = run("flutter", &["run"]).unwrap();
        assert!(bare.get("cwd").is_none() && bare.get("env").is_none());
    }

    #[test]
    fn fvm_and_puro_wrappers() {
        let fvm = run("fvm", &["flutter", "run", "-d", "macos"]).unwrap();
        assert_eq!(fvm["useFvm"], true);
        assert_eq!(fvm["deviceId"], "macos");
        assert_eq!(fvm["type"], "flutter");
        let puro = run("puro", &["flutter", "run"]).unwrap();
        assert!(puro.get("useFvm").is_none());
        assert_eq!(puro["type"], "flutter");
        assert_eq!(run("fvm", &["dart", "run", "x.dart"]), None);
        assert_eq!(run("fvm", &["flutter", "build", "apk"]), None);
        assert_eq!(run("fvm", &["use", "3.24"]), None);
        assert_eq!(run("fvm", &[]), None);
        assert_eq!(run("puro", &["ls"]), None);
    }

    #[test]
    fn command_spellings() {
        assert!(run("/opt/flutter/bin/flutter", &["run"]).is_some());
        assert!(run("C:\\flutter\\bin\\flutter.bat", &["run"]).is_some());
        assert!(run("Flutter.EXE", &["run"]).is_some());
        assert!(run("fvm.exe", &["flutter", "run"]).is_some());
        assert_eq!(run("flutterw", &["run"]), None);
        assert_eq!(run("my-flutter", &["run"]), None);
    }

    #[test]
    fn command_with_spaces_is_split_only_when_simple() {
        assert!(run("flutter run -d linux", &[]).is_some());
        assert_eq!(
            run("flutter run -d linux", &[]).unwrap()["deviceId"],
            "linux"
        );
        assert!(run("fvm flutter run", &[]).is_some());
        assert!(run("dart run bin/a.dart", &[]).is_some());
        // args present: the command is a path with spaces, not a command line
        assert_eq!(
            run("C:\\Program Files\\flutter\\bin\\flutter", &["run"]),
            None
        );
        assert_eq!(run("flutter run 'a b'", &[]), None);
        assert_eq!(run("", &["run"]), None);
        assert_eq!(run("   ", &[]), None);
    }

    #[test]
    fn non_run_flutter_tasks_are_not_matched() {
        for args in [
            vec![],
            vec!["build", "apk"],
            vec!["test"],
            vec!["pub", "get"],
            vec!["doctor"],
            vec!["--version"],
            vec!["attach"],
            vec!["Run"],
            vec!["-d", "linux", "run"],
            vec!["run", "--machine"],
            vec!["run", "-d"],
            vec!["run", "--device-id="],
            vec!["run", "-t"],
        ] {
            assert_eq!(run("flutter", &args), None, "{args:?}");
        }
    }

    #[test]
    fn dart_run_with_a_file() {
        let got = run("dart", &["run", "bin/main.dart"]).unwrap();
        assert_eq!(
            got,
            json!({"request":"launch","type":"dart","program":"bin/main.dart"})
        );
    }

    #[test]
    fn dart_file_without_run() {
        let got = run("dart", &["tool/gen.dart", "--out", "x"]).unwrap();
        assert_eq!(got["program"], "tool/gen.dart");
        assert_eq!(got["args"], json!(["--out", "x"]));
        assert_eq!(got["type"], "dart");
    }

    #[test]
    fn dart_flags_before_the_file_are_tool_args() {
        let got = run(
            "dart",
            &[
                "run",
                "--enable-asserts",
                "bin/main.dart",
                "--enable-asserts",
                "x",
            ],
        )
        .unwrap();
        assert_eq!(got["toolArgs"], json!(["--enable-asserts"]));
        assert_eq!(got["args"], json!(["--enable-asserts", "x"]));
        assert_eq!(got["program"], "bin/main.dart");
    }

    #[test]
    fn dart_carries_env_and_cwd() {
        let got = run_with("dart", &["run", "a.dart"], &[("K", "V")], Some("/p")).unwrap();
        assert_eq!(got["cwd"], "/p");
        assert_eq!(got["env"], json!({"K":"V"}));
        assert!(got.get("useFvm").is_none());
    }

    #[test]
    fn other_dart_tasks_are_not_matched() {
        for args in [
            vec![],
            vec!["run"],
            vec!["run", "build_runner", "build"],
            vec!["run", ":tool"],
            vec!["run", "--verbose"],
            vec!["test"],
            vec!["pub", "get"],
            vec!["format", "."],
            vec!["analyze"],
            vec!["compile", "exe", "bin/a.dart"],
            vec!["--version"],
        ] {
            assert_eq!(run("dart", &args), None, "{args:?}");
        }
    }

    #[test]
    fn unrelated_commands_are_not_matched() {
        assert_eq!(run("cargo", &["run"]), None);
        assert_eq!(run("npm", &["run", "dev"]), None);
        assert_eq!(run("python", &["main.py"]), None);
        assert_eq!(run("sh", &["-c", "flutter run"]), None);
    }

    #[test]
    fn output_is_accepted_by_the_extension_parser() {
        let got = run_with(
            "fvm",
            &[
                "flutter",
                "run",
                "--release",
                "-d",
                "linux",
                "--flavor",
                "x",
            ],
            &[("A", "1")],
            Some("/p"),
        )
        .unwrap();
        let cfg = crate::proxy_args::parse_config(&got.to_string()).unwrap();
        assert!(cfg.use_fvm);
        assert_eq!(cfg.cwd.as_deref(), Some("/p"));
        assert_eq!(cfg.request, crate::proxy_args::Request::Launch);
        let dart = run("dart", &["run", "bin/a.dart"]).unwrap();
        let cfg = crate::proxy_args::parse_config(&dart.to_string()).unwrap();
        assert_eq!(cfg.kind, crate::proxy_args::Kind::Dart);
    }

    #[test]
    fn names_match_the_manifest() {
        let toml = include_str!("../extension.toml");
        assert!(toml.contains(&format!("[debug_locators.{LOCATOR_NAME}]")));
        assert!(toml.contains(&format!("[debug_adapters.{ADAPTER_NAME}]")));
    }
}
