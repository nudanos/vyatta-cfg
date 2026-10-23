#!/usr/bin/perl

# Author: Vyatta <eng@vyatta.com>
# Date: 2007
# Description: script to save the configuration

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

use strict;
use warnings;
use lib "/opt/vyatta/share/perl5";
use File::Sync qw(fsync);
use Getopt::Long;
use File::Basename;
use File::Temp;
use Vyatta::Config qw(get_short_config_path);

umask 0077;

my $etcdir        = "/opt/vyatta/etc";
my $sbindir       = "/opt/vyatta/sbin";
my $bootpath      = $etcdir . "/config";
my $url_tmp_file  = $bootpath . "/config.boot.$$";
my %url_protocols = map { $_ => 1 } qw(tftp ftp http scp);

sub fail {
    my ($msg) = @_;
    print "$msg\n";
    exit 1;
}

# Returns (save file, routing instance or undef, show defaults).
sub parse_args {
    my $no_defaults;
    GetOptions( 'no-defaults' => \$no_defaults );

    return ( "$bootpath/config.boot", undef,    !$no_defaults ) if !@ARGV;
    return ( $ARGV[0],                undef,    !$no_defaults ) if @ARGV == 1;
    return ( $ARGV[2],                $ARGV[1], !$no_defaults )
      if @ARGV == 3 && $ARGV[0] eq 'routing-instance';
    return fail(
        "Usage: save [routing-instance <ri_name>] " . "[config_file_name] [--no-defaults]" );
}

# A save file of the form proto://... is a URL; anything else is a path.
sub is_url {
    my ($save_file) = @_;
    return 0 if $save_file !~ m{^[^/]\w+:/}x;
    my ($proto) = $save_file =~ m{^(\w+)://\w}x
      or fail("Invalid url [$save_file]");
    $proto = lc $proto;
    fail("Invalid url protocol [$proto]") if !$url_protocols{$proto};
    return 1;
}

sub is_config_file {
    my ($file) = @_;
    open my $fh, '<', $file or return 0;
    my $found = grep { m{[ ]===[ ]vyatta-config-version:}x } <$fh>;
    close $fh or return 0;
    return $found;
}

# Writes the active configuration and the version trailer to $fh.
sub write_config {
    my ( $fh, $name, $show_default ) = @_;
    my @show_cmd = qw(cli-shell-api showConfig --show-active-only
      --show-ignore-edit);
    push @show_cmd, '--show-show-defaults' if $show_default;
    open my $ver_fd, '-|', "$sbindir/vyatta_current_conf_ver.pl"
      or die "Cannot execute vyatta_current_conf_ver.pl\n";
    my $version_str = do { local $/ = undef; <$ver_fd> }
      // q{};
    close $ver_fd;

    open my $show_fd, '-|', @show_cmd
      or die "Cannot execute config output\n";
    while ( my $line = <$show_fd> ) {
        print {$fh} $line
          or die "Failed to write in config file $name: $!\n";
    }
    close $show_fd;
    print {$fh} $version_str
      or die "Failed to write in config file $name: $!\n";
    $fh->flush or die "Failed to write in config file $name: $!\n";
    fsync($fh);
    return;
}

sub save_local {
    my ( $save_file, $show_default ) = @_;
    $save_file = "$bootpath/$save_file" if $save_file !~ m{^/}x;
    print "Saving configuration to '" . get_short_config_path($save_file) . "'...\n";

    # an existing file is only replaced if it is a configuration file
    fail("File exists and is not a Vyatta configuration file, aborting save!")
      if -e $save_file && !is_config_file($save_file);

    my ( undef, $basedir ) = fileparse($save_file);
    my $save = File::Temp->new(
        TEMPLATE => 'tmp_configXXXXXXXX',
        DIR      => $basedir,
        UNLINK   => 1
    ) or die "Failed to create a tmp_config file:$!\n";
    write_config( $save, $save_file, $show_default );
    close $save or die "Failed to close $save: $!\n";
    return if !-s $save->filename;

    rename $save->filename, $save_file
      or die "Failed to rename $save to $save_file: $!\n";
    open my $dir, '<', $basedir
      or die "Failed to open filehandle $basedir: $!\n";
    fsync($dir) or die "Failed to fsync $basedir: $!\n";
    close $dir;
    return;
}

sub save_url {
    my ( $save_file, $ri_name, $show_default ) = @_;
    print "Saving configuration to '$save_file'...\n";
    die "Package [curl] not installed\n" unless -f '/usr/bin/curl';

    open my $save, '>', $url_tmp_file
      or die "Cannot open file '$url_tmp_file': $!\n";
    write_config( $save, $url_tmp_file, $show_default );
    close $save or die "Failed to close $url_tmp_file: $!\n";

    my @ri = $ri_name ? ("--ri=$ri_name") : ();
    my $rc = system "$sbindir/vyatta-transfer-url", @ri, "--infile=$url_tmp_file", $save_file;
    unlink $url_tmp_file;
    fail("Error saving $save_file") if $rc;
    return;
}

my ( $save_file, $ri_name, $show_default ) = parse_args();
if ( is_url($save_file) ) {
    save_url( $save_file, $ri_name, $show_default );
}
else {
    save_local( $save_file, $show_default );
}

print "Done\n";
exit 0;
