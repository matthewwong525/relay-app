import 'api.dart';
import 'store.dart';

/// What one send round did. [failure] is why it stopped early, or null when the outbox emptied.
class FlushResult {
  const FlushResult({this.sent = 0, this.dropped = 0, this.failure});

  final int sent;
  final int dropped;
  final Failure? failure;
}

/// Sends waiting uploads oldest first, and stops at the first that can not land now, so order holds.
/// A body the server turns down is dropped: it would never land, and would hold back the rest.
Future<FlushResult> flush(Store store, RelayApi api) async {
  var sent = 0, dropped = 0;
  for (final item in await store.outbox()) {
    try {
      await api.post(item.route, item.body);
      sent++;
    } on ApiException catch (error) {
      if (error.failure != Failure.rejected) return FlushResult(sent: sent, dropped: dropped, failure: error.failure);
      dropped++;
    }
    if (item.route == 'notes') await store.noteSent(item.body['clientId'] as String);
    await store.done(item.id);
  }
  return FlushResult(sent: sent, dropped: dropped);
}
