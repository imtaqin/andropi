import 'dart:async';

import 'package:flutter/foundation.dart';

import 'agent_client.dart';
import 'features.dart';
import 'integrations.dart';
import 'models.dart';

enum BootStatus { starting, ready, failed }

/// App-wide agent state: boot, the active session's transcript rebuilt from
/// pi's event stream, and model/provider selection.
class AgentController extends ChangeNotifier {
  AgentController(this.client) {
    client.records.listen(_onRecord);
  }

  final AgentClient client;
  late final integrations = Integrations(client);
  late final features = Features(client);

  BootStatus status = BootStatus.starting;
  String? bootError;
  Map<String, dynamic> info = const {};

  // Session state
  ModelInfo? model;
  String thinkingLevel = 'off';
  List<String> thinkingLevels = const ['off'];
  String? sessionId;
  String? sessionName;
  String? sessionFile;
  String cwd = '';
  bool busy = false;

  /// Set when the current model is billed differently than the user may expect.
  String? billingNotice;

  /// Plan mode: the agent plans first and changes nothing until approved.
  bool planMode = false;
  String approvalMode = 'ask_risky';

  final entries = <ChatEntry>[];
  final tools = <String, ToolRun>{};

  List<ProviderInfo> providers = const [];
  List<ModelInfo> models = const [];

  /// Login prompts and notices from pi's auth flow, handled by the UI.
  final authRecords = StreamController<Map<String, dynamic>>.broadcast();

  AssistantEntry? _streaming;
  Timer? _notifyTimer;

  bool get hasModel => model != null;

  // -------------------------------------------------------------------------
  // Lifecycle

  Future<void> boot() async {
    status = BootStatus.starting;
    bootError = null;
    notifyListeners();
    try {
      await client.start();
      info = await client.call<Map<String, dynamic>>('hello');
      _applyState(info);
      await Future.wait([loadHistory(), refreshProviders()]);
      unawaited(integrations.refresh().then((_) => integrations.refreshProjects()).catchError((_) {}));
      status = BootStatus.ready;
    } catch (e) {
      status = BootStatus.failed;
      final tail = client.stderrTail;
      bootError = [
        e.toString(),
        if (tail.isNotEmpty) tail.skip(tail.length > 20 ? tail.length - 20 : 0).join('\n'),
      ].join('\n\n');
    }
    notifyListeners();
  }

  Future<void> restart() async {
    status = BootStatus.starting;
    notifyListeners();
    await client.stop();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await boot();
  }

  // -------------------------------------------------------------------------
  // Conversation

  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    try {
      await client.call('prompt', {'text': trimmed});
    } on AgentError catch (e) {
      _addNotice(e.message, error: true);
    }
  }

  Future<void> abort() => client.call('abort');

  /// Starts a session, in [dir] when given (a project folder), else the workspace.
  Future<void> newSession({String? dir}) async {
    _applyState(await client.call<Map<String, dynamic>>('new_session', {'cwd': ?dir}));
    _resetTranscript();
    notifyListeners();
  }

  Future<void> openSession(String path) async {
    _applyState(await client.call<Map<String, dynamic>>('open_session', {'path': path}));
    await loadHistory();
  }

  Future<void> renameSession(String path, String name) async {
    await client.call('rename_session', {'path': path, 'name': name});
    if (path == sessionFile) sessionName = name;
    notifyListeners();
  }

  Future<void> deleteSession(String path) => client.call('delete_session', {'path': path});

  Future<List<SessionSummary>> listSessions() async {
    final list = await client.call<List>('sessions');
    final out = list.map((e) => SessionSummary((e as Map).cast<String, dynamic>())).toList()
      ..sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }

  Future<void> loadHistory() async {
    final messages = await client.call<List>('messages');
    _resetTranscript();
    for (final m in messages.cast<Map>()) {
      _addMessage(m.cast<String, dynamic>(), fromHistory: true);
    }
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Models & providers

  Future<void> refreshProviders() async {
    final list = await client.call<List>('providers');
    providers = list.map((e) => ProviderInfo((e as Map).cast<String, dynamic>())).toList()
      ..sort((a, b) {
        if (a.configured != b.configured) return a.configured ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    final available = await client.call<List>('models');
    models = available.map((e) => ModelInfo((e as Map).cast<String, dynamic>())).toList();
    notifyListeners();
  }

  Future<void> setModel(ModelInfo m) async {
    _applyState(await client.call<Map<String, dynamic>>('set_model', {'provider': m.provider, 'model': m.id}));
    notifyListeners();
  }

  Future<void> setPlanMode(bool on) async {
    _applyState(await client.call<Map<String, dynamic>>('plan_mode', {'on': on}));
    notifyListeners();
  }

  /// Leaves plan mode and tells the agent to carry out its plan.
  Future<void> approvePlan([String? text]) async {
    _applyState(await client.call<Map<String, dynamic>>('plan_approve', {'text': ?text}));
    notifyListeners();
  }

  /// Sends with images (base64) attached; files are referenced by path in [text].
  Future<void> sendWith(String text, {List<Map<String, String>> images = const []}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty && images.isEmpty) return;
    try {
      await client.call('prompt', {'text': trimmed.isEmpty ? 'See the attached image.' : trimmed, 'images': images});
    } on AgentError catch (e) {
      _addNotice(e.message, error: true);
    }
  }

  /// Rewinds to just before a user message; returns its text for editing.
  Future<String> editMessage(String entryId) async {
    final r = await client.call<Map>('edit_message', {'entryId': entryId});
    await loadHistory();
    return r['text'] as String? ?? '';
  }

  /// Copies this chat into a new one, rewound to just before [entryId].
  Future<String> forkAt(String? entryId) async {
    final r = (await client.call<Map>('fork_session', {'entryId': ?entryId})).cast<String, dynamic>();
    _applyState(r);
    await loadHistory();
    return r['text'] as String? ?? '';
  }

  Future<void> setThinking(String level) async {
    _applyState(await client.call<Map<String, dynamic>>('set_thinking', {'level': level}));
    notifyListeners();
  }

  Future<void> login(String provider, String method) async {
    await client.call('login', {'provider': provider, 'method': method});
    await refreshProviders();
    if (model == null) {
      _applyState(await client.call<Map<String, dynamic>>('state'));
      if (model == null && models.isNotEmpty) await setModel(models.first);
    }
    notifyListeners();
  }

  void answerAuth(int authId, String? value) {
    client.call('auth_reply', {'authId': authId, 'value': value, 'cancel': value == null});
  }

  Future<void> logout(String provider) async {
    await client.call('logout', {'provider': provider});
    await refreshProviders();
    _applyState(await client.call<Map<String, dynamic>>('state'));
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Event handling

  void _onRecord(Map<String, dynamic> record) {
    switch (record['type']) {
      case 'event':
        _onEvent((record['event'] as Map).cast<String, dynamic>());
      case 'auth_prompt' || 'auth_event' || 'auth_dismiss':
        authRecords.add(record);
      case 'notice':
        // Startup hints ("no models") are covered by the empty state; the rest
        // (model fallback, triggers) are worth showing.
        final message = record['message'] as String? ?? '';
        if (!message.startsWith('No models available')) _addNotice(message);
      // The host changed session state on its own (e.g. a fallback model).
      case 'state':
        _applyState((record['state'] as Map).cast<String, dynamic>());
        notifyListeners();
      case 'error':
        _addNotice(readableError(record['message'] as String? ?? 'Error'), error: true);
      case 'exit':
        if (status == BootStatus.ready) {
          status = BootStatus.failed;
          bootError = 'The agent process stopped (code ${record['code']}).\n\n${client.stderrTail.join('\n')}';
          _setBusy(false);
          notifyListeners();
        }
    }
  }

  void _onEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'agent_start':
        _setBusy(true);
      case 'agent_settled':
        _setBusy(false);
        _streaming = null;
        _refreshStateQuietly();
      case 'message_start':
        _addMessage((e['message'] as Map).cast<String, dynamic>());
      case 'message_update':
        _applyDelta((e['assistantMessageEvent'] as Map).cast<String, dynamic>());
      case 'message_end':
        final message = (e['message'] as Map).cast<String, dynamic>();
        if (message['role'] == 'assistant') {
          (_streaming ?? _lastAssistant())?.applyMessage(message);
          _streaming = null;
        }
      case 'tool_execution_start':
        tools[e['toolCallId'] as String] = ToolRun(e['toolCallId'] as String);
      case 'tool_execution_update':
        final run = tools.putIfAbsent(e['toolCallId'] as String, () => ToolRun(e['toolCallId'] as String));
        run.output = contentText((e['partialResult'] as Map?)?['content']);
      case 'tool_execution_end':
        final run = tools.putIfAbsent(e['toolCallId'] as String, () => ToolRun(e['toolCallId'] as String));
        run.output = contentText((e['result'] as Map?)?['content']);
        run.status = e['isError'] == true ? ToolStatus.failed : ToolStatus.done;
      case 'compaction_start':
        _addNotice('Compacting context…');
      case 'session_info_changed':
        sessionName = e['name'] as String?;
      case 'thinking_level_changed':
        thinkingLevel = e['level'] as String? ?? thinkingLevel;
      default:
        return;
    }
    _scheduleNotify();
  }

  void _addMessage(Map<String, dynamic> m, {bool fromHistory = false}) {
    switch (m['role']) {
      case 'user':
        entries.add(UserEntry(contentText(m['content']), images: contentImages(m['content'])));
      case 'assistant':
        final entry = AssistantEntry();
        if (fromHistory || (m['content'] as List?)?.isNotEmpty == true) entry.applyMessage(m);
        entry.streaming = !fromHistory;
        entries.add(entry);
        if (!fromHistory) _streaming = entry;
      case 'toolResult':
        final run = tools.putIfAbsent(m['toolCallId'] as String, () => ToolRun(m['toolCallId'] as String));
        run.output = contentText(m['content']);
        run.status = m['isError'] == true ? ToolStatus.failed : ToolStatus.done;
      case 'bashExecution':
        entries.add(NoticeEntry('\$ ${m['command']}\n${m['output']}'));
      case 'compactionSummary':
        entries.add(NoticeEntry('Earlier messages were summarized to save context.'));
    }
  }

  void _applyDelta(Map<String, dynamic> d) {
    final entry = _streaming ??= _lastAssistant();
    if (entry == null) return;
    final index = d['contentIndex'] as int? ?? 0;
    switch (d['type']) {
      case 'text_start':
        entry.block(index, BlockKind.text);
      case 'text_delta':
        entry.block(index, BlockKind.text).buffer.write(d['delta'] ?? '');
      case 'text_end':
        entry.block(index, BlockKind.text).text = d['content'] as String? ?? '';
      case 'thinking_start':
        entry.block(index, BlockKind.thinking);
      case 'thinking_delta':
        entry.block(index, BlockKind.thinking).buffer.write(d['delta'] ?? '');
      case 'thinking_end':
        entry.block(index, BlockKind.thinking).text = d['content'] as String? ?? '';
      case 'toolcall_start':
        entry.block(index, BlockKind.toolCall)
          ..toolCallId = d['id'] as String?
          ..toolName = d['toolName'] as String?;
      case 'toolcall_delta':
        final block = entry.block(index, BlockKind.toolCall);
        block.toolCallId ??= d['id'] as String?;
        block.toolName ??= d['toolName'] as String?;
        block.buffer.write(d['delta'] ?? '');
      case 'toolcall_end':
        final call = (d['toolCall'] as Map?)?.cast<String, dynamic>();
        if (call != null) {
          entry.block(index, BlockKind.toolCall)
            ..toolCallId = call['id'] as String?
            ..toolName = call['name'] as String?
            ..args = (call['arguments'] as Map?)?.cast<String, dynamic>();
        }
    }
  }

  AssistantEntry? _lastAssistant() {
    for (final e in entries.reversed) {
      if (e is AssistantEntry) return e.streaming ? e : null;
    }
    return null;
  }

  void _addNotice(String text, {bool error = false}) {
    entries.add(NoticeEntry(text, error: error));
    notifyListeners();
  }

  void _resetTranscript() {
    entries.clear();
    tools.clear();
    _streaming = null;
  }

  void _setBusy(bool value) {
    if (busy == value) return;
    busy = value;
    client.setBusy(value);
  }

  void _applyState(Map<String, dynamic> s) {
    final m = s['model'];
    model = m == null ? null : ModelInfo((m as Map).cast<String, dynamic>());
    thinkingLevel = s['thinkingLevel'] as String? ?? 'off';
    thinkingLevels = (s['thinkingLevels'] as List? ?? const ['off']).cast<String>();
    sessionId = s['sessionId'] as String?;
    sessionName = s['sessionName'] as String?;
    sessionFile = s['sessionFile'] as String?;
    cwd = s['cwd'] as String? ?? cwd;
    billingNotice = s['billingNotice'] as String?;
    planMode = s['planMode'] == true;
    approvalMode = s['approvalMode'] as String? ?? approvalMode;
    if (s['isStreaming'] is bool) _setBusy(s['isStreaming'] as bool);
  }

  /// Re-reads session state after something outside the chat changed it (the shell).
  Future<void> refreshState() async {
    _applyState(await client.call<Map<String, dynamic>>('state'));
    notifyListeners();
  }

  Future<void> _refreshStateQuietly() async {
    try {
      _applyState(await client.call<Map<String, dynamic>>('state'));
      notifyListeners();
    } catch (_) {}
  }

  /// Coalesces streaming updates to roughly one rebuild per frame.
  void _scheduleNotify() {
    if (_notifyTimer?.isActive ?? false) return;
    _notifyTimer = Timer(const Duration(milliseconds: 32), notifyListeners);
  }

  @override
  void dispose() {
    _notifyTimer?.cancel();
    authRecords.close();
    super.dispose();
  }
}
