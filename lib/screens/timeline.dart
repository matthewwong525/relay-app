import 'package:flutter/material.dart';

import '../relay.dart';
import 'compose.dart';
import 'settings.dart';

String _time(BuildContext context, DateTime at) {
  final now = DateTime.now();
  final time = TimeOfDay.fromDateTime(at).format(context);
  final today = at.year == now.year && at.month == now.month && at.day == now.day;
  return today ? time : '${MaterialLocalizations.of(context).formatShortMonthDay(at)}, $time';
}

/// Every note, newest first, with the one primary action: a new note.
class TimelineScreen extends StatelessWidget {
  const TimelineScreen({super.key, required this.relay});

  final Relay relay;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: relay,
      builder: (context, _) {
        final entries = relay.entries;
        return Scaffold(
          appBar: AppBar(title: const Text('Relay'), actions: [
            _SyncChip(relay: relay),
            IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SettingsScreen(relay: relay))),
            ),
          ]),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ComposeScreen(relay: relay))),
            icon: const Icon(Icons.edit_outlined),
            label: const Text('New note'),
          ),
          body: RefreshIndicator(
            onRefresh: relay.sync,
            child: entries.isEmpty
              ? ListView(children: const [Padding(padding: EdgeInsets.all(32),
                  child: Text('No notes yet. Hold the ring and talk, or tap New note.', textAlign: TextAlign.center))])
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                  itemCount: entries.length + (relay.hasMore ? 1 : 0),
                  itemBuilder: (context, index) => index == entries.length
                    ? Center(child: TextButton(onPressed: relay.more, child: const Text('Show older notes')))
                    : _NoteCard(entry: entries[index]),
                ),
          ),
        );
      },
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.entry});

  final Entry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final line = [_time(context, entry.at), entry.place, entry.device].whereType<String>().join(' · ');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 6, children: [
          Row(spacing: 8, children: [
            Chip(label: Text(entry.ring ? 'Ring' : 'Typed'), visualDensity: VisualDensity.compact),
            if (entry.waiting) Chip(avatar: const Icon(Icons.schedule, size: 16), label: const Text('Waiting'), visualDensity: VisualDensity.compact),
            if (entry.audio) const Icon(Icons.mic_none, size: 18, semanticLabel: 'Has a recording'),
          ]),
          Text(entry.text.isEmpty ? 'No words, only the recording.' : entry.text, style: theme.textTheme.bodyLarge),
          Text(line, style: muted),
        ]),
      ),
    );
  }
}

class _SyncChip extends StatelessWidget {
  const _SyncChip({required this.relay});

  final Relay relay;

  @override
  Widget build(BuildContext context) {
    final (icon, label) = switch (relay.status) {
      SyncStatus.syncing => (Icons.sync, 'Syncing'),
      SyncStatus.refused => (Icons.key_off_outlined, 'Key refused'),
      SyncStatus.offline => (Icons.cloud_off_outlined, relay.waiting > 0 ? '${relay.waiting} waiting' : 'Offline'),
      _ => (Icons.cloud_done_outlined, relay.waiting > 0 ? '${relay.waiting} waiting' : 'Synced'),
    };
    return ActionChip(avatar: Icon(icon, size: 18), label: Text(label), tooltip: 'Sync now', onPressed: relay.sync);
  }
}
