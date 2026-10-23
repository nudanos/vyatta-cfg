#!/usr/bin/perl
# Characterization tests for the maintainer tools that edit and read
# node.def templates: update-priority.pl, update-helpstring.pl and
# helpstring.pl.
#
# SPDX-License-Identifier: GPL-2.0-only

use strict;
use warnings;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More tests => 7;

my $scripts = "$FindBin::Bin/../scripts";

sub write_file {
    my ( $file, $content ) = @_;
    open my $fh, '>', $file or BAIL_OUT("cannot write $file: $!");
    print {$fh} $content;
    close $fh or BAIL_OUT("cannot close $file: $!");
    return;
}

sub read_file {
    my ($file) = @_;
    open my $fh, '<', $file or BAIL_OUT("cannot read $file: $!");
    local $/ = undef;
    my $content = <$fh>;
    close $fh or BAIL_OUT("cannot close $file: $!");
    return $content;
}

sub node {
    my ( $root, $path, $content ) = @_;
    make_path("$root/$path");
    write_file( "$root/$path/node.def", $content );
    return;
}

sub run_tool {
    my @cmd = @_;
    my $pid = open my $fh, '-|';
    defined $pid or BAIL_OUT("fork: $!");
    if ( !$pid ) {
        open STDERR, '>&', \*STDOUT or exit 126;
        exec @cmd or exit 127;
    }
    my $out = do { local $/ = undef; <$fh> }
      // q{};
    close $fh;
    return ( $? >> 8, $out );
}

my $tmp = tempdir( CLEANUP => 1 );

# update-priority.pl
{
    my $root = "$tmp/prio";
    node( $root, 'system/ntp',  "# leading comment\n\ntag:\npriority: 100\nhelp: NTP\n" );
    node( $root, 'interfaces',  "help: Interfaces\npriority: 300\nval_help: x\n" );
    node( $root, 'service/ssh', "multi:\nhelp: SSH\n" );
    write_file( "$tmp/prio.txt",
            "# comment line\n\n"
          . "400 system/ntp # after ntp\n"
          . "0 interfaces\n"
          . "250 service/ssh\n" );

    my ( $rc, $out ) = run_tool( $^X, "$scripts/update-priority.pl", "$tmp/prio.txt", $root );
    is( $rc, 0, 'update-priority exits 0' );
    is_deeply(
        [
            read_file("$root/system/ntp/node.def"), read_file("$root/interfaces/node.def"),
            read_file("$root/service/ssh/node.def"),
        ],
        [
            "# leading comment\n\ntag:\npriority: 400\t # after ntp\nhelp: NTP\n",
            "help: Interfaces\nval_help: x\n",
            "multi:\npriority: 250\t\nhelp: SSH\n",
        ],
        'update-priority rewrites, drops and adds priority lines'
    );

    write_file( "$tmp/bad.txt", "high system/ntp\n" );
    ($rc) = run_tool( $^X, "$scripts/update-priority.pl", "$tmp/bad.txt", $root );
    isnt( $rc, 0, 'update-priority rejects a malformed line' );
}

# update-helpstring.pl
{
    my $root = "$tmp/help";
    node( $root, 'system/ntp', "tag:\nhelp: old\npriority: 100\n" );
    write_file( "$tmp/help.txt", "# c\n   \nsystem/ntp | Network Time Protocol\n" );

    my ( $rc, $out ) = run_tool( $^X, "$scripts/update-helpstring.pl", "$tmp/help.txt", $root );
    is( $rc, 0, 'update-helpstring exits 0' );
    is(
        read_file("$root/system/ntp/node.def"),
        "tag:\nhelp: Network Time Protocol\npriority: 100\n",
        'update-helpstring replaces the help line'
    );
}

# helpstring.pl
{
    my $root = "$tmp/gen/templates-cfg";
    node( $root, 'system',     "help: System parameters\n" );
    node( $root, 'system/ntp', "tag:\nhelp: NTP servers\n" );
    node( $root, 'service',    "priority: 10\n" );

    my ( $rc, $out ) = run_tool( $^X, "$scripts/helpstring.pl", $root );
    is( $rc, 0, 'helpstring exits 0' );
    is_deeply(
        [ sort split /\n/x, $out ],
        [ 'service  ', 'system  |System parameters', 'system/ntp  |NTP servers', ],
        'helpstring lists each node with its help string'
    );
}
