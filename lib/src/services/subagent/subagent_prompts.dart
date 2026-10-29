import '../../models/subagent.dart';

String subagentSystemPrompt({
  required String agentName, required SubagentRole role, required String domain,
  required String knowledge, required String worklog, required String intention,
  required String userLanguage,
}) => '''You are $agentName, an agent working in $domain. Respond in $userLanguage.
Use only the tools supplied by the host. Report actual tool results and distinguish completed work from uncertainty.
Role: ${role.name}
Assignment: $intention
Knowledge: $knowledge
Work log: $worklog
''';

String kSubagentRoundCapStopNotice(int maxRounds) =>
    '[Crux system note — round limit reached]\n'
    'This run has reached its $maxRounds-round limit. Stop working NOW '
    'and do NOT call any tool — this is your final exchange and tool '
    'calls cannot be executed anymore. Write your INTERIM report as '
    'plain text in this reply: state that the round limit was hit, '
    'then cover what you completed so far (with file paths / evidence), '
    'what is verified, what remains, and exactly where the next '
    'dispatch should pick up. This report is the only thing that '
    'survives — anything not written here is lost.';

/// The report envelope injected into the main session when a run ends.
///
/// Walks the runtime system-note path (never a user message). The
/// `next` line teaches the main agent the agent is ready again.
String subagentReportEnvelope({
  required String agentName,
  required SubagentRole role,
  required String domain,
  required String intention,
  required String status,
  required String report,
}) {
  final roleLabel = role == SubagentRole.worker ? 'worker' : 'expert';
  // Round-cap statuses arrive from the runner's cap branch: the report
  // below is INTERIM, gathered by a final stop-notice exchange, not a
  // finished task. The envelope must say so — the main agent would
  // otherwise relay unfinished work as done.
  final capped = status == 'round_cap' || status == 'round_cap_no_report';
  final nextHint = capped
      ? 'agent://$agentName is ready; re-dispatch with send_agent to '
            'continue from where the interim report left off.'
      : 'agent://$agentName is ready; send_agent dispatches the next '
            'task.';
  return '[Crux system note — subagent report]\n'
      'from: agent://$agentName ($roleLabel, domain: $domain)\n'
      'intention: $intention\n'
      'status: $status\n'
      '${capped ? 'note: INTERIM report — the run hit its round limit '
                'before finishing; the task is INCOMPLETE.\n' : ''}'
      'report: |\n'
      '${_indentBlock(report)}\n'
      'next: $nextHint';
}

String _indentBlock(String text) {
  final lines = text.trimRight().split('\n');
  return lines.map((l) => '  ${l.trimRight()}').join('\n');
}

/// The mode announcement attached to the FIRST user message after a
/// toggle flip (plan §模式切换与 cache: rides the message, never the
/// system prompt — zero cache invalidation).
///
/// [workersOn]/[expertsOn] select the on-announcement's emphasis; a
/// both-off call renders the symmetric exit announcement. The text is
/// English (the system-prompt language); the dispatching user message
/// may be any language.
String subagentModeAnnouncement({
  required bool workersOn,
  required bool expertsOn,
}) {
  if (!workersOn && !expertsOn) {
    return '[Crux system note — subagent mode off]\n'
        'Subagent mode has been turned OFF. Edit/write/shell tools are '
        'yours to use directly again — no dispatching required.\n'
        'Agents you hired earlier stay on the roster '
        '(find_agents still lists them) and remain dispatchable the '
        'moment the switches go back on.';
  }
  final buffer = StringBuffer('[Crux system note — subagent mode on]\n');
  if (workersOn) {
    buffer.writeln(
      'Worker dispatch is ON: hands-on work (edit, write, shell/build/test '
      'runs) MUST go to a worker via send_agent / hire_agent. That includes '
      'investigation and diagnosis — reading code to find a root cause, '
      'tracing a call chain, locating where something lives. You orchestrate: '
      'decompose, dispatch, verify. You never do the legwork yourself, even '
      'with read-only tools. Parallelize aggressively: whenever a task can '
      'split into independent chunks, split it and dispatch each chunk to its '
      'OWN worker — they run concurrently in the background, so a batch of '
      'small pieces finishes faster than one long serial run, and each '
      'worker keeps a narrow context.',
    );
  }
  if (expertsOn) {
    buffer.writeln(
      'Expert consultation is ON: when unsure about an approach or when a '
      'change needs a read-only second opinion, hire or send an expert '
      '(read-only advisor) and weigh its answer.',
    );
  }
  buffer.writeAll([
    'Workflow:\n',
    if (workersOn)
      '- Parallelize: split a large task into independent, non-overlapping '
          'chunks and dispatch each chunk to a DIFFERENT worker — send_agent '
          'returns immediately and runs execute in the background concurrently. '
          'Keep chunks disjoint: separate files/areas, no ordering dependency, '
          'so results compose without merge conflicts. Never hand the same '
          'region to two agents.\n',
    '- Domains are NARROW: prefer a specific label like "token-refresh" '
        'or "home-rendering" over a broad one like "general" or "ui". Name '
        'domains in the USER\'s language (the reply_language setting), e.g. '
        'a Chinese-speaking user gets "消息渲染", not "message-rendering" — '
        'the domain shows up in the user\'s UI.\n'
        '- HARD RULE — domain match is mandatory: send_agent/hire only an '
        'agent whose domain names THIS task\'s subject area. A worker being '
        'idle, ready, or recently used is NEVER a reason to reuse it — an '
        'idle "CI 修复" agent must not receive a subagent-runtime bug. Before '
        'dispatching, ask: would this task\'s one-line description sit '
        'naturally under the agent\'s existing domain label? If NO, '
        'hire_agent a fresh one with a precise domain label instead — every '
        'dispatch to a mismatched agent pollutes its distilled context and '
        'dilutes its specialty. When in doubt, hire fresh: a new narrow '
        'agent costs minutes, a polluted one costs all its future runs.\n'
        '- ALWAYS refer to agents as agent://<id> (e.g. agent://orion) — '
        'never the bare name. The UI renders agent://<id> as the localized '
        'constellation name in the user\'s language; a bare id like "apus" '
        'or "ara" is meaningless to a non-English user. This applies '
        'EVERYWHERE: prose, tables, headings, summaries.\n'
        '- find_agents first — someone may already own the domain.\n'
        '- Dispatch with intention (one line, shown to the user) and a '
        'message that states the task boundary, acceptance criteria, and '
        'the report granularity you want (one-line conclusion vs '
        'detailed).\n'
        '- check_agent asks progress; cancel_agent is the brake; a busy '
        'agent queues by default — fork only when it cannot wait.\n'
        '- Agents report back on their own as system notes; relay their '
        'conclusions to the user, then verify / accept.\n',
  ]);
  return buffer.toString();
}
