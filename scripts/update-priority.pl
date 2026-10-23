#!/usr/bin/perl

# Author: Arthur Xiong
# Date: 04/15/2010
# Description: Script to automatically update/add priority tag with
#              some value for each node.def according to the inputs

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

die "Usage: update-priority.pl <priority-file> <path-to-template>\n"
  unless @ARGV == 2;

my ( $priority_file, $prefix ) = @ARGV;

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

sub is_header       { my ($line) = @_; return $line =~ m{^(?:\#|$)}x }
sub is_priority     { my ($line) = @_; return $line =~ m{^priority:\s\d+}x }
sub is_tag_or_multi { my ($line) = @_; return $line =~ m{^(?:tag|multi):}x }

# Rewrite one node.def: keep the leading comment block and a tag:/multi:
# line, then the new priority line (none for priority 0), then the rest
# of the file without its old priority line.
sub update_node_def {
    my ( $node_def, $priority, $priority_line ) = @_;
    my @in = read_lines($node_def);
    my @out;
    push @out, shift @in while @in && is_header( $in[0] );
    my $first = shift @in;
    push @out, $first         if defined $first && is_tag_or_multi($first);
    push @out, $priority_line if $priority != 0;
    push @out, $first
      if defined $first && !is_priority($first) && !is_tag_or_multi($first);
    push @out, grep { !is_priority($_) } @in;
    write_lines( "$node_def.new", @out );
    rename "$node_def.new", $node_def
      or die "$node_def.new can't be renamed to $node_def\n";
    return;
}

foreach my $line ( read_lines($priority_file) ) {
    chomp $line;
    next if $line =~ m{^(?:\#|$)}x;
    my ( $priority, $path, $comment ) = $line =~ m{^(\d+) \s+ (\S+) (|\s+|\s+\#.*)$}x
      or die "Syntax Error \"$line\"\n";

    my $priority_line = "priority: $priority\t$comment\n";
    print "priority_line: $priority_line";

    my $node_def = "$prefix/$path/node.def";
    print "node_def: $node_def\n";

    update_node_def( $node_def, $priority, $priority_line );
    print "Updated $node_def\n\n";
}
