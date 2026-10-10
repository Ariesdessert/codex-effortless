#!/usr/bin/env perl
# Drives `effortless.pl codex --serve` the way the Codex TUI does, against a real app-server and judge:
#   1. a simple prompt sent at high runs at what the judge picks (low), and the session records it;
#   2. a follow-up keeps that effort without asking the judge;
#   3. changing the effort by hand pauses Auto for the chat.
# Usage: perl test/auto-proxy.pl   (uses your Codex login; makes a few real model calls)
use strict;
use warnings;
use IO::Socket::UNIX;
use JSON::PP;
use MIME::Base64 qw(encode_base64);
use File::Temp qw(tempdir);
use FindBin;

my $J = JSON::PP->new->utf8->canonical;
my $data = tempdir(CLEANUP => 1);
$ENV{EFFORTLESS_DATA} = $data;
$ENV{EFFORTLESS_MODE} = 'auto';
$ENV{EFFORTLESS_MIN} = 'low';   # the test expects low, whatever your own floor is
my $pid = open(my $srv, '-|', $^X, "$FindBin::Bin/../effortless.pl", 'codex', '--serve') or die "serve: $!";
my $url = <$srv>;
chomp $url;
(my $path = $url) =~ s{^unix://}{};
my $s = IO::Socket::UNIX->new(Peer => $path) or die "connect: $!";
my $key = encode_base64(join('', map { chr rand 256 } 1 .. 16), '');
print $s "GET /rpc HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: $key\r\nSec-WebSocket-Version: 13\r\n\r\n";
my $buf = '';
sysread($s, $buf, 4096, length $buf) until $buf =~ s/^.*?\r\n\r\n//s;
die "no upgrade\n" unless 1;

sub send_msg {
  my $payload = $J->encode(shift);
  my $mask = join '', map { chr rand 256 } 1 .. 4;
  my $n = length $payload;
  my $head = chr(0x81) . ($n < 126 ? chr(0x80 | $n) : $n < 65536 ? chr(0x80 | 126) . pack('n', $n) : chr(0x80 | 127) . pack('Q>', $n));
  syswrite($s, $head . $mask . ($payload ^ substr($mask x ($n / 4 + 1), 0, $n)));
}
sub next_msg {
  my $deadline = time + (shift // 60);
  while (time < $deadline) {
    if (length $buf >= 2) {
      my ($b0, $b1) = unpack 'CC', $buf;
      my ($len, $pos) = ($b1 & 0x7f, 2);
      if ($len == 126) { ($len, $pos) = (unpack('n', substr($buf, 2, 2)), 4) if length $buf >= 4 }
      elsif ($len == 127) { ($len, $pos) = (unpack('Q>', substr($buf, 2, 8)), 10) if length $buf >= 10 }
      if (length $buf >= $pos + $len) {
        my $p = substr($buf, $pos, $len);
        substr($buf, 0, $pos + $len) = '';
        return $J->decode($p) if ($b0 & 0x0f) == 1;
        next;
      }
    }
    my $rin = '';
    vec($rin, fileno $s, 1) = 1;
    select(my $rout = $rin, undef, undef, 1) or next;
    sysread($s, $buf, 1 << 20, length $buf) or die "closed\n";
  }
  die "timed out\n";
}
sub wait_for { my ($pred, $t) = @_; while (1) { my $m = next_msg($t); return $m if $pred->($m) } }
my $ok = 0;
sub check { my ($cond, $what) = @_; printf "%s %s\n", $cond ? 'ok  ' : 'FAIL', $what; $ok++ unless $cond }

send_msg({ id => 1, method => 'initialize', params => { clientInfo => { name => 'effortless-test', title => undef, version => '0' }, capabilities => undef } });
wait_for(sub { ($_[0]{id} // '') eq '1' });
send_msg({ method => 'initialized' });
my $cwd = tempdir(CLEANUP => 1);
send_msg({ id => 2, method => 'thread/start', params => { cwd => $cwd, sandbox => 'read-only', approvalPolicy => 'never' } });
my $t = wait_for(sub { ($_[0]{id} // '') eq '2' })->{result};
my $tid = $t->{thread}{id};
my $rollout = $t->{thread}{path};
print "thread $tid, model $t->{model}\n";

sub turn {
  my ($id, $text, $effort) = @_;
  send_msg({ id => $id, method => 'turn/start', params => { threadId => $tid, effort => $effort, input => [{ type => 'text', text => $text }] } });
  wait_for(sub { ($_[0]{method} // '') eq 'turn/completed' }, 120);
  my $r = $J->decode(do { local $/; open my $f, '<', "$data/routed/$tid" or return {}; <$f> });
  return $r;
}
my $r1 = turn(3, 'What does the -r flag of cp do? Answer in one short sentence, no tools.', 'high');
check(($r1->{effort} // '') eq 'low', "simple prompt sent at high runs at low (judge: $r1->{effort}, $r1->{why})");
# The TUI takes the effort the server ran at, so its next request carries it.
my $r2 = turn(4, 'ok', $r1->{effort});
check(($r2->{action} // '') eq 'follow-up' && ($r2->{effort} // '') eq 'low', "follow-up keeps low ($r2->{action})");
my $r3 = turn(5, 'Now say hi.', 'xhigh');
check(($r3->{action} // '') eq 'manual', "effort changed by hand pauses Auto ($r3->{action})");
if ($rollout && -f $rollout) {
  open my $f, '<', $rollout;
  my @efforts = map { /"type":"turn_context".*?"effort":"([a-z]+)"/ ? $1 : () } <$f>;
  check("@efforts" eq 'low low xhigh', "the session ran at: @efforts");
  unlink $rollout;   # a test thread, not yours
}
kill 'TERM', $pid;
exit($ok ? 1 : 0);
