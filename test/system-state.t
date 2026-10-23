#!/usr/bin/perl
# Tests for the vyatta-system-v1 state scripts, run from copies whose
# /proc and /etc paths point at fixtures, with a stub mpstat.
#
# SPDX-License-Identifier: GPL-2.0-only

use strict;
use warnings;
use File::Temp qw(tempdir);
use FindBin;
use JSON;
use Test::More tests => 9;

my $port = "$FindBin::Bin/..";
my $tmp  = tempdir( CLEANUP => 1 );

sub write_file {
    my ( $file, $content, $mode ) = @_;
    open my $fh, '>', $file or BAIL_OUT("cannot write $file: $!");
    print {$fh} $content;
    close $fh or BAIL_OUT("cannot close $file: $!");
    chmod $mode, $file if defined $mode;
    return;
}

# Runs a copy of scripts/$name with each path in %paths replaced by its
# fixture, and returns the decoded JSON it prints.
sub run_state {
    my ( $name, %paths ) = @_;
    open my $in, '<', "$port/scripts/$name" or BAIL_OUT("cannot read $name: $!");
    my $script = do { local $/ = undef; <$in> };
    close $in or BAIL_OUT("cannot close $name: $!");
    while ( my ( $path, $fixture ) = each %paths ) {
        $script =~ s{\Q$path\E}{$fixture}x or BAIL_OUT("$name: no $path");
    }
    write_file( "$tmp/$name", $script );
    local $ENV{PATH} = "$tmp/bin:$ENV{PATH}";
    open my $out, '-|', $^X, "$tmp/$name" or BAIL_OUT("cannot run $name: $!");
    my $json = do { local $/ = undef; <$out> };
    close $out;
    return eval { decode_json($json) } // $json;
}

write_file( "$tmp/meminfo", <<'END' );
MemTotal:        2014464 kB
MemFree:          102400 kB
Active(file):      20480 kB
Active(anon):       1024 kB
Inactive(anon):     2048 kB
Committed_AS:      40960 kB
HugePages_Total:       4
HugePages_Free:        3
Hugepagesize:       2048 kB
DirectMap4k:      200000 kB
END
is_deeply(
    run_state( 'vyatta-system-state-memory', '/proc/meminfo' => "$tmp/meminfo" ),
    {
        'total-memory'           => 2014464 * 1024,
        'free-memory'            => 102400 * 1024,
        'active-file'            => 20480 * 1024,
        'total-committed-memory' => 40960 * 1024,
        anonymous                => { active => 1024 * 1024, inactive => 2048 * 1024 },
        'huge-pages'             => { total  => 4, free => 3, size => 2048 * 1024 },
    },
    'memory: meminfo fields mapped and scaled'
);

write_file( "$tmp/uptime", "350735.47 234388.90\n" );
is_deeply(
    run_state( 'vyatta-system-state-uptime', '/proc/uptime' => "$tmp/uptime" ),
    { uptime => 350735 },
    'uptime: whole seconds'
);

write_file( "$tmp/os-release", <<'END' );
PRETTY_NAME="NuDanOS 2026.10"
NAME="NuDanOS"
VERSION_ID="2026.10"
BUILD_ID=20261022
VYATTA_PROJECT_ID="nudanos"
END
is_deeply(
    run_state( 'vyatta-system-state-platform', '/etc/os-release' => "$tmp/os-release" ),
    {
        'os-version' => '2026.10',
        'os-name'    => 'NuDanOS 2026.10',
        'os-release' => 'nudanos',
    },
    'platform: os-release values, preferring VERSION_ID and PRETTY_NAME'
);

write_file( "$tmp/os-release", "NAME=Debian\nBUILD_ID=7\n" );
is_deeply(
    run_state( 'vyatta-system-state-platform', '/etc/os-release' => "$tmp/os-release" ),
    { 'os-version' => '7', 'os-name' => 'Debian', 'os-release' => 'unknown' },
    'platform: fallbacks'
);

is_deeply(
    run_state( 'vyatta-system-state-platform', '/etc/os-release' => "$tmp/missing" ),
    {
        'os-version' => 'unknown',
        'os-name'    => 'unknown',
        'os-release' => 'unknown',
    },
    'platform: no os-release'
);

mkdir "$tmp/bin" or BAIL_OUT("mkdir: $!");
my @cpus = (
    [qw(all 1.00 0.00 2.00 0.10 0.00 0.20 0.00 0.00 0.00 96.70)],
    [qw(0   1.50 0.00 2.50 0.20 0.00 0.30 0.00 0.00 0.00 95.50)],
);
my @keys = qw(cpu user nice sys iowait irq soft steal guest niced-guest idle);

# One mpstat row as the leaves the script reports.
sub row {
    my ($values) = @_;
    return { map { $keys[$_] => $values->[$_] } 0 .. $#keys };
}
my $expected = { utilization => [ map { row($_) } @cpus ] };
my $head     = "%usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest  %gnice   %idle";

sub mpstat {
    my ( $time, $header_time ) = @_;
    my $out =
      "Linux 6.12.0 (vr) \t10/22/2026 \t_x86_64_\t(1 CPU)\n\n" . "$header_time  CPU    $head\n";
    $out .= "$time  " . join( q{ }, @{$_} ) . "\n" foreach @cpus;
    write_file( "$tmp/bin/mpstat", "#!/bin/sh\ncat <<'X'\n${out}X\n", oct 755 );
    return run_state('vyatta-system-state-utilization');
}

is_deeply( mpstat( '10:17:35 AM', '10:17:35 AM' ), $expected,
    'utilization: 12-hour mpstat output' );
is_deeply( mpstat( '10:17:35', '10:17:35' ), $expected, 'utilization: 24-hour mpstat output' );

my $missing = run_state( 'vyatta-system-state-memory', '/proc/meminfo' => "$tmp/missing" );
ok( !ref $missing, 'memory: unreadable meminfo is not reported as state' );

my $none = run_state( 'vyatta-system-state-uptime', '/proc/uptime' => "$tmp/missing" );
ok( !ref $none, 'uptime: unreadable uptime is not reported as state' );
