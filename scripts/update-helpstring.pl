#!/usr/bin/perl

# Author: Arthur Xiong
# Date: 06/21/2010
# Description: Script to automatically update help string for each
#              node.def according to the inputs

# **** License ****
# Copyright (c) 2019, AT&T Intellectual Property. All rights reserved.
#
# Copyright (c) 2014 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2010-2013 Vyatta, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#
# **** End License ****

use strict;
use warnings;

die "Usage: update-helpstring.pl <helpstring-file> <path-to-template>\n"
  unless @ARGV == 2;

my ( $helpstring_file, $prefix ) = @ARGV;

sub read_lines {
    my ($file) = @_;
    open my $fh, '<', $file or die "$file can't be opened\n";
    my @lines = <$fh>;
    close $fh or die "$file can't be closed\n";
    return @lines;
}

sub write_lines {
    my ( $file, @lines ) = @_;
    open my $fh, '>', $file or die "$file can't be opened\n";
    print {$fh} @lines or die "$file can't be written\n";
    close $fh          or die "$file can't be closed\n";
    return;
}

foreach my $line ( read_lines($helpstring_file) ) {
    chomp $line;
    next if $line =~ m{^(?:\#|\s*$)}x;
    my ( $path, $helpstring ) = $line =~ m{^(\S+) \s+ [|] \s* (\S.*)$}x
      or die "Syntax Error \"$line\"\n";

    my $help_line = "help: $helpstring\n";
    print $help_line;

    my $node_def = "$prefix/$path/node.def";
    my @out      = map { m{^help:}x ? $help_line : $_ } read_lines($node_def);
    write_lines( "$node_def.new", @out );
    rename "$node_def.new", $node_def
      or die "$node_def.new can't be renamed to $node_def\n";

    print "Updated $node_def\n\n";
}
