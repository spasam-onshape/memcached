#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/lib";
use Carp qw(croak);
use MemcachedTest;
use IO::Socket qw(AF_INET SOCK_STREAM);
use IO::Select;

if (!supports_proxy()) {
    plan skip_all => 'proxy not enabled';
    exit 0;
}

my $t = Memcached::ProxyTest->new(servers => [12191]);

my $p_srv = new_memcached('-o proxy_config=routelib,proxy_arg=./t/proxyroutelibretry.lua -t 1');
my $ps = $p_srv->sock;
$ps->autoflush(1);

$t->set_c($ps);
$t->accept_backends();

sub pstats {
    my $s = $p_srv->new_sock;
    print $s "stats proxy\r\n";
    my %st;
    while (my $line = <$s>) {
        last if $line =~ /^END/;
        $st{$1} = $2 if $line =~ /^STAT (\S+) (\S+)/;
    }
    return \%st;
}

sub active {
    return mem_stats($ps)->{proxy_req_active};
}

subtest 'allasync answers at once, retries reuse the same handle' => sub {
    for my $round (1 .. 3) {
        $t->c_send("delete foo$round\r\n");
        $t->c_recv("NOT_FOUND\r\n", "client answered before the backend");
        $t->be_recv(0, "delete foo$round\r\n", "attempt 1");
        $t->be_send(0, "SERVER_ERROR boom\r\n");
        $t->be_recv(0, "delete foo$round\r\n", "attempt 2 on the same handle");
        $t->be_send(0, "SERVER_ERROR boom\r\n");
        $t->be_recv(0, "delete foo$round\r\n", "attempt 3 on the same handle");
        $t->be_send(0, "DELETED\r\n");
        $t->clear();
    }
    my $st = pstats();
    is($st->{user_retry_main_retries}, 6, "two retries per request");
    is($st->{user_retry_main_recovered}, 3, "every request recovered");
    is($st->{user_retry_main_dropped}, 0, "nothing dropped");
    is($st->{user_retry_inflight}, 0, "no request left in the retry loop");
};

subtest 'retry gives up after the last attempt' => sub {
    $t->c_send("delete bar\r\n");
    $t->c_recv("NOT_FOUND\r\n");
    for my $n (1 .. 4) {
        $t->be_recv(0, "delete bar\r\n", "attempt $n");
        $t->be_send(0, "SERVER_ERROR boom\r\n");
    }
    $t->clear();
    my $st;
    for (1 .. 20) {
        $st = pstats();
        last if $st->{user_retry_main_dropped} == 1;
        select(undef, undef, undef, 0.1);
    }
    is($st->{user_retry_main_dropped}, 1, "dropped after 4 attempts");
    is($st->{user_retry_inflight}, 0, "retry loop finished");
};

subtest 'final results are not retried' => sub {
    $t->c_send("delete baz\r\n");
    $t->c_recv("NOT_FOUND\r\n");
    $t->be_recv(0, "delete baz\r\n");
    $t->be_send(0, "NOT_FOUND\r\n");
    $t->clear();
    my $st = pstats();
    is($st->{user_retry_main_retries}, 9, "no extra retry");
};

subtest 'max_pending: the route waits for its children' => sub {
    $t->c_send("touch foo 10\r\n");
    $t->be_recv(0, "touch foo 10\r\n");
    ok(!$t->wait_c(0.3), "client not answered while the backend is pending");
    $t->be_send(0, "TOUCHED\r\n");
    ok($t->wait_c(2), "client answered after the backend");
    $t->c_recv("NOT_FOUND\r\n");
    $t->clear();
    is(pstats()->{user_allasync_throttled}, 1, "throttled counter");
};

subtest 'retry state survives a reload' => sub {
    my $w = $p_srv->new_sock;
    print $w "watch proxyevents\r\n";
    is(<$w>, "OK\r\n", "watcher enabled");

    # park a request in the retry loop
    $t->c_send("delete qux\r\n");
    $t->c_recv("NOT_FOUND\r\n");
    $t->be_recv(0, "delete qux\r\n", "attempt 1");
    $t->be_send(0, "SERVER_ERROR boom\r\n");
    $t->be_recv(0, "delete qux\r\n", "attempt 2 in flight");
    is(pstats()->{user_retry_inflight}, 1, "one request in the retry loop");

    $p_srv->reload();
    like(<$w>, qr/type=proxy_conf status=start/, "reload started");
    like(<$w>, qr/type=proxy_conf status=done/, "reload completed");

    # 2 active (the retrying delete + this one), 1 of them retrying: not over max_pending = 1
    $t->c_send("decr cnt 1\r\n");
    ok($t->wait_c(1), "answered without waiting: the retrying request is not counted");
    $t->c_recv("NOT_FOUND\r\n");
    $t->be_recv(0, "decr cnt 1\r\n");
    $t->be_send(0, "NOT_FOUND\r\n");
    is(pstats()->{user_allasync_throttled}, 1, "nothing throttled after the reload");

    $t->be_send(0, "DELETED\r\n");
    $t->clear();
    my $st;
    for (1 .. 20) {
        $st = pstats();
        last if $st->{user_retry_inflight} == 0;
        select(undef, undef, undef, 0.1);
    }
    is($st->{user_retry_inflight}, 0, "retry loop finished");
};

subtest 'nothing left active' => sub {
    my $a;
    for (1 .. 20) {
        $a = active();
        last if $a == 0;
        select(undef, undef, undef, 0.1);
    }
    is($a, 0, "proxy_req_active back to 0");
};

done_testing();
