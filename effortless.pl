#!/usr/bin/env perl
# codex-effortless for Codex on Linux, macOS and WSL. One script, only core Perl modules (and curl for Jev):
#
#   effortless.pl hook            the UserPromptSubmit hook (judge.sh runs this)
#   effortless.pl codex [args]    start the Codex CLI with Auto: every prompt runs at the effort the judge picks
#   effortless.pl stats | debug | auto [on|off] | save [on|off] | config [set KEY VALUE] | test [prompt]
#   effortless.pl handoff-save | handoff-show | handoff-write | copy | bench | update | version
#
# GPT-5.6 Luna on your Codex login (or Jev on TypeSafe first, when you have a key) reads each
# prompt and picks the reasoning effort. Started through `codex` above, the effort is set for the turn
# itself; started as plain `codex`, a hook can only say which effort to pick, because Codex hooks cannot
# set it (openai/codex#40599).
use strict;
use warnings;
use utf8;
use JSON::PP;
use POSIX qw(setsid WNOHANG _exit);
use Time::HiRes qw(time sleep);
use Time::Local qw(timegm);
use Digest::MD5 qw(md5_hex);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use File::Glob qw(bsd_glob);
use Cwd qw(abs_path getcwd);
use IO::Select;
use IO::Handle;
use Encode qw(encode_utf8 decode_utf8);

our $VERSION = '0.5.4';
my $HERE = dirname(abs_path($0));
my $HOME = $ENV{HOME} // '';
my $CODEX_HOME = $ENV{CODEX_HOME} || "$HOME/.codex";
my $JSON = JSON::PP->new->utf8->canonical;
# Text in, text out: for JSON that goes inside other text.
my $JSON_TEXT = JSON::PP->new->canonical;

# ---------------------------------------------------------------- settings

# effortless.conf: KEY=${KEY:-value} or KEY=value lines, # comments. Environment variables win.
my %conf;
if (open my $f, '<', "$HERE/effortless.conf") {
  while (<$f>) {
    next unless /^\s*(EFFORTLESS_\w+)=(.*)$/;
    my ($k, $v) = ($1, $2);
    if ($v =~ /^\$\{\w+:-([^}]*)\}/) { $v = $1 } else { $v =~ s/\s+#.*$// }
    $v =~ s/^\s+|\s+$//g;
    $v =~ s/^["']|["']$//g;
    $conf{$k} = decode_utf8($v);
  }
}
sub S {
  my ($k, $d) = @_;
  my $e = $ENV{$k};
  return decode_utf8($e) if defined $e && $e ne '';
  return $conf{$k} if defined $conf{$k} && $conf{$k} ne '';
  return $d;
}

my $MODE = S('EFFORTLESS_MODE', 'auto');            # auto, warn, block, off
my $JUDGE = S('EFFORTLESS_JUDGE', 'auto');          # auto, luna, jev
my $MODEL = S('EFFORTLESS_MODEL', 'gpt-5.6-luna');
my $MIN = S('EFFORTLESS_MIN', 'medium');
my $MAX = S('EFFORTLESS_MAX', 'max');
my $BIAS = int(S('EFFORTLESS_BIAS', 0));
my $BLOCK_GAP = int(S('EFFORTLESS_BLOCK_GAP', 1));
my $BUDGET = int(S('EFFORTLESS_TIMEOUT', 20));
my $JEV_URL = S('EFFORTLESS_JEV_URL', $ENV{JEV_URL} || 'https://api.typesafe.ai/v1/systemone');
my $SWAMP_AT = S('EFFORTLESS_SWAMP_AT', 70);
my $COLD = S('EFFORTLESS_COLD', 'block');           # block, warn, off
my $COLD_MINUTES = S('EFFORTLESS_COLD_MINUTES', 30);
my $COLD_TOKENS = S('EFFORTLESS_COLD_TOKENS', 150000);
my $HOT_AT = S('EFFORTLESS_HOT_AT', 80);
my $HANDOFF_FROM = S('EFFORTLESS_HANDOFF_FROM', 30);
my $HANDOFF_EVERY = int(S('EFFORTLESS_HANDOFF_EVERY', 2)) || 2;
my $HANDOFF_SKILL = S('EFFORTLESS_HANDOFF_SKILL', '');
my $HANDOFF_AFTER = S('EFFORTLESS_HANDOFF_AFTER', 'continue');   # continue, confirm, copy
# Empty hides nothing: the default (reason) holds only when the setting is not there at all, as in the original.
my %HIDE = map { $_ => 1 } grep { length } split /\s*,\s*/, S('EFFORTLESS_HIDE', exists $conf{EFFORTLESS_HIDE} ? '' : 'reason');
my $BAR = S('EFFORTLESS_BAR', 'changes');           # changes, always
my $UPDATE_CHECK = S('EFFORTLESS_UPDATE_CHECK', 'on');
my ($CODEX, $CODEX_OK) = find_codex(S('EFFORTLESS_CODEX', ''));
my $NO_CODEX = '需要 Codex CLI，安装：curl -fsSL https://chatgpt.com/codex/install.sh | sh';
my $DATA = S('EFFORTLESS_DATA', "$CODEX_HOME/effortless/data");
make_path("$DATA/sessions", "$DATA/routed", "$DATA/tmp");
my $LOG = "$DATA/verdicts.tsv";

my @LEVELS = qw(none minimal low medium high xhigh max ultra);
my %RANK = map { $LEVELS[$_] => $_ } 0 .. $#LEVELS;
my @JUDGED = qw(low medium high xhigh max);         # what the judges answer with
sub rank { my $l = shift // ''; exists $RANK{$l} ? $RANK{$l} : -1 }

# ---------------------------------------------------------------- small helpers

sub trim { my $s = shift // ''; $s =~ s/^\s+|\s+$//g; $s }
# Where codex is: the setting, then PATH, then where OpenAI's installer puts it (~/.local/bin, and the release that
# links to). A hook, a cron job or an editor can run with a PATH that has no ~/.local/bin. Gives (command, found).
sub find_codex {
  my $set = shift;
  return ($set, 1) if length $set;
  for my $dir (split /:/, $ENV{PATH} // '') { return ('codex', 1) if length $dir && -f "$dir/codex" && -x _ }
  for my $c ("$HOME/.local/bin/codex", "$CODEX_HOME/packages/standalone/current/bin/codex") { return ($c, 1) if -f $c && -x _ }
  return ('codex', 0);
}
sub now { time() }
sub slurp { my $p = shift; open my $f, '<:raw', $p or return undef; local $/; my $t = <$f>; $t }
sub spew {
  my ($p, $t, $mode) = @_;
  my $tmp = "$p.$$";
  open my $f, '>:raw', $tmp or return;
  print $f $t;
  close $f;
  chmod $mode, $tmp if $mode;
  rename $tmp, $p;
}
sub read_json { my $t = slurp(shift); return undef unless defined $t; my $j = eval { $JSON->decode($t) }; $j }
sub write_json { my ($p, $v) = @_; spew($p, $JSON->encode($v)) }
sub iso_time {
  my $s = shift // return undef;
  $s =~ /^(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+(?:\.\d+)?)/ or return undef;
  timegm(int($6), $5, $4, $3, $2 - 1, $1) + ($6 - int($6));
}
sub ktokens { my $n = shift // 0; $n >= 1000 ? sprintf('%dk', int($n / 1000 + 0.5)) : $n }
# "14:20" for a time within 20 hours, "周一 14:20" further out.
sub clock_of {
  my $at = shift;
  my @t = localtime($at);
  my $hm = sprintf('%02d:%02d', $t[2], $t[1]);
  return $at - now() < 20 * 3600 ? $hm : (qw(周日 周一 周二 周三 周四 周五 周六))[$t[6]] . " $hm";
}
sub cut { my ($s, $n) = @_; $s //= ''; length($s) > $n ? substr($s, 0, $n) : $s }
sub tail { my ($s, $n) = @_; $s //= ''; length($s) > $n ? substr($s, -$n) : $s }
sub say_json { print STDOUT $JSON->encode(shift), "\n" }
sub out { print STDOUT encode_utf8(join('', @_)) }

my $by = '-';
my $session = '-';
sub log_row {
  my ($cur, $verdict, $sure, $ms, $tokens, $action) = @_;
  my @t = gmtime();
  my $ts = sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, @t[3, 2, 1, 0]);
  open my $f, '>>', $LOG or return;
  print $f encode_utf8(join("\t", $ts, $cur // '-', $verdict // '-', $sure // '-', $ms // 0, $tokens // 0, $action, $by, $session) . "\n");
}

# ---------------------------------------------------------------- the transcript

# What effortless reads from a session's transcript (~/.codex/sessions/.../rollout-*.jsonl): the effort and
# model in use, how full the context is, when the last answer came, the usage limits, and the messages.
# With $full, also every message and tool call in order (msgs), for a handoff written from the transcript.
sub read_transcript {
  my ($path, $full) = @_;
  my %t = (users => [], usage => [], turn_effort => {}, limits => {}, msgs => []);
  return \%t unless $path && -f $path;
  open my $f, '<:raw', $path or return \%t;
  my $n = 0;
  while (my $line = <$f>) {
    $n++;
    $t{desktop} = 1 if $n <= 3 && $line =~ /"originator"\s*:\s*"Codex Desktop"/;
    next unless $line =~ /"type"\s*:\s*"(turn_context|token_count|message|token_usage_record)"/
      || $full && $line =~ /"type"\s*:\s*"[a-z_]*(call|call_output)"/;
    my $j = eval { $JSON->decode($line) } or next;
    my $p = $j->{payload} // {};
    my $type = $j->{type} // '';
    if ($type eq 'turn_context') {
      my $e = $p->{effort} // $p->{collaboration_mode}{settings}{reasoning_effort};
      $t{effort} = $e if $e;
      $t{model} = $p->{model} if $p->{model};
      $t{turn_effort}{$p->{turn_id}} = $e if $p->{turn_id} && $e;
    } elsif ($type eq 'event_msg' && ($p->{type} // '') eq 'token_count') {
      if (my $info = $p->{info}) {
        my $u = $info->{last_token_usage} // {};
        $t{tokens} = ($u->{input_tokens} // 0) + ($u->{output_tokens} // 0);
        $t{window} = $info->{model_context_window} if $info->{model_context_window};
        $t{last_at} = iso_time($j->{timestamp});
      }
      my $rl = $p->{rate_limits} // {};
      for my $k (qw(primary secondary)) {
        my $w = $rl->{$k} or next;
        next unless defined $w->{used_percent};
        $t{limits}{$k} = { pct => $w->{used_percent}, minutes => $w->{window_minutes}, resets => $w->{resets_at} };
      }
    } elsif ($type eq 'response_item' && ($p->{type} // '') eq 'message') {
      my $text = join '', map { $_->{text} // '' } grep { ($_->{type} // '') =~ /text/ } @{ $p->{content} // [] };
      if (($p->{role} // '') eq 'user') {
        # Codex sends its own context as user messages too: they start with a tag.
        next if $text =~ /^\s*(<[a-z_]+>|# AGENTS\.md)/;
        push @{ $t{users} }, $text;
        push @{ $t{msgs} }, { role => 'user', text => $text } if $full;
      } elsif (($p->{role} // '') eq 'assistant') {
        $t{last_assistant} = $text if trim($text) ne '' && ($p->{phase} // 'final_answer') ne 'commentary';
        push @{ $t{msgs} }, { role => 'assistant', text => $text } if $full && trim($text) ne '';
      }
    } elsif ($full && $type eq 'response_item' && ($p->{type} // '') =~ /_call$/) {
      my $input = $p->{arguments} // $p->{input} // $p->{action} // '';
      push @{ $t{msgs} }, { role => 'tool', text => ($p->{name} // $p->{type}) . ' ' . (ref $input ? $JSON_TEXT->encode($input) : $input) };
    } elsif ($full && $type eq 'response_item' && ($p->{type} // '') =~ /_call_output$/) {
      my $o = $p->{output} // '';
      $o = $o->{content} // $o if ref $o eq 'HASH';
      $o = join "\n", map { ref $_ eq 'HASH' ? $_->{text} // '' : $_ } @$o if ref $o eq 'ARRAY';
      $o = $JSON_TEXT->encode($o) if ref $o;
      push @{ $t{msgs} }, { role => 'result', text => $o };
    } elsif ($type eq 'token_usage_record') {
      my $u = $p->{usage} // {};
      push @{ $t{usage} }, { turn => $p->{turn_id}, in => $u->{input_tokens} // 0, cached => $u->{cached_input_tokens} // 0, out => $u->{output_tokens} // 0 };
    }
  }
  if (!$t{effort}) {
    # Older transcripts: the last reasoning_effort recorded anywhere.
    seek $f, 0, 0;
    while (<$f>) { $t{effort} = $1 if /"reasoning_effort"\s*:\s*"([a-z]+)"/ }
  }
  $t{percent} = $t{window} ? 100 * ($t{tokens} // 0) / $t{window} : 0;
  return \%t;
}

# The models Codex knows, with the efforts each takes (Codex keeps this list in models_cache.json).
sub model_info {
  my $model = shift // return undef;
  my $j = read_json("$CODEX_HOME/models_cache.json") or return undef;
  for my $m (@{ $j->{models} // [] }) {
    next unless ($m->{slug} // '') eq $model;
    return {
      supported => [map { ref $_ ? ($_->{effort} // $_->{reasoningEffort}) : $_ } @{ $m->{supported_reasoning_levels} // [] }],
      updates => $m->{supports_reasoning_effort_updates},
      default => $m->{default_reasoning_level},
      window => $m->{context_window},
    };
  }
  return undef;
}

sub config_effort {
  my $t = slurp("$CODEX_HOME/config.toml") // '';
  my @m = $t =~ /^\s*model_reasoning_effort\s*=\s*"([a-z]+)"/mg;
  return $m[-1];
}

# ---------------------------------------------------------------- what the judges are asked

my $JUDGE_SYSTEM = <<'EOT';
You choose the reasoning effort an agentic coding assistant (it reads files, runs tools and edits things, not only code) should use for the user's next message. Pick the cheapest effort that will still do the job well. Never use tools.

Effort: low for quick answers, medium for normal work, high for hard problems, xhigh or max only for very hard ones.
- low: quick questions, explanations, small mechanical edits such as a rename, a typo or a config value, running one command.
- medium: ordinary feature work or a bug fix in code that is easy to locate, moderate multi-file edits, tests for clear behaviour.
- high: debugging unclear failures, concurrency, performance or security problems, design decisions, refactors across many files, anything where a wrong answer is costly.
- xhigh: long autonomous multi-step tasks, deep investigations, hard algorithmic or architectural problems.
- max: only the hardest research-level work.
Do not lean toward the current effort: pick what the message needs.

Judge the SCOPE and the amount of work, not whether it is code. A short message can ask for a lot: "go through my whole drive and clean it up", "review the entire repo", "migrate everything" are big, multi-step, tool-heavy jobs where mistakes are costly: never low, usually high. Low is only for answers that need no tools and no planning.

If the message answers a question in the assistant's last reply (picks an option, says which one, confirms a plan), judge only the work that answer starts, as the reply describes it, not the length of the answer and not the work done before the question: "B" can mean "build the complicated section B" (high), while "yes" or "no" to one small action ("should I archive this?", "delete the old ones too?") is low, and picking a value for one setting (a log level, a colour, a font) is low. But picking which way to build something ("option 1", "the same shapes", "B") starts that build: judge the build. Approving a whole plan or several steps takes the effort of that plan. A plain "yes", "ok" or "do it" after "Is that OK? Then I'll build X" or "Should I build X?" approves building X: judge X, not the word.

A message that pushes back on, corrects or adds to a plan or claim under discussion continues that work: keep at least the effort that work had, never drop to low for it. Thanks, praise or a closing remark with no new request is low. A question about how to do something, or about effort itself, that needs no tools is low.

If the person asks for deep thought ("think hard", "ultrathink", "be thorough"), pick at least high; if they ask for a quick answer, pick low.

If the message is a short follow-up to ongoing work ("yes", "go", "ok", "continue", or the same in any language), keep the current effort.

Reply with JSON only: {"effort":"low|medium|high|xhigh|max","sure":0.0-1.0 how sure you are of the effort,"why":"at most 6 words, in the user's language"}
EOT
chomp $JUDGE_SYSTEM;
my $EFFORT_SCHEMA = { type => 'object', additionalProperties => JSON::PP::false, required => [qw(effort sure why)],
  properties => { effort => { type => 'string', enum => [@JUDGED] }, sure => { type => 'number' }, why => { type => 'string' } } };

my $HANDOFF_SYSTEM = <<'EOT';
You decide whether the person should hand off now: start a fresh chat that carries over a short summary, instead of carrying on in this one. You are shown what the chat was for, the trail of what the person asked, the last turns, the next message, how full the context is and whether the cache is cold. Never use tools.

Say yes only for a clear reason: the task just finished and the next message is something else, the topic has changed so the old context is dead weight, the chat keeps going in circles on the same problem, or a long chat now holds so much unrelated history that a clean start would be sharper. A normal next step of the same work is never a reason, a long chat by itself is not one, and neither is a high context share when the work is going well. When unsure, say no: a wrong yes costs the person more than a missed one.

Reply with JSON only: {"handoff":"reason of at most 8 words, in the person's language"} for yes, or {"handoff":null} for no.
EOT
chomp $HANDOFF_SYSTEM;
my $HANDOFF_SCHEMA = { type => 'object', additionalProperties => JSON::PP::false, required => ['handoff'],
  properties => { handoff => { type => ['string', 'null'] } } };

my %JEV_EFFORTS = (
  low => 'quick answer, no tools, no planning',
  medium => 'normal work: a few tool calls or edits',
  high => 'hard or large multi-step job: many tool calls, costly mistakes',
  xhigh => 'very hard: a long investigation',
  max => 'the hardest research-level work',
);
my $JEV_TASK = 'Choose the reasoning effort an agentic coding assistant should use for the next user message. It reads files, '
  . 'runs tools and edits things, not only code. Pick the cheapest that still does the job well. Judge the scope and the '
  . 'amount of work, not whether it is code: "go through my whole drive and clean it up" is a big tool-heavy job. '
  . 'A short follow-up ("yes", "go", "ok", in any language) keeps the current effort. When the message answers a '
  . "question in the assistant's last reply (picks an option), judge only the work that answer starts, not its length and "
  . 'not the work before the question: yes/no to one small action, or picking a value for one setting (a log level, a colour), is low; picking which way to build something starts that build, so judge the build; '
  . 'approving a whole plan takes the effort of that plan; a plain yes to "Then I will build X" means judge X. Pushing back on or adding to a plan under discussion continues that work: keep its effort, never low. Thanks or a closing remark with no new request is low. A '
  . 'question about how to do something that needs no tools is low. "think hard", "ultrathink" or "be thorough" means '
  . 'at least high; "quick question" means low.';

# The judge's view of the conversation: the person's previous message, short, and the end of the last reply,
# where a question with options ("A, B or C?") sits: "B" alone looks like a small job, the reply says what it sets off.
sub context_text {
  my ($last_user, $last_assistant) = @_;
  join "\n", grep { length } ($last_user ? 'user: ' . cut($last_user, 400) : ''), ($last_assistant ? 'assistant: ' . tail($last_assistant, 2000) : '');
}

sub judge_question {
  my ($prompt, $current, $context, $percent) = @_;
  join "\n\n", grep { length } (
    'Current effort: ' . ($current // 'unknown'),
    $context ? "Recent conversation:\n$context" : '',
    "Next message:\n" . cut($prompt, 2000),
    $percent ? sprintf('Context used: %d%% of the window', $percent + 0.5) : '',
  );
}

sub handoff_evidence {
  my ($users, $last_assistant, $next, $percent, $cold) = @_;
  my @asked = grep { trim($_) ne '' } @$users;
  pop @asked if @asked && $asked[-1] eq $next;
  my $first = @asked ? cut($asked[0], 500) : '';
  my @trail = map { my $m = cut($_, 160); $m =~ s/\s+/ /g; "- $m" } @asked > 1 ? @asked[(@asked > 8 ? -8 : 1) .. -1] : ();
  join "\n\n", grep { length } (
    $first ? "What the chat was for (first message):\n$first" : '',
    @trail ? "Trail of earlier messages:\n" . join("\n", @trail) : '',
    $last_assistant ? "The assistant's last reply (its end):\n" . tail($last_assistant, 700) : '',
    "Next message:\n" . cut($next, 600),
    sprintf('Context used: %d%% of the window; %d messages so far; the cache is %s.', $percent + 0.5, scalar(@asked) + 1, $cold ? 'cold' : 'warm'),
  );
}

# A level the prompt names ("max effort", "effort: high", "xhigh"), or nothing. The word effort must sit beside the
# level, so "a medium sized image" names nothing, and "don't use max effort" is a no. As in the original, a named
# level runs without the judge.
my $LEVEL_WORD = '(low|medium|high|xhigh|x-high|extra[- ]high|max|maximum)';
my $NAMED_LEVEL = qr/\b$LEVEL_WORD\s+effort\b|\beffort(?:\s+level)?\s*(?:[:=]|to|at|of|on)?\s*$LEVEL_WORD\b|\bxhigh\b/ia;
my %LEVEL_OF = (low => 'low', medium => 'medium', high => 'high', xhigh => 'xhigh', 'x-high' => 'xhigh', 'extra high' => 'xhigh', 'extra-high' => 'xhigh', max => 'max', maximum => 'max');
sub named_effort {
  my $text = shift // '';
  while ($text =~ /$NAMED_LEVEL/g) {
    my ($at, $word) = ($-[0], $1 // $2 // 'xhigh');
    my $before = lc substr($text, $at > 20 ? $at - 20 : 0, $at > 20 ? 20 : $at);
    next if $before =~ /\b(not|no|don'?t|never|without|instead of)\b/a || $before =~ /(不要|不用|别|无需|不必)/;
    $word = lc $word;
    $word =~ s/\s+/ /;
    return $LEVEL_OF{$word};
  }
  return undef;
}

# "$effortless stats" and the like: effortless's own commands, never judged.
sub own_command { (shift // '') =~ /^\s*\$effortless\b/i }

# The skill a typed "$name args" runs ({name, description}), or nothing: looked up where Codex keeps skills (yours,
# the system ones, ~/.agents, the project's, plugins'). A plugin's "$plugin:skill" is found by its last part.
sub typed_skill {
  my ($text, $cwd) = @_;
  my ($name) = ($text // '') =~ /^\s*\$([A-Za-z0-9][\w.:-]*)/ or return undef;
  return undef if lc $name eq 'effortless';
  $name =~ s/^.*://;
  my @roots = ("$CODEX_HOME/skills", "$CODEX_HOME/skills/.system", "$HOME/.agents/skills",
    ($cwd ? ("$cwd/.agents/skills", "$cwd/.codex/skills") : ()), bsd_glob("$CODEX_HOME/plugins/cache/*/*/*/skills"));
  for my $root (@roots) {
    for my $file (bsd_glob("$root/*/SKILL.md")) {
      my $head = decode_utf8(slurp($file) // '', Encode::FB_DEFAULT);
      my ($front) = $head =~ /\A---\s*\n(.*?)\n---/s or next;
      my ($called) = $front =~ /^name:\s*["']?(.*?)["']?\s*$/m;
      next unless ($called // '') eq $name || (split m{/}, dirname($file))[-1] eq $name;
      my ($what) = $front =~ /^description:\s*["']?(.*?)["']?\s*$/m;
      return { name => $name, description => cut(trim($what // ''), 400) };
    }
  }
  return undef;
}

# A short follow-up such as "go", "ok", "继续" keeps the effort the work is on, unless the last reply ended on a
# question: then the answer can start a small or a big job, and goes to the judge.
my $FOLLOW_RE = qr/^\s*(ok(ay)?|y(es)?|yep|sure|go( ahead)?|continue|do it|proceed|thanks?|lgtm|好的?|行|可以|继续|是的?|对|嗯|开始吧?|确认|没问题)\s*[.!。！~～]*\s*$/i;
sub is_follow_up {
  my $t = trim(shift);
  return 0 if $t eq '';
  return 1 if length($t) <= 24 && $t =~ $FOLLOW_RE;
  # The original's rule for words split by spaces: a dozen characters and two words at most.
  return 1 if $t !~ /[^\x00-\x7f]/ && length($t) <= 12 && scalar(split /\s+/, $t) <= 2;
  return 0;
}
sub ends_on_question { my $r = shift // ''; tail($r, 400) =~ /[?？]/ }
sub keeps_effort { my ($p, $last_assistant) = @_; is_follow_up($p) && !ends_on_question($last_assistant) }

# ---------------------------------------------------------------- processes

# Starts a command in its own process group (so the whole tree can be stopped) with pipes on stdin and stdout.
sub spawn {
  my ($opt, @cmd) = @_;
  pipe(my $child_in, my $to_child) or return;
  pipe(my $from_child, my $child_out) or return;
  my $pid = fork;
  return unless defined $pid;
  if (!$pid) {
    setsid();
    open STDIN, '<&', $child_in;
    open STDOUT, '>&', $child_out;
    open STDERR, '>', '/dev/null';
    close $to_child; close $from_child;
    chdir $opt->{cwd} if $opt->{cwd};
    $ENV{$_} = $opt->{env}{$_} for keys %{ $opt->{env} // {} };
    { exec { $cmd[0] } @cmd }
    _exit(127);
  }
  close $child_in; close $child_out;
  $to_child->autoflush(1);
  return ($pid, $to_child, $from_child);
}
sub stop_tree {
  my $pid = shift or return;
  kill 'TERM', -$pid;
  for (1 .. 20) { return if waitpid($pid, WNOHANG) != 0; sleep 0.05 }
  kill 'KILL', -$pid;
  waitpid($pid, 0);
}

# Reads whole lines from $fh until the deadline; calls $on_line for each, and with undef on a quiet moment;
# stops when it returns true.
sub read_lines {
  my ($fh, $deadline, $buf, $on_line) = @_;
  my $sel = IO::Select->new($fh);
  while (1) {
    while ($$buf =~ s/^([^\n]*)\n//) { return 1 if $on_line->($1) }
    return 1 if $on_line->(undef);
    my $left = $deadline - now();
    return 0 if $left <= 0;
    next unless $sel->can_read($left < 0.25 ? $left : 0.25);
    my $got = sysread($fh, $$buf, 65536, length $$buf);
    return 0 unless $got;
  }
}

# ---------------------------------------------------------------- the judges

our $failed = '';

# Codex: a short-lived app-server on your login, hooks and tools off, one ephemeral thread per question.
# Takes [{system, ask, schema, effort}] (no schema: free text; effort none unless set), gives [{text, tokens}]
# (undef for a question that got no answer).
sub ask_codex {
  my ($jobs, $budget) = @_;
  my @off = map { ('--disable', $_) } qw(apps browser_use browser_use_external computer_use code_mode_host goals hooks image_generation multi_agent plugins remote_plugin shell_snapshot shell_tool skill_search sleep_tool tool_suggest unified_exec view_image web_search workspace_dependencies worktrees);
  # notify=[]: a notify program from config.toml must not fire on (and see) the judge's turn.
  # An empty working directory keeps project files such as AGENTS.md out of the judge's context.
  my $cwd = "$DATA/judge-cwd";
  make_path($cwd);
  my ($pid, $in, $out) = spawn({ cwd => $cwd, env => { EFFORTLESS_JUDGE => 1 } }, $CODEX, 'app-server', '-c', 'notify=[]', @off);
  unless ($pid) { $failed = 'spawn'; return }
  my $deadline = now() + $budget;
  my $buf = '';
  my $send = sub { print $in $JSON->encode(shift), "\n" };
  my @answers;
  my $ok = eval {
    local $SIG{PIPE} = 'IGNORE';
    $send->({ id => 1, method => 'initialize', params => { clientInfo => { name => 'codex-effortless', title => undef, version => $VERSION }, capabilities => undef } });
    read_lines($out, $deadline, \$buf, sub { defined $_[0] && $_[0] =~ /"id"\s*:\s*1\b/ }) or do { $failed = 'init'; return 0 };
    $send->({ method => 'initialized' });
    my %thread_job;
    for my $i (0 .. $#$jobs) {
      $send->({ id => 10 + $i, method => 'thread/start', params => { model => $MODEL, ephemeral => JSON::PP::true, sandbox => 'read-only', approvalPolicy => 'never', cwd => $cwd, baseInstructions => $jobs->[$i]{system} } });
    }
    my %pending = map { (10 + $_) => $_ } 0 .. $#$jobs;
    my (%over, %tokens, $all_over_at);
    read_lines($out, $deadline, \$buf, sub {
      my $line = shift;
      if (defined $line) {
        my $m = eval { $JSON->decode($line) } or return 0;
        if (defined $m->{id} && exists $pending{ $m->{id} }) {
          my $i = delete $pending{ $m->{id} };
          if (my $tid = $m->{result}{thread}{id}) {
            $thread_job{$tid} = $i;
            my %turn = (threadId => $tid, effort => $jobs->[$i]{effort} // 'none', input => [{ type => 'text', text => "[effortless-judge] $jobs->[$i]{ask}" }]);
            $turn{outputSchema} = $jobs->[$i]{schema} if $jobs->[$i]{schema};
            $send->({ id => 20 + $i, method => 'turn/start', params => \%turn });
          } else {
            $over{$i} = 1;
          }
        } elsif (my $method = $m->{method}) {
          my $i = $thread_job{ $m->{params}{threadId} // '' };
          return 0 unless defined $i;
          if ($method eq 'item/completed' && ($m->{params}{item}{type} // '') eq 'agentMessage' && !$answers[$i]) {
            $answers[$i] = { text => $m->{params}{item}{text}, tokens => 0 };
            $over{$i} = 1;
          } elsif ($method eq 'turn/completed' || $method eq 'error') {
            # A turn that ends without an answer (an unknown model, an error) gives up at once.
            $over{$i} = 1;
          } elsif ($method eq 'thread/tokenUsage/updated') {
            $tokens{$i} = $m->{params}{tokenUsage}{total}{totalTokens} // 0;
          }
        }
      }
      return 0 if keys(%over) < @$jobs;
      # Every question answered or given up: wait a moment for the token counts.
      $all_over_at //= now();
      my $counted = grep { !$answers[$_] || exists $tokens{$_} } 0 .. $#$jobs;
      return $counted == @$jobs || now() - $all_over_at > 1.5;
    });
    $answers[$_] && ($answers[$_]{tokens} = $tokens{$_} // 0) for 0 .. $#$jobs;
    1;
  };
  stop_tree($pid);
  $failed ||= 'turn' unless grep { $_ } @answers;
  return $ok ? \@answers : undef;
}

# Runs curl with the header config (the key) on stdin, so the key never shows in the process list, and the
# body in a private file, so the prompt does not either. Gives (status, body).
sub curl_start {
  my ($url, $headers, $body, $timeout) = @_;
  my $base = "$DATA/tmp/req-$$-" . int(rand(1e9));
  spew("$base.body", $body, 0600);
  my ($pid, $in, $out) = spawn({}, 'curl', '-sS', '-m', $timeout, '-o', "$base.out", '-w', '%{http_code}', '-K', '-',
    '-H', 'Content-Type: application/json', '--data-binary', "\@$base.body", $url) or return;
  print $in join('', map { my $h = $_; $h =~ s/(["\\])/\\$1/g; "header = \"$h\"\n" } @$headers);
  close $in;
  return { pid => $pid, out => $out, base => $base };
}
sub curl_finish {
  my $c = shift or return ('000', '');
  local $/;
  my $code = readline($c->{out}) // '';
  waitpid($c->{pid}, 0);
  my $body = slurp("$c->{base}.out") // '';
  unlink "$c->{base}.body", "$c->{base}.out";
  return ($code =~ /(\d{3})/ ? $1 : '000', $body);
}

# The judge for a set of questions: Luna on your Codex login. Sets $by to the judge that answered.
sub ask_judge {
  my $jobs = shift;
  $failed = q{};
  $by = q{codex};
  return ask_codex($jobs, $BUDGET);
}

sub jev_key {
  my $k = S('EFFORTLESS_TYPESAFE_KEY', '');
  return $k if $k ne '';
  return $ENV{TYPESAFE_API_KEY} if $ENV{TYPESAFE_API_KEY};
  # Only when Jev was picked outright is ~/.config/jev/.env read: a file holding a secret nobody asked us to use.
  return undef unless $JUDGE eq 'jev';
  my $t = slurp("$HOME/.config/jev/.env") // '';
  return $t =~ /^\s*TYPESAFE_API_KEY\s*=\s*['"]?([^'"\s]+)/m ? $1 : undef;
}

# Jev on TypeSafe: quick, and answers with its confidence. Below even odds it is unsure: Luna decides then.
sub ask_jev {
  my ($key, $prompt, $current, $context) = @_;
  my $body = { model => 'jev-latest',
    state => { task => $JEV_TASK, current_effort => $current, recent_conversation => $context, next_message => cut($prompt, 4000) },
    questions => { effort => { type => 'choice', instructions => 'Which effort fits the next message?', criteria => \%JEV_EFFORTS } } };
  my ($code, $raw) = curl_finish(curl_start($JEV_URL, ["Authorization: Bearer $key"], $JSON->encode($body), 3));
  return { down => jev_failure($code) } if $code ne '200';
  my $j = eval { $JSON->decode($raw) } or return { down => 'Jev 回复无法读取' };
  my $a = ($j->{answers} // $j->{result}{answers} // {})->{effort} // {};
  my $effort = $a->{choice} // '';
  return { down => 'Jev 回复无法读取' } unless grep { $_ eq $effort } @JUDGED;
  my $sure = $a->{confidence} // $a->{probabilities}{$effort};
  my $tokens = ($j->{usage}{input_tokens} // 0) + ($j->{usage}{output_tokens} // 0);
  return { unsure => 1, tokens => $tokens } if defined $sure && $sure < 0.5;
  return { effort => $effort, sure => $sure, why => defined $sure ? sprintf('%d%% sure', $sure * 100 + 0.5) : '', tokens => $tokens };
}
sub jev_failure {
  my $c = shift;
  return 'Jev 没有及时回答' if $c eq '000';
  return "Jev 拒绝了 key（$c）" if $c eq '401' || $c eq '403';
  return "Jev 额度用完了（$c）" if $c eq '402';
  return "Jev 限流了（$c）" if $c eq '429';
  return "Jev 出错了（$c）";
}

sub parse_verdict {
  my $text = shift // return undef;
  $text =~ /(\{.*\})/s or return undef;
  my $v = eval { JSON::PP->new->decode($1) } or return undef;
  return undef unless ref $v eq 'HASH';
  my $effort = lc($v->{effort} // '');
  return undef unless grep { $_ eq $effort } @JUDGED;
  my $sure = $v->{sure};
  # No confidence stays none, as in the original: a made-up 0.5 would count as a close call and tip the slider.
  $sure = undef unless defined $sure && $sure =~ /^[\d.]+$/ && $sure >= 0 && $sure <= 1;
  my $why = cut($v->{why} // '', 60);
  $why =~ s/["\\]//g;
  $why =~ s/[.。!！ ]+$//;
  return { effort => $effort, sure => $sure, why => $why };
}
sub parse_handoff {
  my $text = shift // return undef;
  $text =~ /(\{.*\})/s or return undef;
  my $v = eval { JSON::PP->new->decode($1) } or return undef;
  my $h = ref $v eq 'HASH' ? $v->{handoff} : undef;
  return defined $h && !ref $h && trim($h) ne '' ? cut(trim($h), 70) : undef;
}

# ---------------------------------------------------------------- picking the effort

# The slider tips close calls only; then the floor and ceiling; save mode caps at medium; then the efforts the model takes.
sub shape_effort {
  my ($effort, $sure, $supported) = @_;
  my $i = rank($effort);
  if ($BIAS && defined $sure && $sure < (abs($BIAS) == 1 ? 0.65 : 0.85)) {
    $i += $BIAS > 0 ? 1 : -1;
    $i = rank('low') if $i < rank('low');
    $i = rank('max') if $i > rank('max');
  }
  my ($lo, $hi) = (rank($MIN), rank($MAX));
  $lo = rank('low') if $lo < 0;
  $hi = rank('max') if $hi < 0;
  $hi = $lo if $hi < $lo;
  $i = $lo if $i < $lo;
  $i = $hi if $i > $hi;
  $i = rank('medium') if saving() && $i > rank('medium');
  return fit_supported($LEVELS[$i], $supported);
}

# The nearest level the model takes, the higher one on a tie.
sub fit_supported {
  my ($level, $supported) = @_;
  my $i = rank($level);
  if ($supported && @$supported && !grep { $_ eq $level } @$supported) {
    my ($best, $dist);
    for my $s (@$supported) {
      my $r = rank($s);
      next if $r < 0;
      my $d = abs($r - $i);
      ($best, $dist) = ($r, $d) if !defined $dist || $d < $dist || ($d == $dist && $r > $best);
    }
    $i = $best if defined $best;
  }
  return $LEVELS[$i];
}

sub saving {
  my $until = slurp("$DATA/save-until") // return 0;
  return 1 if trim($until) > now();
  unlink "$DATA/save-until";
  return 0;
}
sub auto_on { !-e "$DATA/auto-off" }

# One prompt through the pipeline every caller shares (the hook, Auto, the bench): a level named in the prompt
# ("max effort") runs as asked, a follow-up keeps the effort, else Jev (when set) and then Luna judge. With $handoff,
# the handoff question goes along with Luna's.
# Gives {effort (shaped), raw, sure, why, by, ms, tokens, action, down, handoff}.
sub decide {
  my %a = @_;
  my $current = $a{current};
  my $context = context_text($a{last_user}, $a{last_assistant});
  my $started = now();
  my %r = (tokens => 0);
  # effortless's own commands are never judged: the effort stays, and no handoff question goes along.
  if (!$a{only_handoff} && own_command($a{prompt})) {
    return { %r, effort => $current, raw => $current, why => '', action => 'command', ms => 0 };
  }
  my $prompt = $a{prompt};
  $prompt .= "\n\n[The message comes with $a{attachments} to look at.]" if $a{attachments};
  # A typed $skill: its name alone says little, so the judge is told what the skill does.
  if (!$a{only_handoff} && (my $skill = typed_skill($a{prompt}, $a{cwd}))) {
    $prompt .= "\n\n[This message runs a skill: " . ($skill->{description} || $skill->{name}) . " Judge the work the skill will do.]";
  }
  my $named = !$a{only_handoff} && $a{prompt} !~ m{^\s*[\$/]} ? named_effort($a{prompt}) : undef;
  if ($a{only_handoff}) {
    %r = (%r, effort => $current, action => q{skip});
  } elsif ($named) {
    # The person said the level: it runs past Min, Max and save mode, and no judge is asked.
    $by = q{named};
    %r = (%r, effort => fit_supported($named, $a{supported}), raw => $named, sure => 1, why => q{你点名要的}, action => q{named}, by => q{named}, ms => 0);
    return \%r unless $a{handoff};
  } elsif (!$a{attachments} && $current && rank($current) >= 0 && keeps_effort($a{prompt}, $a{last_assistant})) {
    %r = (%r, effort => $current, raw => $current, sure => 1, why => '', action => 'follow-up');
    return \%r unless $a{handoff};
  }
  my $key = $JUDGE ne 'luna' ? jev_key() : undef;
  if (!$r{action} && $key) {
    my $j = ask_jev($key, $prompt, $current, $context);
    $r{tokens} += $j->{tokens} // 0;
    $r{down} = $j->{down} if $j->{down};
    if ($j->{effort}) { $by = 'jev'; %r = (%r, raw => $j->{effort}, sure => $j->{sure}, why => $j->{why}, action => 'judged') }
  }
  my @jobs;
  my ($effort_job, $handoff_job);
  if (!$r{action}) { $effort_job = scalar @jobs; push @jobs, { system => $JUDGE_SYSTEM, ask => judge_question($prompt, $current, $context, $a{percent}), schema => $EFFORT_SCHEMA } }
  if ($a{handoff}) { $handoff_job = scalar @jobs; push @jobs, { system => $HANDOFF_SYSTEM, ask => $a{handoff}, schema => $HANDOFF_SCHEMA } }
  if (@jobs) {
    my $judge_by = $by;
    my $answers = ask_judge(\@jobs) // [];
    $r{tokens} += $_->{tokens} // 0 for grep { $_ } @$answers;
    if (defined $effort_job) {
      if (my $v = parse_verdict(($answers->[$effort_job] // {})->{text})) {
        %r = (%r, raw => $v->{effort}, sure => $v->{sure}, why => $v->{why}, action => 'judged');
      } else {
        $r{action} = 'fail';
        $r{fail} = "$by:" . ($answers->[$effort_job] ? 'verdict' : $failed || 'turn');
        $r{down} //= ($CODEX_OK ? '判断器没有及时回答' : "找不到 codex，判断器没法运行（$NO_CODEX）") . '，档位保持不变' if !$answers->[$effort_job];
      }
    } else {
      $by = $judge_by;
    }
    if (defined $handoff_job && $answers->[$handoff_job]) {
      $r{handoff_checked} = 1;
      $r{handoff} = parse_handoff($answers->[$handoff_job]{text});
    }
  }
  $r{ms} = int((now() - $started) * 1000);
  $r{by} = $by;
  $r{effort} = $r{action} eq 'judged' ? shape_effort($r{raw}, $r{sure}, $a{supported}) : ($r{effort} // $current);
  return \%r;
}

# ---------------------------------------------------------------- the alerts' words (the hook and the previews share them)

# A chat gone cold; $held: the prompt is held back once (COLD=block), else it is a note.
sub cold_text {
  my ($idle, $tokens, $held) = @_;
  my $msg = sprintf('effortless: 对话已冷（闲置 %d 分钟），这条消息会按全价重读约 %s tokens。', $idle, ktokens($tokens));
  return $held ? "${msg}想省就先 /compact 或 \$effortless handoff；原文还在输入框里，直接回车重发就照常发送。"
               : "${msg}下次闲置这么久后，先 /compact 或 \$effortless handoff 更省。";
}
sub swamp_text {
  my ($percent, $tokens) = @_;
  return sprintf('effortless: 对话臃肿 — 上下文已用 %d%%（约 %s tokens），每条消息都要重读这些内容。可以 /compact 或 $effortless handoff。', $percent + 0.5, ktokens($tokens));
}
# A usage window running hot: {minutes, pct, resets}.
sub hot_text {
  my $top = shift;
  my $reset = $top->{resets} ? '，' . clock_of($top->{resets}) . ' 重置' : '';
  my $save = saving() ? '省钱模式已开（Auto 最高 medium）。' : '输入 $effortless save 开启省钱模式：Auto 最高只到 medium，直到额度重置。';
  return sprintf('effortless: %s额度已用 %d%%%s。%s', limit_name($top->{minutes}), $top->{pct}, $reset, $save);
}

# ---------------------------------------------------------------- per-session memory

sub session_state {
  my $sid = shift;
  my $s = read_json("$DATA/sessions/$sid.json") // {};
  return $s;
}
sub save_session_state {
  my ($sid, $s) = @_;
  write_json("$DATA/sessions/$sid.json", $s);
  # Sessions untouched for a week are forgotten.
  if (rand() < 0.05) {
    for my $f (glob("$DATA/sessions/*.json"), glob("$DATA/routed/*")) { unlink $f if -M $f > 7 }
  }
}

sub limit_name { my $m = shift // 0; $m == 300 ? '5 小时' : $m == 10080 ? '每周' : $m % 60 == 0 ? ($m / 60) . ' 小时' : "$m 分钟" }

# The hottest of the usage windows, or nothing.
sub hottest {
  my $t = shift;
  my ($top) = sort { $b->{pct} <=> $a->{pct} } values %{ $t->{limits} };
  return $top;
}

# Running hot is said once per usage window (its length and reset time), and once more when it passes HOT_FINAL.
my $HOT_FINAL = 95;
# To the quarter hour: the reset time Codex reports can shift by seconds between turns.
sub hot_window { my $top = shift; join ' ', $top->{minutes} // 0, $top->{resets} ? int($top->{resets} / 900 + 0.5) : '' }
sub hot_visible {
  my ($top, $said) = @_;
  return 1 if !$said || ($said->{window} // '') ne hot_window($top);
  return $top->{pct} >= $HOT_FINAL && ($said->{pct} // 0) < $HOT_FINAL;
}

# ---------------------------------------------------------------- the hook

sub hook {
  exit 0 if $ENV{EFFORTLESS_JUDGE} || $MODE eq 'off';
  my $raw = do { local $/; <STDIN> } // '';
  my $p = eval { $JSON->decode($raw) } or exit 0;
  my $prompt = $p->{prompt} // '';
  exit 0 if trim($prompt) eq '';
  $session = $p->{session_id} // '-';
  $session =~ s/[^\w.-]//g;
  my $sid = $session ne '' ? $session : 'none';
  my $t = read_transcript($p->{transcript_path});
  spew("$DATA/last-session", $JSON->encode({ id => $sid, transcript => $p->{transcript_path}, at => now() }));
  my $st = session_state($sid);
  $st->{prompts}++;
  my $key = substr(md5_hex(encode_utf8($prompt)), 0, 16);
  my @notes;
  my $model = $p->{model} || $t->{model};
  my $info = model_info($model);
  my $current = $t->{effort} || config_effort() || ($info && $info->{default}) || 'medium';
  my @users = @{ $t->{users} };
  pop @users if @users && $users[-1] eq $prompt;
  my $last_user = $users[-1];
  my $idle = $t->{last_at} ? (now() - $t->{last_at}) / 60 : 0;
  my $cold = $t->{last_at} && $idle >= $COLD_MINUTES;

  # A quick handoff from a cold chat: the chat's model would reread the whole context at full price to write it.
  # Luna writes it from the transcript instead, in the background, as the original has Haiku do. Sent again in the
  # same idle spell, the prompt goes through and the chat's model writes it.
  if ($cold && $prompt =~ /^\s*\$effortless\s+handoff\s*$/i && abs(($st->{cold_handoff_for} // 0) - $t->{last_at}) >= 0.01 && start_handoff_writer($p->{transcript_path})) {
    $st->{cold_handoff_for} = $t->{last_at};
    save_session_state($sid, $st);
    log_row($current, '-', '-', 0, 0, 'cold-handoff');
    say_json({ decision => 'block', reason => "effortless: 对话已冷，快速交接改由 $MODEL 在后台从对话记录写，不让当前模型按全价重读约 " . ktokens($t->{tokens}) . " tokens。输入 /new 开新对话，发送 \$effortless resume 即可接上（还没写完会稍等）。想让当前模型来写，直接回车重发。" });
    exit 0;
  }

  # A chat gone cold: the next message rereads the whole context at full price. Held back once, so /compact or a
  # handoff can come first; sent again (or anything else sent in the same idle spell), it goes through.
  if ($cold && $COLD ne 'off' && !$HIDE{cold} && ($t->{tokens} // 0) >= $COLD_TOKENS && abs(($st->{cold_for} // 0) - $t->{last_at}) >= 0.01) {
    if ($COLD eq 'block') {
      $st->{cold_for} = $t->{last_at};
      save_session_state($sid, $st);
      log_row($current, '-', '-', 0, 0, 'cold-block');
      say_json({ decision => 'block', reason => cold_text($idle, $t->{tokens}, 1) });
      exit 0;
    }
    push @notes, cold_text($idle, $t->{tokens}, 0);
  }

  my $routed = read_json("$DATA/routed/$sid");
  $routed = undef unless $routed && now() - ($routed->{at} // 0) < 120;
  my $handoff_due = 0;
  my $percent = $t->{percent} // 0;
  # effortless's own commands do not count towards the next handoff check, nor get one.
  if (own_command($prompt)) {
  } elsif ($HANDOFF_FROM ne 'off' && $percent >= $HANDOFF_FROM) {
    $st->{since_check}++;
    if ($st->{since_check} >= $HANDOFF_EVERY) { $handoff_due = 1; $st->{since_check} = 0 }
  } else {
    $st->{since_check} = 0;
    $st->{advice} = undef;
  }
  my $evidence = $handoff_due ? handoff_evidence($t->{users}, $t->{last_assistant}, $prompt, $percent, $cold) : undef;

  my ($block, $r, $reason_said);
  if ($routed) {
    # Auto already set this turn's effort (effortless.pl codex, or the Desktop shim on Windows): say what it did.
    $by = $routed->{by} // '-';
    if (($routed->{action} // '') eq 'manual') {
      push @notes, 'effortless: 你手动改了档位，本对话的 Auto 已暂停（你说了算）。输入 $effortless auto 恢复。' unless $st->{manual_said}++;
    } elsif (($routed->{effort} // '') ne ($routed->{previous} // '') && $routed->{effort}) {
      my $why = (!$HIDE{reason} || ($routed->{action} // q{}) eq q{named}) && $routed->{why} ? ' · ' . reason_line($routed->{by}, $routed->{sure}, $routed->{why}) : '';
      $reason_said = 1 if $why;
      push @notes, "effortless: 自动切到 $routed->{effort}（原 " . ($routed->{previous} // '?') . "）$why";
    }
    push @notes, "effortless: $routed->{down}" if $routed->{down} && !$st->{warned}{ $routed->{down} }++;
    log_row($routed->{previous}, $routed->{effort}, $routed->{sure}, $routed->{ms}, $routed->{tokens}, 'auto:' . ($routed->{action} // '-'));
    $r = decide(prompt => $prompt, current => $current, handoff => $evidence, only_handoff => 1) if $evidence;
  } elsif (!auto_on() || ($info && defined $info->{updates} && !$info->{updates})) {
    push @notes, "effortless: $model 不支持在对话中途改档位，Auto 在这个模型上暂停。" if $info && defined $info->{updates} && !$info->{updates} && auto_on() && !$st->{paused_said}++;
    $r = decide(prompt => $prompt, current => $current, handoff => $evidence, only_handoff => 1) if $evidence;
    log_row($current, '-', '-', 0, 0, auto_on() ? 'paused-model' : 'auto-off');
  } elsif (rank($current) < 0) {
    log_row($current, '-', '-', 0, 0, 'unknown-effort');
  } else {
    # No Auto in this session: the judge picks, and the hook says which effort to switch to.
    my $held = read_json("$DATA/held") // {};
    if (($held->{key} // '') eq $key && now() - ($held->{at} // 0) < 900) {
      # A prompt held back, sent again: the advice was seen, so it goes through.
      unlink "$DATA/held";
      log_row($current, '-', '-', 0, 0, 'resent');
    } else {
      $r = decide(prompt => $prompt, current => $current, last_user => $last_user, last_assistant => $t->{last_assistant},
        percent => $percent, supported => $info && $info->{supported}, handoff => $evidence, cwd => $p->{cwd});
      push @notes, "effortless: $r->{down}" if $r->{down} && !$st->{warned}{ $r->{down} }++;
      if ($r->{action} eq 'follow-up' || $r->{action} eq 'command') {
        log_row($current, '-', '-', 0, 0, $r->{action});
      } elsif ($r->{action} eq 'fail') {
        log_row($current, '-', '-', $r->{ms}, $r->{tokens}, "fail:$r->{fail}");
      } else {
        my $gap = rank($r->{effort}) - rank($current);
        my $sure = defined $r->{sure} ? sprintf('%.2f', $r->{sure}) : '-';
        if ($gap == 0) {
          log_row($current, $r->{effort}, $sure, $r->{ms}, $r->{tokens}, 'same');
        } else {
          my $how = $t->{desktop} ? "在输入框旁的推理档位菜单切到 $r->{effort}" : $gap > 0 ? "按 Alt+. 升 $gap 档" : "按 Alt+, 降 " . (-$gap) . " 档";
          my $text = "effortless: 建议 $r->{effort}（当前 $current）— " . reason_line($r->{by}, $r->{sure}, $r->{why});
          $reason_said = 1;
          if ($MODE ne 'warn' && $gap >= $BLOCK_GAP) {
            log_row($current, $r->{effort}, $sure, $r->{ms}, $r->{tokens}, 'block');
            write_json("$DATA/held", { key => $key, at => now() });
            $block = "$text。$how 后直接回车重发（原文还在输入框里，重发会直接放行）。";
          } else {
            log_row($current, $r->{effort}, $sure, $r->{ms}, $r->{tokens}, 'warn');
            push @notes, "$text（$how，对下一条消息生效）";
          }
        }
      }
    }
  }

  # A fresh chat would serve better: said when the advice appears or changes.
  if ($r && $r->{handoff_checked}) {
    my $advice = $r->{handoff};
    if ($advice && ($st->{advice} // '') ne $advice) {
      my $full = $HANDOFF_SKILL ne '' ? "\$$HANDOFF_SKILL" : '$effortless handoff full（检查 git、写 HANDOFF.md）';
      push @notes, "effortless: 建议换个新对话 — $advice。输入 \$effortless handoff（快速）或 $full。";
    }
    $st->{advice} = $advice;
  }

  # Swamped: every message rereads a lot of context. Said again once the context has grown 50k tokens more.
  my $tokens = $t->{tokens} // 0;
  if ($percent >= $SWAMP_AT && !$HIDE{swamp}) {
    if (!defined $st->{swamp_at} || $tokens >= $st->{swamp_at} + 50000) {
      if (!$cold) {
        push @notes, swamp_text($percent, $tokens);
        $st->{swamp_at} = $tokens;
      }
    }
  } else {
    delete $st->{swamp_at};
  }

  # Running hot: a usage window past HOT_AT. Said once for that window, in any chat, and once more at $HOT_FINAL%.
  if (my $top = hottest($t)) {
    if ($top->{pct} >= $HOT_AT && !$HIDE{hot} && hot_visible($top, read_json("$DATA/hot-said"))) {
      push @notes, hot_text($top);
      write_json("$DATA/hot-said", { window => hot_window($top), pct => $top->{pct} });
    }
  }

  if (-e "$DATA/update-available" && !$st->{update_said}++) {
    my $n = trim(slurp("$DATA/update-available"));
    push @notes, "effortless: 有新版本（领先 $n 个提交）。输入 \$effortless update 更新。";
  }
  check_update_later();

  if ($BAR eq 'always') {
    my $effort = $routed ? $routed->{effort} : $current;
    my @bar = ("effortless: $effort");
    push @bar, sprintf('◔ %d%%', $percent + 0.5) if $t->{window};
    push @bar, $cold ? '❄ 缓存已冷' : sprintf('缓存约剩 %d 分钟', $COLD_MINUTES - $idle) if $t->{last_at};
    if (my $top = hottest($t)) { push @bar, sprintf('%s %d%%', limit_name($top->{minutes}), $top->{pct}) }
    # The judge's line, as the original's bar shows it under the effort, unless a note above already said it.
    my ($said) = grep { $_ && ($_->{action} // q{}) =~ /^(judged|named)$/ } $routed, $r;
    push @bar, reason_line($said->{by}, $said->{sure}, $said->{why}) if $said && !$HIDE{reason} && !$reason_said;
    unshift @notes, join(' · ', @bar);
  }

  save_session_state($sid, $st);
  if ($block) { say_json({ decision => 'block', reason => join("\n", @notes, $block) }) }
  elsif (@notes) { say_json({ systemMessage => join("\n", @notes) }) }
  exit 0;
}

sub judge_name { my $b = shift // q{}; $b eq q{jev} ? q{Jev} : $b eq q{named} ? q{你} : q{Luna} }
# The judge's line: who judged, how sure when it said ("Luna 82%：…"), and why. Jev's reason already is its confidence.
sub reason_line {
  my ($by, $sure, $why) = @_;
  my $pct = ($by // q{}) ne q{named} && defined $sure && ($why // q{}) !~ /% sure/ ? sprintf(' %d%%', $sure * 100 + 0.5) : q{};
  return judge_name($by) . $pct . (length($why // q{}) ? "：$why" : q{});
}

# At most every 6 hours, in the background: is the repo the hook was installed from behind its remote?
sub check_update_later {
  return if $UPDATE_CHECK ne 'on';
  my $src = trim(slurp("$CODEX_HOME/effortless/source") // '');
  return unless $src && -d "$src/.git";
  my $stamp = "$DATA/update-checked";
  return if -e $stamp && -M $stamp < 0.25;
  spew($stamp, now());
  my $pid = fork;
  return if !defined $pid || $pid;
  # The child must not hold the hook's output open: Codex waits for it to close.
  setsid();
  open STDIN, '<', '/dev/null'; open STDOUT, '>', '/dev/null'; open STDERR, '>', '/dev/null';
  if (system('git', '-C', $src, 'fetch', '--quiet') == 0) {
    my $n = trim(`git -C '$src' rev-list --count HEAD..\@{u} 2>/dev/null` // '');
    if ($n =~ /^\d+$/ && $n > 0) { spew("$DATA/update-available", $n) } else { unlink "$DATA/update-available" }
  }
  _exit(0);
}

# ---------------------------------------------------------------- commands

sub last_transcript {
  my $l = read_json("$DATA/last-session") // {};
  return $l->{transcript} && -f $l->{transcript} ? $l->{transcript} : undef;
}

sub cmd_stats {
  my $path = last_transcript();
  my $sid = (read_json("$DATA/last-session") // {})->{id} // '';
  if ($path) {
    my $t = read_transcript($path);
    my (%by, $total);
    # Relative cost: input 1, cached input 0.1, output 8 (GPT pricing at the time of writing).
    for my $u (@{ $t->{usage} }) {
      my $e = $t->{turn_effort}{ $u->{turn} // '' } // '?';
      my $cost = ($u->{in} - $u->{cached}) + 0.1 * $u->{cached} + 8 * $u->{out};
      $by{$e}{requests}++;
      $by{$e}{cost} += $cost;
      $by{$e}{turns}{ $u->{turn} // '' } = 1;
      $total += $cost;
    }
    out("本对话（最近一个）：\n");
    if ($total) {
      for my $e (sort { rank($a) <=> rank($b) } keys %by) {
        out(sprintf("  %-7s %3d 轮  %4d 次请求  费用占比 %3d%%\n", $e, scalar(keys %{ $by{$e}{turns} }), $by{$e}{requests}, 100 * $by{$e}{cost} / $total + 0.5));
      }
    } else {
      out("  还没有用量记录。\n");
    }
  }
  my @rows = -s $LOG ? do { open my $f, '<', $LOG; map { chomp; [split /\t/] } <$f> } : ();
  my @mine = grep { ($_->[8] // '') eq $sid } @rows;
  my $judge = sub {
    my $rows = shift;
    my %act; $act{ $_->[6] }++ for @$rows;
    my @timed = grep { ($_->[4] // 0) > 0 } @$rows;
    my ($ms, $tk) = (0, 0); $ms += $_->[4], $tk += $_->[5] for @timed;
    my %judges; $judges{ $_->[7] }++ for grep { ($_->[7] // '-') ne '-' } @$rows;
    out(sprintf("  %d 条消息：%s\n", scalar(@$rows), join('，', map { "$_ $act{$_}" } sort { $act{$b} <=> $act{$a} } keys %act)));
    out(sprintf("  判断器：%s；平均 %.1f 秒、%d tokens\n", join('，', map { judge_name($_) . " $judges{$_}" } sort keys %judges) || '-', $ms / 1000 / @timed, $tk / @timed)) if @timed;
  };
  if (@mine) { out("Auto 在本对话：\n"); $judge->(\@mine) }
  if (@rows) { out("全部记录：\n"); $judge->(\@rows) } else { out("还没有判断记录（$LOG）。\n") }
}

sub cmd_debug {
  out("codex-effortless $VERSION（$HERE）\n");
  out("设置：MODE=$MODE JUDGE=$JUDGE MODEL=$MODEL MIN=$MIN MAX=$MAX BIAS=$BIAS COLD=$COLD/${COLD_MINUTES}分钟 SWAMP_AT=$SWAMP_AT HOT_AT=$HOT_AT HANDOFF_FROM=$HANDOFF_FROM\n");
  out("判断器：Codex 登录上的 $MODEL" . (jev_key() ? '；Jev 先答' : '') . "\n");
  out('Auto：' . (auto_on() ? '开' : '关（$effortless auto 打开）') . '；省钱模式：' . (saving() ? '开' : '关') . "\n");
  my $codex = $CODEX =~ m{/} ? $CODEX : `command -v '$CODEX' 2>/dev/null`;
  out('codex：' . ($CODEX_OK && trim($codex) || "找不到。$NO_CODEX") . "\n");
  if (my $path = last_transcript()) {
    my $t = read_transcript($path);
    out(sprintf("最近对话：模型 %s，档位 %s，上下文 %s / %s（%d%%）%s\n", $t->{model} // '?', $t->{effort} // '?', ktokens($t->{tokens}), ktokens($t->{window}), $t->{percent} + 0.5,
      $t->{desktop} ? '，Codex Desktop' : ''));
    out(sprintf("  上次回答在 %d 分钟前\n", (now() - $t->{last_at}) / 60)) if $t->{last_at};
    out(sprintf("  %s额度 %d%%\n", limit_name($_->{minutes}), $_->{pct})) for sort { $a->{minutes} <=> $b->{minutes} } values %{ $t->{limits} };
  }
  if (-s $LOG) {
    open my $f, '<', $LOG;
    my @l = <$f>;
    out("最近的判断：\n", map { "  $_" } map { decode_utf8($_) } @l[($#l > 4 ? $#l - 4 : 0) .. $#l]);
  }
}

# $effortless cold, swamp, hot, down: an alert's words now, to see it. With the last chat's numbers when there is one.
sub cmd_preview {
  my $kind = shift;
  my $path = last_transcript();
  my $t = $path ? read_transcript($path) : {};
  my $off = $HIDE{$kind} || ($kind eq 'cold' && $COLD eq 'off') ? "（这条提醒现在是关的：EFFORTLESS_HIDE 或 EFFORTLESS_COLD=off）\n" : '';
  out("预览，不是真的提醒：\n");
  if ($kind eq 'cold') {
    my $idle = $t->{last_at} ? (now() - $t->{last_at}) / 60 : 0;
    $idle = $COLD_MINUTES + 5 if $idle < $COLD_MINUTES;
    my $tokens = ($t->{tokens} // 0) >= $COLD_TOKENS ? $t->{tokens} : $COLD_TOKENS + 30000;
    out(cold_text($idle, $tokens, $COLD ne 'warn') . "\n");
    out($COLD eq 'warn' ? "（作为提示附在回复前，消息照常发送）\n" : "（这条消息会被拦下一次）\n");
    out("触发条件：闲置 ${COLD_MINUTES} 分钟以上，且上下文不少于 " . ktokens($COLD_TOKENS) . " tokens。\n");
  } elsif ($kind eq 'swamp') {
    my $percent = ($t->{percent} // 0) >= $SWAMP_AT ? $t->{percent} : $SWAMP_AT + 5;
    my $tokens = $t->{window} ? $t->{window} * $percent / 100 : 180000;
    out(swamp_text($percent, $tokens) . "\n触发条件：上下文用到 ${SWAMP_AT}% 以上，之后每多 50k tokens 再说一次。\n");
  } elsif ($kind eq 'hot') {
    my $top = hottest($t) // {};
    $top = { minutes => $top->{minutes} // 300, resets => $top->{resets}, pct => ($top->{pct} // 0) >= $HOT_AT ? $top->{pct} : $HOT_AT + 5 };
    out(hot_text($top) . "\n触发条件：任一额度用到 ${HOT_AT}% 以上；同一额度窗口只说一次，到 ${HOT_FINAL}% 再说一次。\n");
  } else {
    out('effortless: ' . jev_failure('000') . "\n（Jev 出问题时：Luna 接手判断）\n") if jev_key();
    out("effortless: 判断器没有及时回答，档位保持不变\n（判断器都没答上时：档位不变，消息照常发送）\n");
  }
  out($off);
}

sub cmd_auto {
  my $arg = shift // 'toggle';
  my $on = $arg eq 'on' ? 1 : $arg eq 'off' ? 0 : $arg eq 'status' ? auto_on() : !auto_on();
  if ($on) { unlink "$DATA/auto-off" } else { spew("$DATA/auto-off", now()) }
  # A pause from changing the effort by hand ends too.
  unlink glob("$DATA/routed/*.paused");
  out($on ? "Auto 已打开：每条消息由判断器挑选档位。\n" : "Auto 已关闭：档位由你自己设置，effortless 只做其他提醒。\n");
}

sub cmd_save {
  my $arg = shift // 'toggle';
  my $on = $arg eq 'on' ? 1 : $arg eq 'off' ? 0 : !saving();
  if (!$on) { unlink "$DATA/save-until"; out("省钱模式已关闭。\n"); return }
  my $until = now() + 5 * 3600;
  if (my $path = last_transcript()) { my $top = hottest(read_transcript($path)); $until = $top->{resets} if $top && $top->{resets} && $top->{resets} > now() }
  spew("$DATA/save-until", int $until);
  out('省钱模式已开启：Auto 最高只到 medium，直到 ' . clock_of($until) . "（额度重置）。\n");
}

# Whether $dir is inside a git checkout (a .git folder, or the .git file of a worktree, here or above).
sub in_git_checkout {
  my $dir = shift;
  while ($dir ne '' && $dir ne '/') {
    return 1 if -e "$dir/.git";
    $dir = dirname($dir);
  }
  return 0;
}

sub cmd_config {
  my ($op, $k, @v) = @_;
  my $file = "$HERE/effortless.conf";
  if (($op // '') eq 'set') {
    die "用法：config set EFFORTLESS_XXX 值\n" unless ($k // '') =~ /^EFFORTLESS_[A-Z_]+$/;
    my $v = join ' ', @v;
    die "值里不能有换行\n" if $v =~ /[\r\n]/;
    # A key never goes into a conf a git checkout tracks: run the installed copy, or set it as an environment variable.
    die "不写入：$file 在 git 仓库里，key 不能进仓库。请用安装后的 ~/.codex/effortless/effortless.pl 设置，或改用环境变量。\n"
      if $k =~ /KEY$/ && $v ne '' && in_git_checkout($HERE);
    my $text = slurp($file) // '';
    my $line = "$k=\${$k:-$v}";
    $text =~ s/^\s*\Q$k\E=.*$/$line/m or $text .= ($text =~ /\n\z/ || $text eq '' ? '' : "\n") . "$line\n";
    spew($file, $text, 0600);
    out("已设置 $k=$v\n");
    return;
  }
  for my $k (sort keys %conf) { my $v = $k =~ /KEY$/ && $conf{$k} ne '' ? '（已设置，不显示）' : $conf{$k}; out("$k=$v\n") }
}

sub cmd_test {
  my $prompt = join(' ', @_) || 'rename one variable in a single file';
  $prompt = decode_utf8($prompt);
  my $r = decide(prompt => $prompt, current => 'medium', cwd => getcwd());
  if ($r->{action} eq 'command') { out("effortless 自己的命令，不判断，档位保持 $r->{effort}\n"); return }
  if ($r->{action} =~ /^(judged|named)$/) { out(sprintf("%s 回答：%s（%s，%.1f 秒）%s\n", judge_name($r->{by}), $r->{effort}, defined $r->{sure} ? sprintf('%.0f%% 把握', $r->{sure} * 100) : '没说把握', $r->{ms} / 1000, $r->{why} ? " — $r->{why}" : '')) }
  else { out('判断失败：' . ($r->{fail} // $r->{action}) . ($r->{down} ? "（$r->{down}）" : '') . "\n"); exit 1 }
}

sub cmd_handoff_save {
  my $text = do { local $/; <STDIN> } // '';
  die "没有收到交接内容\n" if trim($text) eq '';
  spew("$DATA/handoff.md", $text, 0600);
  out("交接已保存（$DATA/handoff.md）。\n");
  if ($HANDOFF_AFTER eq 'copy') { copy_text($text); out("也已复制到剪贴板：粘贴到新对话即可。\n") }
  else { out("下一步：输入 /new 开新对话，然后发送 \$effortless resume。\n") }
}

sub cmd_handoff_show {
  # A handoff Luna is still writing from a cold chat: wait a little (the shell tool has a short timeout), then say so.
  my $deadline = now() + 8;
  while (my $w = handoff_writing()) {
    die "Luna 没写成交接（$w->{why}）。回到原来的对话再发一次 \$effortless handoff，由那个对话的模型来写。\n" if $w->{failed};
    if (now() >= $deadline) { out(sprintf("交接还在写（已 %d 秒）。稍等十几秒再运行一次 resume。\n", now() - $w->{at})); exit 3 }
    sleep 1;
  }
  my $text = slurp("$DATA/handoff.md");
  die "没有保存的交接\n" unless defined $text;
  my $ask = $HANDOFF_AFTER eq 'confirm'
    ? 'Read this, say in two lines where things stand and what is next, then wait for me.'
    : 'Continue with the next step. If it is marked "needs user", say what you need and wait.';
  out("Handoff from the previous chat:\n\n", decode_utf8($text), "\n\n$ask\n");
}

# ---------------------------------------------------------------- the handoff from a cold chat

my $HANDOFF_PROMPT = join "\n",
  'Write a handoff so this work can continue in a fresh chat that has no other context.',
  '',
  'Start with the project, its folder and the branch. Then:',
  '- Goal: one or two lines.',
  '- Done: what changed, with file paths, and how each change was checked. Never present something planned, skipped or untested as done.',
  '- Not done: what is half done, and the concrete blocker (a failed check, a missing approval, an open question).',
  '- Git: local changes, local commits, pushed commits and open PRs, as last seen in this chat. You cannot check now, so say "as of last check".',
  '- Next steps in priority order. Make the first one runnable: a file path, a command or a specific decision. Mark every step that needs the user with "needs user".',
  "- To resume: the start command, the preview URL, and the limits on what is allowed (what needs the user's approval, test vs production).",
  '- Do not redo: decisions made and why, approaches that failed.',
  '',
  'Give only the final state of anything that changed during the chat. Point to specs, plans and files instead of '
    . 'copying them. Leave out what is finished and no longer matters. Never include secrets, environment values or raw '
    . 'logs. Write in the language the user writes in. Short bullets, at most about 40 lines. Do not use tools. Reply '
    . 'with the handoff only, no preamble or farewell.';
my $COMPACT_TAIL = 6;

# The transcript as plain text: every message whole, tool calls and results cut short except in the last few messages.
sub compact_transcript {
  my ($msgs, $tool_chars, $tail_chars) = @_;
  my $short = sub { my ($s, $n) = @_; length($s) > $n ? substr($s, 0, $n) . ' …[' . (length($s) - $n) . ' more characters]' : $s };
  my @said = grep { $msgs->[$_]{role} =~ /^(user|assistant)$/ } 0 .. $#$msgs;
  my $tail_from = @said > $COMPACT_TAIL ? $said[-$COMPACT_TAIL] : 0;
  my @out;
  for my $i (0 .. $#$msgs) {
    my ($role, $text) = @{ $msgs->[$i] }{qw(role text)};
    my $in_tail = $i >= $tail_from;
    if ($role eq 'tool') { push @out, '  [' . $short->($text, $in_tail ? $tail_chars : 400) . ']' }
    elsif ($role eq 'result') { push @out, '  → ' . $short->($text, $in_tail ? $tail_chars : $tool_chars) }
    else { push @out, "\n" . ($role eq 'user' ? 'USER' : 'CODEX') . ': ' . trim($text) }
  }
  return trim(join "\n", @out);
}
# Roughly: four characters of ASCII to a token, one of anything else.
sub est_tokens { my $s = shift; my $wide = () = $s =~ /[^\x00-\x7f]/g; (length($s) - $wide) / 4 + $wide }

sub handoff_writing {
  my $w = read_json("$DATA/handoff-writing") or return undef;
  return $w if $w->{failed} || now() - ($w->{at} // 0) < 200;
  unlink "$DATA/handoff-writing";
  return undef;
}

# Starts `handoff-write` on its own, so the hook can answer at once. False when there is no transcript to write from.
sub start_handoff_writer {
  my $path = shift;
  return 0 unless $path && -f $path;
  write_json("$DATA/handoff-writing", { at => now() });
  my $pid = fork;
  return 0 unless defined $pid;
  return 1 if $pid;
  # The child must not hold the hook's output open: Codex waits for it to close.
  setsid();
  open STDIN, '<', '/dev/null'; open STDOUT, '>', '/dev/null'; open STDERR, '>', '/dev/null';
  { exec { $^X } $^X, abs_path($0), 'handoff-write', $path }
  _exit(127);
}

# Luna writes the quick handoff from a chat's transcript (the last chat unless one is named) and saves it.
sub cmd_handoff_write {
  my $path = shift // last_transcript();
  die "找不到对话记录\n" unless $path && -f $path;
  write_json("$DATA/handoff-writing", { at => now() });
  my $t = read_transcript($path, 1);
  my $fail = sub { write_json("$DATA/handoff-writing", { at => now(), failed => 1, why => shift }); die "交接没写成\n" };
  $fail->('对话记录里没有消息') unless @{ $t->{msgs} };
  my $room = 0.75 * ((model_info($MODEL) // {})->{window} || 272000);
  my $text = compact_transcript($t->{msgs}, 2000, 20000);
  $text = compact_transcript($t->{msgs}, 300, 4000) if est_tokens($text) > $room;
  # Still too long: the start of the chat (after its first message) goes first.
  my @msgs = @{ $t->{msgs} };
  while (est_tokens($text) > $room && @msgs > $COMPACT_TAIL + 2) {
    splice @msgs, 1, int(@msgs / 10) || 1;
    $text = compact_transcript([$msgs[0], { role => 'user', text => '[… an earlier part of the chat is left out …]' }, @msgs[1 .. $#msgs]], 300, 4000);
  }
  my $answers = ask_codex([{ system => 'You read a conversation between a user and Codex, an AI coding agent, and write the handoff the user asks for.',
    ask => "$text\n\n---\n$HANDOFF_PROMPT", effort => 'medium' }], 150) // [];
  my $got = trim(($answers->[0] // {})->{text} // '');
  $fail->($failed eq 'spawn' || !$CODEX_OK ? "找不到 codex。$NO_CODEX" : '没有及时写完') if length($got) < 100;
  $got =~ s/^\[effortless-judge\]\s*//;
  spew("$DATA/handoff.md", encode_utf8($got) . "\n", 0600);
  unlink "$DATA/handoff-writing";
  copy_text(encode_utf8($got)) if $HANDOFF_AFTER eq 'copy';
  out("交接已由 $MODEL 写好并保存（$DATA/handoff.md）。输入 /new 开新对话，然后发送 \$effortless resume。\n");
}

sub copy_text {
  my $text = shift;
  for my $tool (['clip.exe'], ['pbcopy'], ['wl-copy'], ['xclip', '-selection', 'clipboard']) {
    next unless trim(`command -v $tool->[0] 2>/dev/null`);
    open my $p, '|-', @$tool or next;
    print $p $text;
    close $p;
    return 1;
  }
  return 0;
}

sub cmd_bench {
  my $file = -f "$HERE/bench/judge-cases.json" ? "$HERE/bench/judge-cases.json" : "$HERE/../bench/judge-cases.json";
  my $j = read_json($file) or die "找不到 bench/judge-cases.json\n";
  # Cases about effort relative to Claude models do not carry over to Codex models.
  my @cases = grep { $_->{kind} ne 'model-relative' } @{ $j->{cases} };
  out(sprintf("%d 个用例，判断器：%s。每个约几秒，请稍候…\n", scalar @cases, jev_key() ? q{Jev + Luna} : q{Luna}));
  my (@answers, %kids);
  my $par = 4;
  for my $i (0 .. $#cases) {
    while (keys %kids >= $par) { my $pid = wait; $answers[ $kids{$pid} ] = read_json("$DATA/tmp/bench-$kids{$pid}.json"); delete $kids{$pid} }
    my $pid = fork;
    if (!$pid) {
      my $c = $cases[$i];
      my ($u) = ($c->{context} // '') =~ /^user: (.*)$/m;
      my ($reply) = ($c->{context} // '') =~ /assistant: (.*)\z/s;
      my $r = decide(prompt => $c->{message}, current => $c->{current}{effort}, last_user => $u, last_assistant => $reply);
      write_json("$DATA/tmp/bench-$i.json", { effort => $r->{action} eq 'fail' ? undef : $r->{raw} // $r->{effort}, ms => $r->{ms}, by => $r->{by}, why => $r->{why} });
      _exit(0);
    }
    $kids{$pid} = $i;
  }
  while ((my $pid = wait) > 0) { $answers[ $kids{$pid} ] = read_json("$DATA/tmp/bench-$kids{$pid}.json") }
  unlink glob("$DATA/tmp/bench-*.json");
  my (%g, @miss, @ms);
  for my $i (0 .. $#cases) {
    my ($c, $ans) = ($cases[$i], $answers[$i] // {});
    my $e = $ans->{effort};
    my $grade = !$e ? 'none' : (grep { $_ eq $e } @{ $c->{ok} }) ? 'hit' : rank($e) < (sort { $a <=> $b } map { rank($_) } @{ $c->{ok} })[0] ? 'under' : 'over';
    $g{all}{$grade}++;
    $g{ $c->{holdout} ? 'held' : 'tuned' }{$grade}++;
    push @ms, $ans->{ms} if $ans->{ms};
    push @miss, sprintf('- %s：答 %s，应为 %s："%s"', $c->{id}, $e // '无', join('/', @{ $c->{ok} }), cut($c->{message}, 50)) if $grade ne 'hit';
  }
  my $pct = sub { my $h = shift; my $n = 0; $n += $_ for values %$h; $n ? sprintf('%d%%（%d）', 100 * ($h->{hit} // 0) / $n + 0.5, $n) : '-' };
  @ms = sort { $a <=> $b } @ms;
  out(sprintf("答对：全部 %s，调优用 %s，留出 %s\n偏低 %d，偏高 %d，无回答 %d，中位耗时 %.1f 秒\n", $pct->($g{all}), $pct->($g{tuned} // {}), $pct->($g{held} // {}),
    $g{all}{under} // 0, $g{all}{over} // 0, $g{all}{none} // 0, @ms ? $ms[@ms / 2] / 1000 : 0));
  out("未答对：\n", join("\n", @miss), "\n") if @miss;
}

sub cmd_update {
  my $src = trim(slurp("$CODEX_HOME/effortless/source") // '');
  die "不知道从哪里安装的（$CODEX_HOME/effortless/source）\n" unless $src && -d "$src/.git";
  system('git', '-C', $src, 'pull', '--ff-only') == 0 or die "git pull 失败\n";
  exec 'bash', "$src/install.sh", '--quiet';
}

# ---------------------------------------------------------------- Auto: the CLI through a proxy

# `effortless.pl codex [args]` starts the Codex CLI on a private app-server it sits in front of:
#
#   codex --remote unix://… (the TUI)  <->  this proxy  <->  codex app-server (stdio)
#
# Everything passes through untouched, except a new prompt's turn/start: the judge picks the effort and the
# proxy writes it into the request, so the turn runs at it and the TUI shows it. Changing the effort yourself
# pauses Auto for that chat, as in the original.
use IO::Socket::UNIX;
use Digest::SHA qw(sha1);
use MIME::Base64 qw(encode_base64);
use File::Temp qw(tempdir);

my $WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

sub ws_frame {
  my ($op, $payload) = @_;
  my $n = length $payload;
  my $head = chr(0x80 | $op);
  $head .= $n < 126 ? chr($n) : $n < 65536 ? chr(126) . pack('n', $n) : chr(127) . pack('Q>', $n);
  return $head . $payload;
}

# Takes complete frames off the front of $$buf: [opcode, payload] each (client frames are masked).
sub ws_frames {
  my $buf = shift;
  my @frames;
  while (length $$buf >= 2) {
    my ($b0, $b1) = unpack 'CC', $$buf;
    my $len = $b1 & 0x7f;
    my $pos = 2;
    if ($len == 126) { return @frames if length $$buf < 4; $len = unpack 'n', substr($$buf, 2, 2); $pos = 4 }
    elsif ($len == 127) { return @frames if length $$buf < 10; $len = unpack 'Q>', substr($$buf, 2, 8); $pos = 10 }
    my $mask = '';
    if ($b1 & 0x80) { return @frames if length $$buf < $pos + 4; $mask = substr($$buf, $pos, 4); $pos += 4 }
    return @frames if length $$buf < $pos + $len;
    my $payload = substr($$buf, $pos, $len);
    substr($$buf, 0, $pos + $len) = '';
    if ($mask ne '') { $payload ^= substr($mask x (int($len / 4) + 1), 0, $len) }
    push @frames, [$b0 & 0x0f, $payload, $b0 & 0x80];
  }
  return @frames;
}

sub input_text {
  my $input = shift // [];
  my @text = map { $_->{text} // '' } grep { ($_->{type} // '') eq 'text' } @$input;
  return join "\n", @text;
}
sub input_attachments {
  my $input = shift // [];
  my %n;
  for (@$input) { my $t = $_->{type} // ''; $n{ $t =~ /image/i ? 'image' : $t =~ /audio/i ? 'audio' : 'file' }++ if $t =~ /image|audio|mention/i }
  return join ', ', map { "$n{$_} $_" . ($n{$_} > 1 ? 's' : '') } sort keys %n;
}

sub proxy_main {
  my @args = @_;
  # serve: no TUI; prints the address and takes one client after another (for tests, or to attach codex yourself).
  my $serve = @args && $args[0] eq '--serve';
  shift @args if $serve;
  die "effortless: leave --remote out; the proxy sets it\n" if grep { /^--remote/ } @args;
  my $dir = tempdir('effortless-XXXXXX', TMPDIR => 1, CLEANUP => 1);
  chmod 0700, $dir;
  my $sock_path = "$dir/proxy.sock";
  my $listener = IO::Socket::UNIX->new(Local => $sock_path, Listen => 1) or die "effortless: cannot listen on $sock_path: $!\n";
  chmod 0600, $sock_path;
  my $tui = $serve ? 0 : fork;
  die "effortless: fork failed\n" unless defined $tui;
  if ($serve) {
    STDOUT->autoflush(1);
    print "unix://$sock_path\n";
  } elsif (!$tui) {
    close $listener;
    { exec { $CODEX } $CODEX, '--remote', "unix://$sock_path", @args }
    print STDERR "effortless: cannot start $CODEX: $!\n";
    print STDERR "effortless: install the Codex CLI with: curl -fsSL https://chatgpt.com/codex/install.sh | sh\n" unless $CODEX_OK;
    _exit(127);
  }
  # Ctrl+C and Ctrl+Z belong to the TUI in the foreground; the proxy stays put until it exits.
  local $SIG{INT} = $serve ? 'DEFAULT' : 'IGNORE';
  local $SIG{QUIT} = $serve ? 'DEFAULT' : 'IGNORE';
  local $SIG{TSTP} = $serve ? 'DEFAULT' : 'IGNORE';
  local $SIG{PIPE} = 'IGNORE';
  my $p = { threads => {}, pending => {}, models => {}, judging => {}, discovery => 'effortless-models-' . int(rand(1e9)) };
  my ($client, $cbuf, $handshaken, $frag, $backend, $bin, $bout, $bbuf) = (undef, '', 0, '', 0, undef, undef, '');
  my $code;
  my $log = sub { open my $f, '>>', "$DATA/proxy.log" or return; print $f scalar(localtime) . ' ' . encode_utf8(shift) . "\n" };
  my $to_client = sub { my $m = shift; return unless $client; my $data = ws_frame(1, ref $m ? $JSON->encode($m) : $m); while (length $data) { my $n = syswrite($client, $data); last unless $n; substr($data, 0, $n) = '' } };
  # Messages go on as they came (raw text) unless the proxy changed them.
  my $to_backend = sub { my $m = shift; print $bin(ref $m ? $JSON->encode($m) : $m, "\n") if $bin };
  $p->{send_client} = $to_client;
  $p->{send_backend} = $to_backend;
  while (1) {
    if ($tui) {
      my $w = waitpid($tui, WNOHANG);
      if ($w == $tui) { $code = $? >> 8; last }
    }
    my $sel = IO::Select->new($listener);
    $sel->add($client) if $client;
    $sel->add($bout) if $bout;
    $sel->add($_->{fh}) for values %{ $p->{judging} };
    for my $fh ($sel->can_read(0.5)) {
      if ($fh == $listener) {
        my $c = $listener->accept or next;
        # One TUI only.
        if ($client) { close $c; next }
        if ($backend) { stop_tree($backend); ($backend, $bin, $bout, $bbuf) = (0, undef, undef, ''); $p->{threads} = {}; $p->{pending} = {} }
        ($client, $cbuf, $handshaken) = ($c, '', 0);
      } elsif ($client && $fh == $client) {
        my $got = sysread($client, $cbuf, 1 << 20, length $cbuf);
        if (!$got) { close $client; $client = undef; next }
        if (!$handshaken) {
          next unless $cbuf =~ s/^(.*?)\r\n\r\n//s;
          my $req = $1;
          my ($key) = $req =~ /^Sec-WebSocket-Key:\s*(\S+)/mi;
          # A browser page cannot reach a unix socket, but say no to anything that looks like one anyway.
          if (!$key || $req =~ /^Origin:/mi) { syswrite($client, "HTTP/1.1 403 Forbidden\r\n\r\n"); close $client; $client = undef; next }
          my $accept = encode_base64(sha1($key . $WS_GUID), '');
          syswrite($client, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: $accept\r\n\r\n");
          $handshaken = 1;
          $log->('client connected');
          ($backend, $bin, $bout) = spawn({}, $CODEX, 'app-server', '--listen', 'stdio://');
          if (!$backend) { $log->('cannot start the app-server'); close $client; $client = undef; next }
        }
        for my $f (ws_frames(\$cbuf)) {
          my ($op, $payload, $fin) = @$f;
          if ($op == 8) { syswrite($client, ws_frame(8, substr($payload, 0, 2))); close $client; $client = undef; last }
          if ($op == 9) { syswrite($client, ws_frame(10, $payload)); next }
          next if $op == 10;
          $frag .= $payload;
          next unless $fin;
          my $text = $frag;
          $frag = '';
          my $m = eval { $JSON->decode($text) };
          if (!$m) { $log->('unreadable client message'); next }
          route_client($p, $m, $text);
        }
      } elsif ($bout && $fh == $bout) {
        my $got = sysread($bout, $bbuf, 1 << 20, length $bbuf);
        if (!$got) {
          $log->('the app-server exited');
          ($bin, $bout) = (undef, undef);
          if ($client) { syswrite($client, ws_frame(8, pack('n', 1011) . 'App-server exited')); close $client; $client = undef }
          next;
        }
        while ($bbuf =~ s/^([^\n]*)\n//) {
          my $line = $1;
          my $m = eval { $JSON->decode($line) };
          if (!$m) { next }
          $to_client->($line) if observe_server($p, $m);
        }
      } else {
        judge_done($p, $fh);
      }
    }
  }
  stop_tree($backend) if $backend;
  close $client if $client;
  unlink $sock_path;
  exit($code // 0);
}

sub thread_state {
  my ($p, $id) = @_;
  $p->{threads}{$id} //= { auto => 1, model => undef, effort => undef, client_effort => undef, last_user => '', last_assistant => '', active => 0 };
}

sub route_client {
  my ($p, $m, $raw) = @_;
  my $method = $m->{method} // '';
  $p->{pending}{ $m->{id} } = { message => $m } if defined $m->{id} && $method;
  if ($method eq 'turn/interrupt') {
    # Interrupted while the judge thinks: the held turn never starts.
    my $tid = $m->{params}{threadId} // '';
    for my $j (values %{ $p->{judging} }) {
      next unless $j->{tid} eq $tid && !$j->{cancelled};
      $j->{cancelled} = 1;
      $p->{send_client}->({ id => $j->{message}{id}, error => { code => -32000, message => 'Turn cancelled before it started' } });
    }
  }
  if ($method eq 'turn/start' && start_judge($p, $m)) { return }
  $p->{send_backend}->($raw // $m);
  # The models and the efforts each takes, asked once the client is set up.
  $p->{send_backend}->({ id => $p->{discovery}, method => 'model/list', params => {} }) if $method eq 'initialized';
}

sub observe_server {
  my ($p, $m) = @_;
  my $req = defined $m->{id} ? $p->{pending}{ $m->{id} } : undef;
  my $method = $req ? $req->{message}{method} // '' : '';
  my $result = $m->{result};
  if ($result && ref $result eq 'HASH' && ($method eq 'model/list' || (defined $m->{id} && $m->{id} eq $p->{discovery}))) {
    for my $model (@{ $result->{data} // [] }) {
      my $info = { supported => [map { $_->{reasoningEffort} } @{ $model->{supportedReasoningEfforts} // [] }], default => $model->{defaultReasoningEffort} };
      $p->{models}{ $model->{model} } = $info if $model->{model};
      $p->{models}{ $model->{id} } = $info if $model->{id};
    }
  }
  if ($result && ref $result eq 'HASH' && $result->{thread} && $method =~ m{^thread/(start|resume|fork)$}) {
    my $s = thread_state($p, $result->{thread}{id});
    $s->{model} = $result->{model} // $req->{message}{params}{model};
    $s->{effort} = $result->{reasoningEffort} // $s->{effort};
    for my $turn (@{ $result->{thread}{turns} // [] }) {
      for my $item (@{ $turn->{items} // [] }) {
        $s->{last_assistant} = tail($item->{text} // '', 2400) if ($item->{type} // '') eq 'agentMessage';
        $s->{last_user} = cut(input_text($item->{content}), 600) if ($item->{type} // '') eq 'userMessage';
      }
    }
  }
  if ($result && $method eq 'turn/start') {
    my $params = $req->{message}{params};
    my $s = thread_state($p, $params->{threadId});
    my $r = $req->{routed} // { model => $params->{model} // $s->{model}, effort => $params->{effort} // $s->{effort} };
    $s->{model} = $r->{model} if $r->{model};
    $s->{effort} = $r->{effort} if $r->{effort};
    $s->{last_user} = cut(input_text($params->{input}), 600);
  }
  if (my $tid = ref $m->{params} eq 'HASH' ? $m->{params}{threadId} : undef) {
    my $s = thread_state($p, $tid);
    my $n = $m->{method} // '';
    $s->{active} = 1 if $n eq 'turn/started';
    $s->{active} = 0 if $n eq 'turn/completed';
    $s->{last_assistant} = tail($m->{params}{item}{text} // '', 2400) if $n eq 'item/completed' && ($m->{params}{item}{type} // '') eq 'agentMessage';
  }
  delete $p->{pending}{ $m->{id} } if defined $m->{id} && !defined $m->{method};
  return !(defined $m->{id} && $m->{id} eq $p->{discovery});
}

# A new prompt: hold its turn/start while the judge decides (in a child, so everything else keeps flowing).
# Gives false when the request should go on untouched.
sub start_judge {
  my ($p, $m) = @_;
  my $params = $m->{params} // {};
  my $tid = $params->{threadId} or return 0;
  my $s = thread_state($p, $tid);
  my $text = input_text($params->{input});
  # Steering, tool continuations and delegated work are not new prompts.
  return 0 if $s->{active} || grep({ $_->{tid} eq $tid } values %{ $p->{judging} }) || $params->{toolOutput} || $params->{parentTurnId} || $params->{rootTurnId};
  return 0 if trim($text) eq '' && !@{ $params->{input} // [] };
  return 0 if $MODE eq 'warn' || $MODE eq 'off' || !auto_on();
  my $settings = ref $params->{collaborationMode} eq 'HASH' ? $params->{collaborationMode}{settings} : undef;
  my $model = ($settings && $settings->{model}) // $params->{model} // $s->{model};
  my $incoming = ($settings && $settings->{reasoning_effort}) // $params->{effort};
  (my $ftid = $tid) =~ s/[^\w.-]//g;
  my $paused_file = "$DATA/routed/$ftid.paused";
  # The effort changed by hand since the last prompt (and not to what Auto set): you win, Auto pauses for this chat.
  my $manual = defined $incoming && defined $s->{client_effort} && $incoming ne $s->{client_effort} && $incoming ne ($s->{effort} // '');
  $s->{client_effort} = $incoming if defined $incoming;
  if ($manual) { $s->{auto} = 0; spew($paused_file, now()) }
  $s->{auto} = 1 if !$s->{auto} && !-e $paused_file;
  my $routed_file = "$DATA/routed/$ftid";
  if (!$s->{auto}) {
    write_json($routed_file, { at => now(), action => 'manual', effort => $incoming, previous => $incoming });
    $s->{effort} = $incoming // $s->{effort};
    return 0;
  }
  my $info = $p->{models}{ $model // '' };
  return 0 unless $info && @{ $info->{supported} };
  my $current = (defined $s->{model} && defined $model && $model eq $s->{model} ? $s->{effort} : undef) // $incoming // $info->{default};
  pipe(my $r, my $w) or return 0;
  my $pid = fork;
  return 0 unless defined $pid;
  if (!$pid) {
    close $r;
    $session = $tid;
    my $d = eval {
      decide(prompt => $text, current => $current, last_user => $s->{last_user}, last_assistant => $s->{last_assistant},
        attachments => input_attachments($params->{input}), supported => $info->{supported}, cwd => $params->{cwd} // getcwd());
    } // { action => 'fail', fail => 'error' };
    print $w $JSON->encode($d);
    close $w;
    _exit(0);
  }
  close $w;
  $p->{judging}{ fileno $r } = { fh => $r, pid => $pid, tid => $tid, file => $routed_file, message => $m, current => $current, model => $model, settings => $settings, buf => '' };
  return 1;
}

sub judge_done {
  my ($p, $fh) = @_;
  my $j = $p->{judging}{ fileno $fh } or return;
  my $got = sysread($fh, $j->{buf}, 65536, length $j->{buf});
  return if $got;
  delete $p->{judging}{ fileno $fh };
  close $fh;
  waitpid($j->{pid}, 0);
  return if $j->{cancelled};
  my $d = eval { $JSON->decode($j->{buf}) } // { action => 'fail', fail => 'error' };
  my $m = $j->{message};
  my $effort = $d->{action} eq 'fail' ? $j->{current} : $d->{effort};
  write_json($j->{file}, { at => now(), effort => $effort, previous => $j->{current}, why => $d->{why}, by => $d->{by}, sure => $d->{sure},
    action => $d->{action}, down => $d->{down}, ms => $d->{ms}, tokens => $d->{tokens} });
  if ($effort) {
    $m->{params}{effort} = $effort;
    # Older clients put the effort in collaborationMode, which wins over params.effort.
    $m->{params}{collaborationMode}{settings}{reasoning_effort} = $effort if $j->{settings};
    $p->{pending}{ $m->{id} }{routed} = { effort => $effort, model => $j->{model} } if defined $m->{id};
  }
  $p->{send_backend}->($m);
}

# ---------------------------------------------------------------- main

sub main {
  my $cmd = shift(@_) // 'hook';
  if ($cmd eq 'hook') { hook() }
  elsif ($cmd eq 'stats' || $cmd eq '--stats') { cmd_stats() }
  elsif ($cmd eq 'debug') { cmd_debug() }
  elsif ($cmd =~ /^(cold|swamp|hot|down)$/) { cmd_preview($cmd) }
  elsif ($cmd eq 'auto') { cmd_auto(@_) }
  elsif ($cmd eq 'save') { cmd_save(@_) }
  elsif ($cmd eq 'config') { cmd_config(@_) }
  elsif ($cmd eq 'test') { cmd_test(@_) }
  elsif ($cmd eq 'handoff-save') { cmd_handoff_save() }
  elsif ($cmd eq 'handoff-show' || $cmd eq 'resume') { cmd_handoff_show() }
  elsif ($cmd eq 'handoff-write') { cmd_handoff_write(@_) }
  elsif ($cmd eq 'copy') { my $t = do { local $/; <STDIN> }; exit(copy_text($t) ? 0 : 1) }
  elsif ($cmd eq 'bench') { cmd_bench() }
  elsif ($cmd eq 'update') { cmd_update() }
  elsif ($cmd eq 'version') { out("codex-effortless $VERSION\n") }
  elsif ($cmd eq 'codex') { proxy_main(@_) }
  else { print STDERR "unknown command: $cmd\n"; exit 2 }
}

main(@ARGV) unless caller;
1;
