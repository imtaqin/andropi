import 'dart:async';

import 'package:flutter/foundation.dart';

import 'agent_client.dart';

class GithubAccount {
  GithubAccount(this.json);
  final Map<String, dynamic> json;

  String get login => json['login'] as String;
  String? get name => json['name'] as String?;
  String? get avatarUrl => json['avatarUrl'] as String?;
}

class SshHost {
  SshHost(this.json);
  final Map<String, dynamic> json;

  String get id => json['id'] as String;
  String get name => json['name'] as String;
  String get host => json['host'] as String;
  int get port => json['port'] as int? ?? 22;
  String get user => json['user'] as String;
  String? get path => json['path'] as String?;
  String get address => port == 22 ? '$user@$host' : '$user@$host:$port';
}

class RepoInfo {
  RepoInfo(this.json);
  final Map<String, dynamic> json;

  String get fullName => json['fullName'] as String;
  String get name => json['name'] as String;
  bool get isPrivate => json['private'] == true;
  String? get description => json['description'] as String?;
  String? get language => json['language'] as String?;
  int get stars => json['stars'] as int? ?? 0;
  DateTime? get pushedAt => DateTime.tryParse(json['pushedAt'] as String? ?? '');
  bool get cloned => json['cloned'] == true;
}

class ProjectInfo {
  ProjectInfo(this.json);
  final Map<String, dynamic> json;

  String get name => json['name'] as String;
  String get path => json['path'] as String;
  bool get isGit => json['git'] == true;
  String? get branch => json['branch'] as String?;
  String? get remote => json['remote'] as String?;
  bool get dirty => json['dirty'] == true;

  /// `owner/repo` when the origin is on GitHub.
  String? get githubSlug {
    final m = RegExp(r'github\.com[:/]([^/]+/[^/]+?)(?:\.git)?/?$').firstMatch(remote ?? '');
    return m?.group(1);
  }
}

class ContainerStatus {
  ContainerStatus(this.json);
  final Map<String, dynamic> json;

  bool get installed => json['installed'] == true;
  bool get enabled => json['enabled'] == true;
  String? get distro => json['distro'] as String?;
  String? get image => json['image'] as String?;
  List<(String, String)> get distros => [
    for (final d in (json['distros'] as List? ?? const [])) ((d as Map)['id'] as String, d['label'] as String),
  ];
}

class SkillInfo {
  SkillInfo(this.json);
  final Map<String, dynamic> json;

  String get name => json['name'] as String;
  String get description => json['description'] as String? ?? '';
  String get path => json['path'] as String;
  String get source => json['source'] as String? ?? 'local';
  bool get builtin => json['builtin'] == true;
}

class RemoteSkill {
  RemoteSkill(this.json);
  final Map<String, dynamic> json;

  String get name => json['name'] as String;
  String get source => json['source'] as String;
  bool get installed => json['installed'] == true;
}

class SkillHit {
  SkillHit(this.json);
  final Map<String, dynamic> json;

  String get name => json['name'] as String;
  String get description => json['description'] as String? ?? '';
  String get spec => json['spec'] as String;
  String get origin => json['origin'] as String? ?? '';
  bool get installed => json['installed'] == true;
  String? get note => json['note'] as String?;
}

class AppSettings {
  AppSettings(this.json);
  final Map<String, dynamic> json;

  String get dns => json['dns'] as String? ?? 'cloudflare';
  String? get dnsUrl => json['dnsUrl'] as String?;
  bool get hasBraveKey => json['braveKey'] == true;
  bool get hasTavilyKey => json['tavilyKey'] == true;
  String get approvalMode => json['approvalMode'] as String? ?? 'ask_risky';
  List<Map<String, dynamic>> get fallbackModels =>
      (json['fallbackModels'] as List? ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
  double get dailyBudget => (json['dailyBudget'] as num?)?.toDouble() ?? 0;
}

/// Accounts, repositories, SSH and deploys, backed by the host's
/// integrations module (agent/src/integrations.ts).
class Integrations extends ChangeNotifier {
  Integrations(this.client) {
    client.records.listen((r) {
      if (r['type'] == 'task') _taskLines.add(r);
    });
  }

  final AgentClient client;
  final _taskLines = StreamController<Map<String, dynamic>>.broadcast();
  int _nextTask = 1;

  GithubAccount? github;
  String? vercelUser;
  String? publicKey;
  List<SshHost> hosts = const [];
  List<ProjectInfo> projects = const [];
  bool loaded = false;

  void _apply(dynamic summary) {
    final s = (summary as Map).cast<String, dynamic>();
    final gh = s['github'];
    github = gh == null ? null : GithubAccount((gh as Map).cast<String, dynamic>());
    vercelUser = (s['vercel'] as Map?)?['username'] as String?;
    final ssh = (s['ssh'] as Map).cast<String, dynamic>();
    publicKey = ssh['publicKey'] as String?;
    hosts = (ssh['hosts'] as List).map((e) => SshHost((e as Map).cast<String, dynamic>())).toList();
    loaded = true;
    notifyListeners();
  }

  Future<void> refresh() async => _apply(await client.call('integrations'));

  Future<void> refreshProjects() async {
    final list = await client.call<List>('projects');
    projects = list.map((e) => ProjectInfo((e as Map).cast<String, dynamic>())).toList();
    notifyListeners();
  }

  /// Runs a long command, forwarding its output lines to [onLine].
  Future<T> _task<T>(
    String type,
    Map<String, dynamic> args,
    void Function(String line)? onLine, {
    void Function(Map<String, dynamic> ci)? onCi,
  }) async {
    final taskId = 'task-${_nextTask++}';
    final sub = _taskLines.stream.where((r) => r['taskId'] == taskId).listen((r) {
      if (r['ci'] != null) {
        onCi?.call((r['ci'] as Map).cast<String, dynamic>());
      } else {
        onLine?.call(r['line'] as String);
      }
    });
    try {
      return await client.call<T>(type, {...args, 'taskId': taskId});
    } finally {
      await sub.cancel();
    }
  }

  // GitHub
  Future<void> githubLogin(String token) async => _apply(await client.call('github_login', {'token': token}));

  /// Starts GitHub's device flow: returns the code the user types at [verificationUri].
  Future<({String deviceCode, String userCode, String verificationUri, int expiresIn, int interval})>
  githubDeviceStart() async {
    final r = (await client.call<Map>('github_device_start')).cast<String, dynamic>();
    return (
      deviceCode: r['deviceCode'] as String,
      userCode: r['userCode'] as String,
      verificationUri: r['verificationUri'] as String,
      expiresIn: (r['expiresIn'] as num).toInt(),
      interval: (r['interval'] as num).toInt(),
    );
  }

  /// Polls until the user approves, denies or the code expires. Returns true once signed in.
  Future<bool> githubDeviceWait(String deviceCode, int interval, {required bool Function() cancelled}) async {
    var wait = interval;
    while (!cancelled()) {
      await Future<void>.delayed(Duration(seconds: wait));
      if (cancelled()) return false;
      final r = (await client.call<Map>('github_device_poll', {'deviceCode': deviceCode})).cast<String, dynamic>();
      switch (r['status']) {
        case 'done':
          _apply(r['state']);
          return true;
        case 'slow_down':
          wait = (r['interval'] as num?)?.toInt() ?? wait + 5;
        case 'expired':
          throw 'The code expired. Try again.';
        case 'denied':
          throw 'Login was cancelled on GitHub.';
      }
    }
    return false;
  }

  Future<void> githubLogout() async => _apply(await client.call('github_logout'));

  Future<List<RepoInfo>> repos() async {
    final list = await client.call<List>('github_repos');
    return list.map((e) => RepoInfo((e as Map).cast<String, dynamic>())).toList();
  }

  Future<String> clone(String fullName, {void Function(String)? onLine}) async {
    final result = await _task<Map>('git_clone', {'repo': fullName}, onLine);
    unawaited(refreshProjects());
    return result['path'] as String;
  }

  // Vercel
  Future<void> vercelLogin(String token) async => _apply(await client.call('vercel_login', {'token': token}));
  Future<void> vercelLogout() async => _apply(await client.call('vercel_logout'));

  // SSH
  Future<String> ensureSshKey() async {
    publicKey = await client.call<String>('ssh_key');
    notifyListeners();
    return publicKey!;
  }

  Future<void> saveHost(Map<String, dynamic> host) async => _apply(await client.call('ssh_host_save', {'host': host}));
  Future<void> deleteHost(String id) async => _apply(await client.call('ssh_host_delete', {'hostId': id}));
  Future<void> testHost(String id, {void Function(String)? onLine}) => _task('ssh_test', {'hostId': id}, onLine);

  // Deploy
  Future<String?> deploy({
    required String target,
    required String dir,
    Map<String, dynamic> options = const {},
    void Function(String)? onLine,
    void Function(Map<String, dynamic>)? onCi,
  }) async {
    final result = await _task<Map>('deploy', {'target': target, 'dir': dir, 'options': options}, onLine, onCi: onCi);
    return result['url'] as String?;
  }

  /// Follows GitHub Actions for the latest commit in [dir].
  Future<void> watchCi(String dir, {void Function(String)? onLine, void Function(Map<String, dynamic>)? onCi}) =>
      _task('ci_watch', {'dir': dir}, onLine, onCi: onCi);

  // Linux container
  ContainerStatus? container;

  Future<ContainerStatus> refreshContainer() async {
    container = ContainerStatus((await client.call<Map>('container_status')).cast<String, dynamic>());
    notifyListeners();
    return container!;
  }

  Future<void> installContainer(String distro, {void Function(String)? onLine}) async {
    await _task('container_install', {'distro': distro}, onLine);
    await refreshContainer();
  }

  Future<void> removeContainer() async {
    container = ContainerStatus((await client.call<Map>('container_remove')).cast<String, dynamic>());
    notifyListeners();
  }

  Future<void> setContainerShell(bool on) async {
    container = ContainerStatus((await client.call<Map>('container_enable', {'on': on})).cast<String, dynamic>());
    notifyListeners();
  }

  // Skills
  Future<List<SkillInfo>> skills() async =>
      (await client.call<List>('skills_list')).map((e) => SkillInfo((e as Map).cast<String, dynamic>())).toList();

  Future<List<RemoteSkill>> browseSkills(String spec) async => (await client.call<List>('skills_browse', {
    'spec': spec,
  })).map((e) => RemoteSkill((e as Map).cast<String, dynamic>())).toList();

  Future<List<SkillInfo>> installSkill(String spec, {void Function(String)? onLine}) async => (await _task<List>(
    'skills_install',
    {'spec': spec},
    onLine,
  )).map((e) => SkillInfo((e as Map).cast<String, dynamic>())).toList();

  Future<List<SkillHit>> searchSkills(String query) async => (await client.call<List>('skills_search', {
    'query': query,
  })).map((e) => SkillHit((e as Map).cast<String, dynamic>())).toList();

  Future<void> removeSkill(String path) => client.call('skills_remove', {'path': path});

  // App settings (DNS, search keys)
  AppSettings? settings;

  Future<AppSettings> refreshSettings() async {
    settings = AppSettings((await client.call<Map>('settings_get')).cast<String, dynamic>());
    notifyListeners();
    return settings!;
  }

  Future<void> updateSettings(Map<String, dynamic> patch) async {
    settings = AppSettings((await client.call<Map>('settings_set', {'settings': patch})).cast<String, dynamic>());
    notifyListeners();
  }

  @override
  void dispose() {
    _taskLines.close();
    super.dispose();
  }
}
