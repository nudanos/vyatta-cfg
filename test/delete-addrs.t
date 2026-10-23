#!/usr/bin/perl
# Tests for scripts/vyatta-delete-addrs.pl with a stub Vyatta::Config and
# a stub vyatta-address that logs its arguments.
#
# SPDX-License-Identifier: GPL-2.0-only

use strict;
use warnings;
use File::Temp qw(tempdir);
use FindBin;
use Test::More tests => 2;

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

open my $in, '<', "$port/scripts/vyatta-delete-addrs.pl"
  or BAIL_OUT("cannot read vyatta-delete-addrs.pl: $!");
my $script = do { local $/ = undef; <$in> };
close $in or BAIL_OUT("cannot close vyatta-delete-addrs.pl: $!");
$script =~ s{/opt/vyatta/sbin/vyatta-address}{$tmp/vyatta-address}x
  or BAIL_OUT('no vyatta-address path');
write_file( "$tmp/delete-addrs.pl", $script );
write_file( "$tmp/vyatta-address",
    "#!/bin/sh\nfor a; do printf '%s|' \"\$a\" >> '$log'; done; echo >> '$log'\n",
    oct 755 );

local $ENV{STUB_TREE} = join "\n",
  '=loopback dataplane',
  '#deleted=bridge',
  'loopback=lo',
  'loopback lo address#deleted=127.0.0.1/8 ::1/128 127a0b0c1/8 10.0.0.1/32',
  'dataplane=dp0s1',
  'dataplane dp0s1 address#deleted=192.0.2.1/24',
  'dataplane dp0s1 vif=10',
  'dataplane dp0s1 vif#deleted=20',
  'dataplane dp0s1 vif 10 address#deleted=198.51.100.1/24',
  'dataplane dp0s1 vif 20 address#deleted=203.0.113.1/24',
  'bridge=br0',
  'bridge br0 address#deleted=2001:db8::1/64';

my $rc = system $^X, "-I$port/test/delete-addrs", "$tmp/delete-addrs.pl";
is( $rc, 0, 'exit 0' );

open my $calls, '<', $log or BAIL_OUT("no calls logged: $!");
my @calls = <$calls>;
close $calls or BAIL_OUT("cannot close $log: $!");
is_deeply(
    \@calls,
    [
        "delete|lo|127a0b0c1/8|\n",          "delete|lo|10.0.0.1/32|\n",
        "delete|dp0s1|192.0.2.1/24|\n",      "delete|dp0s1.10|198.51.100.1/24|\n",
        "delete|dp0s1.20|203.0.113.1/24|\n", "delete|br0|2001:db8::1/64|\n",
    ],
    'deletes removed addresses except the system loopback ones'
);
