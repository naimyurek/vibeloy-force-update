import 'package:flutter/material.dart';

import 'force_update.dart'; // Symlink to ../../force_update.dart (lib/ cannot import above itself).

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Force update example',
      // ForceUpdateGate must sit below MaterialApp, because the dialogs need its Navigator.
      home: ForceUpdateGate(child: HomePage()),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Force update example')),
      body: Center(
        child: FilledButton(
          // Manual check. ForceUpdateGate already checks on launch and on every resume.
          onPressed: () => ForceUpdate.check(context),
          child: const Text('Check again'),
        ),
      ),
    );
  }
}
