#!/usr/bin/perl
# Tests for scripts/vyatta-rpc-reboot, run from a copy whose
# vyatta-shutdown.pl path points at a stub.
#
# SPDX-License-Identifier: GPL-2.0-only

use strict;
use warnings;
use File::Temp qw(tempdir);
use FindBin;
use Test::More tests => 8;

my $port = "$FindBin::Bin/..";
my $tmp  = tempdir( CLEANUP => 1 );
my $log  = "$tmp/calls.log";

sub write_file {
    my ( $file, $content, $mode ) = @_;
    open my $fh, '>', $file or BAIL_OUT("cannot write $file: $!");
    print {$fh} $content;
    close $fh or BAIL_OUT("cannot close $file: $!");
    chmod $mode, $file if defined $mode;
    return;
}

write_file(
    "$tmp/vyatta-shutdown.pl",
    "#!/bin/sh\necho \"\$VYATTA_PROCESS_CLIENT\" >> '$log'\n"
      . "for a; do printf '%s|' \"\$a\" >> '$log'; done; echo >> '$log'\n"
      . "echo shutdown says no; exit \${SHUTDOWN_RC:-0}\n",
    oct 755
);

open my $in, '<', "$port/scripts/vyatta-rpc-reboot" or BAIL_OUT("read: $!");
my $script = do { local $/ = undef; <$in> };
close $in or BAIL_OUT("close: $!");
$script =~ s{/opt/vyatta/bin/vyatta-shutdown[.]pl}{$tmp/vyatta-shutdown.pl}x
  or BAIL_OUT('no vyatta-shutdown.pl path');
write_file( "$tmp/rpc-reboot", $script );

sub rpc {
    my ($json) = @_;
    unlink $log;
    write_file( "$tmp/in.json", $json );
    my $pid = open my $outfh, '-|';
    defined $pid or BAIL_OUT("fork: $!");
    if ( !$pid ) {
        open STDIN,  '<',  "$tmp/in.json" or exit 126;
        open STDERR, '>&', \*STDOUT       or exit 126;
        exec $^X, "$tmp/rpc-reboot" or exit 127;
    }
    my $out = do { local $/ = undef; <$outfh> }
      // q{};
    close $outfh;
    my $rc = $? >> 8;
    open my $fh, '<', $log or return ( $rc, $out, q{} );
    my $calls = do { local $/ = undef; <$fh> };
    close $fh or BAIL_OUT("close: $!");
    return ( $rc, $out, $calls );
}

my ( $rc, $out, $calls ) = rpc('{"at":"2026-10-23T05:07:00Z"}');
is( $rc,  0,    'at: exit 0' );
is( $out, '{}', 'at: empty JSON reply' );
is(
    $calls,
    "gui2_rest\n--action|reboot_at|--at_time|05:07 UTC 10/23/26|\n",
    'at: scheduled at the given time, as the REST client'
);

( $rc, $out, $calls ) = rpc('{}');
is( $rc, 0, 'now: exit 0' );
my ( undef, $args ) = split /\n/x, $calls;
my ( $action, $verb, $at, $time ) = split /[|]/x, $args // q{};
is_deeply( [ $action, $verb, $at ], [ '--action', 'reboot_at', '--at_time' ], 'now: scheduled' );
like( $time, qr{^\d\d:\d\d[ ]UTC[ ]\d\d/\d\d/\d\d$}x, 'now: at a time' );

{
    local $ENV{SHUTDOWN_RC} = 1;
    ( $rc, $out ) = rpc('{}');
}
isnt( $rc, 0, 'shutdown failure: fails' );
like( $out, qr{shutdown[ ]says[ ]no}x, 'shutdown failure: its output reported' );
