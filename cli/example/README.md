# flutter_run example

`flutter_run` is a command-line tool, not a library. This is how you use it.

Install it:

```sh
dart pub global activate flutter_run
```

Set up a Flutter project for Zed:

```sh
cd my_flutter_app
flutter_run doctor      # shows the Flutter SDK, PATH and .zed files it sees
flutter_run init        # writes .zed/debug.json and .zed/tasks.json
```

In Zed, press F4 and pick **Flutter: Debug**. While the app runs:

```sh
flutter_run reload      # hot reload
flutter_run restart     # hot restart
flutter_run devices     # list devices
flutter_run devtools    # open DevTools
```

The generated `.zed/debug.json` entry looks like this:

```json
{
  "label": "Flutter: Debug",
  "adapter": "FlutterRun",
  "request": "launch",
  "type": "flutter",
  "program": "lib/main.dart",
  "cwd": "$ZED_WORKTREE_ROOT",
  "reloadOnSave": "changed"
}
```

All keys and commands are in the [configuration reference](https://github.com/sawongam/zed-flutter-run/blob/prod/docs/CONFIGURATION.md).
