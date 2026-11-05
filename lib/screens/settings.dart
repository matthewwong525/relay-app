import 'package:flutter/material.dart';

import '../relay.dart';

/// Each switch acts at once and asks for its permission only when turned on.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.relay});

  final Relay relay;

  Future<void> _apply(BuildContext context, Future<String?> change) async {
    final problem = await change;
    if (problem != null && context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(problem)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: relay,
        builder: (context, _) {
          final settings = relay.settings;
          return ListView(children: [
            SwitchListTile(
              title: const Text('Pin notes to a place'),
              subtitle: const Text('Each typed note keeps where you were.'),
              value: settings.pinNotes,
              onChanged: (on) => _apply(context, relay.setPinNotes(on)),
            ),
            SwitchListTile(
              title: const Text('Location history'),
              subtitle: const Text('Keeps a point each 100 m you move, so ring notes get a place too.'),
              value: settings.history,
              onChanged: (on) => _apply(context, relay.setHistory(on)),
            ),
            SwitchListTile(
              title: const Text('Health'),
              subtitle: const Text('Sends steps, heart rate, sleep and workouts every hour.'),
              value: settings.health,
              onChanged: (on) => _apply(context, relay.setHealth(on)),
            ),
            const Divider(),
            ListTile(
              title: const Text('Server'),
              subtitle: Text(relay.server ?? 'Not connected'),
              trailing: const Icon(Icons.edit_outlined),
              onTap: relay.connected ? () => _editServer(context) : null,
            ),
            ListTile(
              title: const Text('Disconnect this phone'),
              subtitle: const Text('Removes the key from this phone. Notes not sent yet stay here.'),
              onTap: relay.connected ? () => _disconnect(context) : null,
            ),
          ]);
        },
      ),
    );
  }

  Future<void> _editServer(BuildContext context) async {
    final address = await showDialog<String>(context: context, builder: (context) => _ServerDialog(server: relay.server));
    if (address != null && context.mounted) await _apply(context, relay.setServer(address));
  }

  Future<void> _disconnect(BuildContext context) async {
    final sure = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Disconnect this phone?'),
      content: const Text('You need a new key to connect again.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Disconnect')),
      ],
    ));
    if (sure != true) return;
    await relay.disconnect();
    if (context.mounted) Navigator.of(context).popUntil((route) => route.isFirst);
  }
}

/// Owns its text field, so the field lives until the dialog's closing animation ends.
class _ServerDialog extends StatefulWidget {
  const _ServerDialog({required this.server});

  final String? server;

  @override
  State<_ServerDialog> createState() => _ServerDialogState();
}

class _ServerDialogState extends State<_ServerDialog> {
  late final _text = TextEditingController(text: widget.server);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Server'),
      content: TextField(controller: _text, keyboardType: TextInputType.url, autofocus: true,
        decoration: const InputDecoration(helperText: 'Use a preview address to try a change.')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(context, _text.text), child: const Text('Save')),
      ],
    );
  }
}
