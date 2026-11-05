//! Pure logic: parsing the scenario JSON, building the proxy argv/env, request kind, scenarios.

use serde_json::{Map, Value, json};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Flutter,
    Dart,
}

impl Kind {
    fn as_str(self) -> &'static str {
        match self {
            Kind::Flutter => "flutter",
            Kind::Dart => "dart",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Request {
    Launch,
    Attach,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProxyConfig {
    pub cwd: Option<String>,
    pub kind: Kind,
    pub flutter_sdk_path: Option<String>,
    pub use_fvm: bool,
    pub log_file: Option<String>,
    pub env: Vec<(String, String)>,
    pub request: Request,
}

fn non_empty_string(obj: &Map<String, Value>, key: &str) -> Option<String> {
    obj.get(key)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

fn parse_env(value: Option<&Value>) -> Result<Vec<(String, String)>, String> {
    let Some(value) = value else {
        return Ok(Vec::new());
    };
    let obj = match value {
        Value::Null => return Ok(Vec::new()),
        Value::Object(obj) => obj,
        _ => return Err("The \"env\" setting must be an object of names and values.".to_string()),
    };
    let mut out = Vec::with_capacity(obj.len());
    for (name, v) in obj {
        let text = match v {
            Value::String(s) => s.clone(),
            Value::Number(n) => n.to_string(),
            Value::Bool(b) => b.to_string(),
            Value::Null => continue,
            _ => {
                return Err(format!(
                    "The value of env \"{name}\" must be a string, number or boolean."
                ));
            }
        };
        out.push((name.clone(), text));
    }
    Ok(out)
}

/// `dap_request_kind`: `attach` -> Attach; `launch` or missing -> Launch; anything else is an error.
pub fn request_kind(config: &Value) -> Result<Request, String> {
    match config.get("request") {
        None | Some(Value::Null) => Ok(Request::Launch),
        Some(Value::String(s)) if s == "launch" => Ok(Request::Launch),
        Some(Value::String(s)) if s == "attach" => Ok(Request::Attach),
        Some(other) => Err(format!(
            "Unknown \"request\" value {other}. Use \"launch\" or \"attach\"."
        )),
    }
}

/// Parses the JSON string of the scenario (Zed substituted `$ZED_*` already).
pub fn parse_config(config_json: &str) -> Result<ProxyConfig, String> {
    let value: Value = serde_json::from_str(config_json)
        .map_err(|e| format!("The debug configuration is not valid JSON: {e}."))?;
    let obj = value
        .as_object()
        .ok_or_else(|| "The debug configuration must be a JSON object.".to_string())?;
    let kind = match obj.get("type") {
        None | Some(Value::Null) => Kind::Flutter,
        Some(Value::String(s)) if s.is_empty() || s == "flutter" => Kind::Flutter,
        Some(Value::String(s)) if s == "dart" => Kind::Dart,
        Some(other) => {
            return Err(format!(
                "Unknown \"type\" value {other}. Use \"flutter\" or \"dart\"."
            ));
        }
    };
    Ok(ProxyConfig {
        cwd: non_empty_string(obj, "cwd"),
        kind,
        flutter_sdk_path: non_empty_string(obj, "flutterSdkPath"),
        use_fvm: obj.get("useFvm").and_then(Value::as_bool) == Some(true),
        log_file: non_empty_string(obj, "logFile"),
        env: parse_env(obj.get("env"))?,
        request: request_kind(&value)?,
    })
}

/// Argv for the proxy; `cwd` is the resolved working directory (one argv element, spaces kept).
pub fn build_proxy_args(cfg: &ProxyConfig, cwd: &str, client_version: &str) -> Vec<String> {
    let mut args = vec![
        "dap".to_string(),
        "--cwd".to_string(),
        cwd.to_string(),
        "--kind".to_string(),
        cfg.kind.as_str().to_string(),
        "--request".to_string(),
        match cfg.request {
            Request::Launch => "launch".to_string(),
            Request::Attach => "attach".to_string(),
        },
    ];
    if let Some(sdk) = &cfg.flutter_sdk_path {
        args.push("--flutter-sdk".to_string());
        args.push(sdk.clone());
    }
    if cfg.use_fvm {
        args.push("--use-fvm".to_string());
    }
    if let Some(log) = &cfg.log_file {
        args.push("--log-file".to_string());
        args.push(log.clone());
    }
    args.push("--client-version".to_string());
    args.push(client_version.to_string());
    args
}

/// Shell env first, config env on top (config wins on identical keys).
/// With `case_insensitive` (Windows) keys that differ only in ASCII case are the same variable.
pub fn merge_env(
    shell_env: &[(String, String)],
    config_env: &[(String, String)],
    case_insensitive: bool,
) -> Vec<(String, String)> {
    let same = |a: &str, b: &str| {
        if case_insensitive {
            a.eq_ignore_ascii_case(b)
        } else {
            a == b
        }
    };
    let mut out: Vec<(String, String)> = Vec::with_capacity(shell_env.len() + config_env.len());
    for (k, v) in shell_env.iter().chain(config_env.iter()) {
        match out.iter_mut().find(|(ek, _)| same(ek, k)) {
            Some(existing) => *existing = (k.clone(), v.clone()),
            None => out.push((k.clone(), v.clone())),
        }
    }
    out
}

fn is_absolute(path: &str) -> bool {
    let b = path.as_bytes();
    path.starts_with('/')
        || path.starts_with("\\\\")
        || (b.len() >= 3
            && b[0].is_ascii_alphabetic()
            && b[1] == b':'
            && (b[2] == b'\\' || b[2] == b'/'))
}

/// Resolves the working directory: a relative `cwd` is joined onto the worktree root
/// (Zed would otherwise resolve it against its own process directory).
pub fn resolve_cwd(cwd: Option<&str>, root: &str) -> String {
    let Some(cwd) = cwd.filter(|c| !c.is_empty()) else {
        return root.to_string();
    };
    if is_absolute(cwd) {
        return cwd.to_string();
    }
    let rel = cwd.trim_start_matches("./").trim_start_matches(".\\");
    if rel.is_empty() || rel == "." {
        return root.to_string();
    }
    let sep = if root.contains('\\') && !root.contains('/') {
        '\\'
    } else {
        '/'
    };
    format!("{}{sep}{rel}", root.trim_end_matches(['/', '\\']))
}

#[derive(Clone, Debug, PartialEq)]
pub struct ScenarioSpec {
    pub label: String,
    pub adapter: String,
    pub config: Value,
}

pub struct LaunchSpec<'a> {
    pub program: &'a str,
    pub cwd: Option<&'a str>,
    pub args: &'a [String],
    pub envs: &'a [(String, String)],
}

/// `dap_config_to_scenario`: `Some(launch)` for a launch request, `None` for attach.
pub fn config_to_scenario(
    label: &str,
    launch: Option<LaunchSpec>,
    stop_on_entry: Option<bool>,
) -> ScenarioSpec {
    let mut config = Map::new();
    match launch {
        Some(l) => {
            config.insert("request".into(), json!("launch"));
            config.insert("type".into(), json!("flutter"));
            config.insert("program".into(), json!(l.program));
            if let Some(cwd) = l.cwd {
                config.insert("cwd".into(), json!(cwd));
            }
            config.insert("args".into(), json!(l.args));
            let env: Map<String, Value> = l
                .envs
                .iter()
                .map(|(k, v)| (k.clone(), Value::String(v.clone())))
                .collect();
            config.insert("env".into(), Value::Object(env));
        }
        None => {
            config.insert("request".into(), json!("attach"));
            config.insert("type".into(), json!("flutter"));
        }
    }
    if let Some(stop) = stop_on_entry {
        config.insert("stopOnEntry".into(), json!(stop));
    }
    ScenarioSpec {
        label: label.to_string(),
        adapter: "FlutterRun".to_string(),
        config: Value::Object(config),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kv(k: &str, v: &str) -> (String, String) {
        (k.to_string(), v.to_string())
    }

    #[test]
    fn defaults() {
        let c = parse_config("{}").unwrap();
        assert_eq!(c.kind, Kind::Flutter);
        assert_eq!(c.cwd, None);
        assert_eq!(c.request, Request::Launch);
        assert!(!c.use_fvm);
        assert!(c.env.is_empty());
        let c = parse_config(r#"{"type":""}"#).unwrap();
        assert_eq!(c.kind, Kind::Flutter);
    }

    #[test]
    fn full_parse() {
        let c = parse_config(
            r#"{"type":"dart","cwd":"/a b","flutterSdkPath":"/sdk","useFvm":true,"logFile":"/l.txt",
                "request":"attach","env":{"A":"1","N":2,"B":true,"Z":null}}"#,
        )
        .unwrap();
        assert_eq!(c.kind, Kind::Dart);
        assert_eq!(c.cwd.as_deref(), Some("/a b"));
        assert_eq!(c.flutter_sdk_path.as_deref(), Some("/sdk"));
        assert!(c.use_fvm);
        assert_eq!(c.log_file.as_deref(), Some("/l.txt"));
        assert_eq!(c.request, Request::Attach);
        let mut env = c.env.clone();
        env.sort();
        assert_eq!(env, vec![kv("A", "1"), kv("B", "true"), kv("N", "2")]);
    }

    #[test]
    fn empty_strings_are_absent() {
        let c = parse_config(r#"{"flutterSdkPath":"","logFile":"","cwd":""}"#).unwrap();
        assert_eq!(c.flutter_sdk_path, None);
        assert_eq!(c.log_file, None);
        assert_eq!(c.cwd, None);
    }

    #[test]
    fn errors() {
        assert!(parse_config("not json").is_err());
        assert!(parse_config("[]").is_err());
        assert!(parse_config(r#"{"type":"web"}"#).is_err());
        assert!(parse_config(r#"{"type":5}"#).is_err());
        assert!(parse_config(r#"{"env":["a"]}"#).is_err());
        assert!(parse_config(r#"{"env":{"A":{"x":1}}}"#).is_err());
        assert!(parse_config(r#"{"env":{"A":[1]}}"#).is_err());
        assert!(parse_config(r#"{"request":"debug"}"#).is_err());
    }

    #[test]
    fn request_kinds() {
        assert_eq!(
            request_kind(&json!({"request":"launch"})),
            Ok(Request::Launch)
        );
        assert_eq!(
            request_kind(&json!({"request":"attach"})),
            Ok(Request::Attach)
        );
        assert_eq!(request_kind(&json!({})), Ok(Request::Launch));
        assert!(request_kind(&json!({"request":"bogus"})).is_err());
        assert!(request_kind(&json!({"request":3})).is_err());
    }

    #[test]
    fn argv_minimal_and_full() {
        let c = parse_config("{}").unwrap();
        assert_eq!(
            build_proxy_args(&c, "/proj", "0.1.0"),
            [
                "dap",
                "--cwd",
                "/proj",
                "--kind",
                "flutter",
                "--request",
                "launch",
                "--client-version",
                "0.1.0"
            ]
        );
        let c = parse_config(
            r#"{"type":"dart","flutterSdkPath":"/my sdk","useFvm":true,"logFile":"/tmp/l g"}"#,
        )
        .unwrap();
        assert_eq!(
            build_proxy_args(&c, "/my proj", "0.1.0"),
            [
                "dap",
                "--cwd",
                "/my proj",
                "--kind",
                "dart",
                "--request",
                "launch",
                "--flutter-sdk",
                "/my sdk",
                "--use-fvm",
                "--log-file",
                "/tmp/l g",
                "--client-version",
                "0.1.0"
            ]
        );
    }

    #[test]
    fn argv_request_attach() {
        let c = parse_config(r#"{"request":"attach"}"#).unwrap();
        let a = build_proxy_args(&c, "/p", "0.1.0");
        let i = a.iter().position(|x| x == "--request").unwrap();
        assert_eq!(a[i + 1], "attach");
    }

    #[test]
    fn argv_use_fvm_false_omitted() {
        let c = parse_config(r#"{"useFvm":false}"#).unwrap();
        assert!(!build_proxy_args(&c, "/p", "1").contains(&"--use-fvm".to_string()));
    }

    #[test]
    fn env_merge_config_wins() {
        let merged = merge_env(
            &[kv("PATH", "/bin"), kv("HOME", "/h")],
            &[kv("HOME", "/other"), kv("X", "1")],
            false,
        );
        assert_eq!(
            merged,
            vec![kv("PATH", "/bin"), kv("HOME", "/other"), kv("X", "1")]
        );
        assert!(merge_env(&[], &[], false).is_empty());
        // case differs: distinct on POSIX, same variable on Windows
        assert_eq!(
            merge_env(&[kv("PATH", "a")], &[kv("Path", "b")], false).len(),
            2
        );
        assert_eq!(
            merge_env(&[kv("PATH", "a")], &[kv("Path", "b")], true),
            vec![kv("Path", "b")]
        );
    }

    #[test]
    fn scenario_launch() {
        let args = vec!["--a".to_string()];
        let envs = vec![kv("K", "V")];
        let s = config_to_scenario(
            "L",
            Some(LaunchSpec {
                program: "lib/main.dart",
                cwd: Some("/p"),
                args: &args,
                envs: &envs,
            }),
            Some(true),
        );
        assert_eq!(s.adapter, "FlutterRun");
        assert_eq!(s.label, "L");
        assert_eq!(
            s.config,
            json!({"request":"launch","type":"flutter","program":"lib/main.dart","cwd":"/p",
                   "args":["--a"],"env":{"K":"V"},"stopOnEntry":true})
        );
    }

    #[test]
    fn scenario_launch_without_cwd_or_stop() {
        let s = config_to_scenario(
            "L",
            Some(LaunchSpec {
                program: "p",
                cwd: None,
                args: &[],
                envs: &[],
            }),
            None,
        );
        assert_eq!(
            s.config,
            json!({"request":"launch","type":"flutter","program":"p","args":[],"env":{}})
        );
    }

    #[test]
    fn scenario_attach() {
        let s = config_to_scenario("A", None, Some(false));
        assert_eq!(
            s.config,
            json!({"request":"attach","type":"flutter","stopOnEntry":false})
        );
        assert_eq!(
            config_to_scenario("A", None, None).config,
            json!({"request":"attach","type":"flutter"})
        );
    }

    #[test]
    fn cwd_resolution() {
        assert_eq!(resolve_cwd(None, "/w"), "/w");
        assert_eq!(resolve_cwd(Some("."), "/w"), "/w");
        assert_eq!(resolve_cwd(Some("sub"), "/w"), "/w/sub");
        assert_eq!(resolve_cwd(Some("./sub/x"), "/w/"), "/w/sub/x");
        assert_eq!(resolve_cwd(Some("/abs"), "/w"), "/abs");
        assert_eq!(resolve_cwd(Some("C:\\abs"), "/w"), "C:\\abs");
        assert_eq!(resolve_cwd(Some("\\\\srv\\share"), "/w"), "\\\\srv\\share");
        assert_eq!(resolve_cwd(Some("sub"), "C:\\w"), "C:\\w\\sub");
    }
}
