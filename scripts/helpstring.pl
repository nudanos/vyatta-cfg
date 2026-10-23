#!/usr/bin/perl

# Author: Arthur Xiong
# Date: 06/21/2010
# Description: Script to generate Vyatta command help strings from
#              template files

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
use File::Find;

my @command_line;
my $feature_name = q{};

# The first "help:" line of a node.def, as "|<text>", or "" if none.
sub get_parameter {
    my ($file) = @_;
    open my $nd, '<', $file or die "$file can't be opened\n";
    my @help = map { m{^help:\s*(\S.*)$}x ? ($1) : () } <$nd>;
    close $nd or die "$file can't be closed\n";
    return @help ? "|$help[0]" : q{};
}

#
# Generate command with parameter
#
sub wanted {
    return unless $_ eq 'node.def';
    my $parameter = get_parameter($_);

    my $dir = $File::Find::dir;
    return if $dir =~ m{^.*/[.]\S(?:|-)\S*/?.*$}x;
    if ( $feature_name ne q{} ) {
        return unless $dir =~ m{^.*/\Q$feature_name\E(?:|/.*)$}x;
    }

    $dir =~ s{^.*/(?:|\S*-)templates(?:|-(?:cfg|op))/}{}x;
    $dir .= "  $parameter\n";

    push @command_line, $dir;
    return 1;
}

# main program

die "Usage: helpstring.pl <path-to-template> [<feature-name>]\n"
  unless @ARGV == 1 || @ARGV == 2;
my $cfgdir = $ARGV[0];
$feature_name = $ARGV[1] if @ARGV == 2;
die "$cfgdir does not exist!\n" unless -d $cfgdir;

# walk template file tree
find( \&wanted, $cfgdir );

print @command_line;
