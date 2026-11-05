// ignore_for_file: avoid_print
import 'package:flutter/material.dart';

const String kGreeting = 'Hello v1';

int bump(int x) {
  final y = x + 1; // BREAKPOINT_TARGET (line 7)
  return y;
}

void main() {
  print('GREETING: $kGreeting');
  print('BUMP: ${bump(1)}');
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    print('GREETING: $kGreeting');
    return const MaterialApp(home: CounterPage());
  }
}

class CounterPage extends StatefulWidget {
  const CounterPage({super.key});

  @override
  State<CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<CounterPage> {
  int _counter = 0;

  @override
  void reassemble() {
    super.reassemble();
    // Runs on every hot reload, so the breakpoint can be re-hit after reload.
    print('REASSEMBLE: ${bump(_counter)}');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(kGreeting)),
      body: Center(child: Text('Count: $_counter')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => setState(() => _counter = bump(_counter)),
        child: const Icon(Icons.add),
      ),
    );
  }
}
