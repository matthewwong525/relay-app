import 'package:flutter/material.dart';

import '../relay.dart';

/// A new note: the keyboard opens at once, and Save keeps it even with no signal.
class ComposeScreen extends StatefulWidget {
  const ComposeScreen({super.key, required this.relay});

  final Relay relay;

  @override
  State<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends State<ComposeScreen> {
  final _text = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await widget.relay.addNote(_text.text);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New note'), actions: [
        ListenableBuilder(
          listenable: _text,
          builder: (context, _) => Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _saving || _text.text.trim().isEmpty ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Save'),
            ),
          ),
        ),
      ]),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: TextField(
          controller: _text,
          autofocus: true,
          maxLength: 20000,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'What do you want to keep?', border: InputBorder.none, counterText: ''),
        ),
      ),
    );
  }
}
