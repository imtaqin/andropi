import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// Talks to the pi agent host (agent/src/host.ts) running as a Node child
/// process. Commands and records are JSONL; see the host for the protocol.
class AgentClient {
  AgentClient() {
    _events.receiveBroadcastStream().listen(_onPlatformEvent);
  }

  static const _method = MethodChannel('andropi/agent');
  static const _events = EventChannel('andropi/agent/events');

  final _records = StreamController<Map<String, dynamic>>.broadcast();
  final _pending = <int, Completer<dynamic>>{};
  final _stderr = <String>[];
  Completer<void>? _ready;
  int _nextId = 1;

  /// Every record the host writes that is not a command response.
  Stream<Map<String, dynamic>> get records => _records.stream;

  /// Recent stderr output, useful when the host fails to start.
  List<String> get stderrTail => List.unmodifiable(_stderr);

  Map<String, String> paths = const {};

  Future<void> start() async {
    _ready = Completer<void>();
    final result = await _method.invokeMethod<Map>('start');
    paths = result?.cast<String, String>() ?? const {};
    return _ready!.future.timeout(const Duration(seconds: 60));
  }

  Future<void> stop() => _method.invokeMethod('stop');

  Future<void> restart() async {
    await stop();
    while (await _method.invokeMethod<bool>('isRunning') == true) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await start();
  }

  Future<void> setBusy(bool busy) => _method.invokeMethod('setBusy', busy);

  Future<void> openUrl(String url) => _method.invokeMethod('openUrl', url);

  /// Whether the app may read and write shared storage, and where it is.
  Future<({bool granted, String root})> storageAccess() async {
    final m = (await _method.invokeMethod<Map>('storageAccess'))!;
    return (granted: m['granted'] == true, root: m['root'] as String);
  }

  /// Keeps the app alive in the background (queued runs, schedules).
  Future<void> keepAlive(bool on, {String? text}) => _method.invokeMethod('keepAlive', {'on': on, 'text': text});

  /// System speech recognizer; null when cancelled.
  Future<String?> listen({String? language}) => _method.invokeMethod<String>('listen', {'language': language});

  /// Why the app was opened (share from another app, widget, tile), once.
  Future<Map<String, dynamic>?> takeLaunch() async =>
      (await _method.invokeMethod<Map>('takeLaunch'))?.cast<String, dynamic>();

  Future<void> notify(int id, String title, String body) =>
      _method.invokeMethod('notify', {'id': id, 'title': title, 'body': body});

  Future<void> requestNotifications() => _method.invokeMethod('requestNotifications');

  /// Opens the Android share sheet for a file.
  Future<void> shareFile(String path) => _method.invokeMethod('shareFile', {'path': path});

  /// Copies a file into the phone's Download/AndroPI folder; returns where it landed.
  Future<String> saveToDownloads(String path) async =>
      (await _method.invokeMethod<String>('saveToDownloads', {'path': path}))!;

  /// Opens the system page where the user grants "All files access".
  Future<void> requestStorageAccess() => _method.invokeMethod('requestStorageAccess');

  /// The environment the agent runs with (PATH, HOME, git/ssh setup).
  Future<Map<String, String>> environment() async =>
      (await _method.invokeMethod<Map>('environment'))!.cast<String, String>();

  /// Sends a command and resolves with its `data`, or throws [AgentError].
  Future<T> call<T>(String type, [Map<String, dynamic> args = const {}]) {
    final id = _nextId++;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    _method.invokeMethod('send', jsonEncode({'id': id, 'type': type, ...args}));
    return completer.future.then((v) => v as T);
  }

  void _onPlatformEvent(dynamic raw) {
    final event = (raw as Map).cast<String, dynamic>();
    switch (event['kind']) {
      case 'stdout':
        _onLine(event['line'] as String);
      case 'stderr':
        _stderr.add(event['line'] as String);
        if (_stderr.length > 200) _stderr.removeAt(0);
      case 'exit':
        final error = AgentError('Agent exited with code ${event['code']}');
        for (final c in _pending.values) {
          c.completeError(error);
        }
        _pending.clear();
        if (_ready?.isCompleted == false) _ready!.completeError(error);
        _records.add({'type': 'exit', 'code': event['code']});
      // A share, widget or tile opened the app; details come from takeLaunch().
      case 'launch':
        _records.add({'type': 'launch'});
    }
  }

  void _onLine(String line) {
    final Map<String, dynamic> record;
    try {
      record = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (record['type']) {
      case 'response':
        final completer = _pending.remove(record['id']);
        if (completer == null) return;
        if (record['ok'] == true) {
          completer.complete(record['data']);
        } else {
          completer.completeError(AgentError(record['error'] as String? ?? 'Unknown error'));
        }
      case 'ready':
        _ready?.complete();
        _records.add(record);
      case 'fatal':
        final error = AgentError(record['message'] as String? ?? 'Agent failed');
        if (_ready?.isCompleted == false) _ready!.completeError(error);
        _records.add(record);
      default:
        _records.add(record);
    }
  }
}

class AgentError implements Exception {
  AgentError(this.message);
  final String message;
  @override
  String toString() => message;
}
