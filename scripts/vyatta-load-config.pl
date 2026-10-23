#!/usr/bin/perl

# Author: Vyatta <eng@vyatta.com>
# Date: 2007
# Description: Perl script for loading config file at run time.

# **** License ****
# Copyright (c) 2019, AT&T Intellectual Property. All rights reserved.
#
# Copyright (c) 2014-2016 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2007-2013 Vyatta, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#
# **** End License ****

# $0: config file.

use strict;
use warnings;
use lib "/opt/vyatta/share/perl5/";
use Sys::Syslog    qw(:standard :macros);
use Vyatta::Config qw(get_short_config_path);

local $SIG{'INT'} = 'IGNORE';

my $etcdir        = $ENV{vyatta_sysconfdir};
my $sbindir       = $ENV{vyatta_sbindir};
my $bootpath      = $etcdir . "/config";
my $url_tmp_file  = $bootpath . "/config.boot.$$";
my %url_protocols = map { $_ => 1 } qw(tftp ftp http scp);

sub fail {
    my ($msg) = @_;
    print "$msg\n";
    exit 1;
}

# Returns (load file, routing instance or undef).
sub parse_args {
    return ( $ARGV[2], $ARGV[1] )
      if @ARGV == 3 && $ARGV[0] eq 'routing-instance';
    return ( $ARGV[0] // "$bootpath/config.boot", undef );
}

# A load file of the form proto://... is a URL; anything else is a path.
sub is_url {
    my ($load_file) = @_;
    return 0 if $load_file !~ m{^[^/]\w+:/}x;
    my ($proto) = $load_file =~ m{^(\w+)://\w}x
      or fail("Invalid url [$load_file]");
    $proto = lc $proto;
    die "Invalid url protocol [$proto]\n" if !$url_protocols{$proto};
    return 1;
}

# Fetches a URL into $url_tmp_file.
sub fetch_url {
    my ( $url, $ri_name ) = @_;
    fail("Package [curl] not installed") if !-f '/usr/bin/curl';
    my @ri = $ri_name ? ("--ri=$ri_name") : ();
    my $rc = system "$sbindir/vyatta-transfer-url", @ri, "--outfile=$url_tmp_file", $url;
    fail("Can not open remote configuration file $url") if $rc;
    return;
}

my ( $orig_load_file, $ri_name ) = parse_args();
my $load_file = $orig_load_file;
if ( is_url($load_file) ) {
    fetch_url( $load_file, $ri_name );
    $load_file = $url_tmp_file;
}
elsif ( $load_file !~ m{^/}x ) {
    $load_file = "$bootpath/$load_file";
}

# log it
openlog( $0, q{}, LOG_USER );
my $login = getlogin() || getpwuid($<) || "unknown";
syslog( "warning", "Load config [$orig_load_file] by $login" );

# do config migration via configd since this script is called by
# unprivileged users directly.
system 'cli-shell-api', 'migrateFile', $load_file;

# when presenting to users, show shortened /config path
my $shortened_load_file = get_short_config_path($load_file);
print "Loading configuration from '$shortened_load_file'...\n";

my $cobj = Vyatta::Config->new();

# "load" => use backend through API
system 'cli-shell-api', 'loadFileReportWarnings', $load_file;
unlink $url_tmp_file if $load_file eq $url_tmp_file;

if ( !$cobj->sessionChanged() ) {
    print "No configuration changes to commit\n";
    exit 0;
}

print "\nLoad complete.  Use 'commit' to make changes active.\n";
exit 0;
