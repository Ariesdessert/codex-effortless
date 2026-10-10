#!/usr/bin/env perl
# Drives `effortless.exe app-server --analytics-default-enabled` the way Codex Desktop does (JSON lines over stdio)
# against the real codex.exe and judge, from WSL:
#   1. a simple prompt sent at high runs at what the judge picks (low), and the session records it;
#   2. a follow-up keeps that effort; 3. changing the effort by hand pauses Auto for the chat.
# Usage: perl test/desktop-shim.pl /mnt/c/path/to/effortless.exe   (uses your Codex login; a few real model calls)
use strict;
use warnings;
use IPC::Open2;
use JSON::PP;
use IO::Select;

my $exe = shift or die "usage: $0 /mnt/c/.../effortless.exe\n";
my $J = JSON::PP->new->utf8->canonical;
(my $data = $ENV{EFFORTLESS_DATA} // '') or die "set EFFORTLESS_DATA (and WSLENV=EFFORTLESS_DATA/p)\n";
# The test expects low, whatever your own floor is.
$ENV{EFFORTLESS_MIN} = 'low';
$ENV{EFFORTLESS_MODE} = 'auto';
$ENV{WSLENV} = join ':', grep { length } $ENV{WSLENV} // '', 'EFFORTLESS_MIN', 'EFFORTLESS_MODE';
my $pid = open2(my $out, my $in, $exe, 'app-server', '--analytics-default-enabled') or die;
$in->autoflush(1);
my $sel = IO::Select->new($out);
my $buf = '';
sub send_msg { print $in $J->encode(shift), "\n" }
sub wait_for {
  my ($pred, $t) = @_;
  my $deadline = time + ($t // 60);
  while (time < $deadline) {
    while ($buf =~ s/^([^\n]*)\n//) { my $m = eval { $J->decode($1) } or next; return $m if $pred->($m) }
    next unless $sel->can_read(1);
    sysread($out, $buf, 1 << 20, length $buf) or die "closed\n";
  }
  die "timed out\n";
}
my $bad = 0;
sub check { my ($c, $what) = @_; printf "%s %s\n", $c ? 'ok  ' : 'FAIL', $what; $bad++ unless $c }

send_msg({ id => 1, method => 'initialize', params => { clientInfo => { name => 'effortless-test', title => undef, version => '0' }, capabilities => undef } });
wait_for(sub { ($_[0]{id} // '') eq '1' });
send_msg({ method => 'initialized' });
send_msg({ id => 2, method => 'thread/start', params => { sandbox => 'read-only', approvalPolicy => 'never' } });
my $t = wait_for(sub { ($_[0]{id} // '') eq '2' })->{result};
my $tid = $t->{thread}{id};
print "thread $tid, model $t->{model}\n";
sub turn {
  my ($id, $text, $effort) = @_;
  send_msg({ id => $id, method => 'turn/start', params => { threadId => $tid, effort => $effort, input => [{ type => 'text', text => $text }] } });
  wait_for(sub { ($_[0]{method} // '') eq 'turn/completed' }, 120);
  open my $f, '<', "$data/routed/$tid" or return {};
  local $/;
  return $J->decode(<$f>);
}
my $r1 = turn(3, 'What does the -r flag of cp do? Answer in one short sentence, no tools.', 'high');
check(($r1->{effort} // '') eq 'low', "simple prompt sent at high runs at low (judge: $r1->{effort}, $r1->{why})");
my $r2 = turn(4, 'ok', $r1->{effort});
check(($r2->{action} // '') eq 'follow-up', "follow-up keeps $r2->{effort} ($r2->{action})");
my $r3 = turn(5, 'Now say hi.', 'xhigh');
check(($r3->{action} // '') eq 'manual', "effort changed by hand pauses Auto ($r3->{action})");
my $path = $t->{thread}{path};
if ($path) {
  chomp(my $p = `wslpath -u '$path'`);
  if (open my $f, '<', $p) {
    my @efforts = map { /"type":"turn_context".*?"effort":"([a-z]+)"/ ? $1 : () } <$f>;
    check("@efforts" eq 'low low xhigh', "the session ran at: @efforts");
    close $f;
    unlink $p;   # a test thread, not yours
  }
}
close $in;
waitpid($pid, 0);
exit($bad ? 1 : 0);
