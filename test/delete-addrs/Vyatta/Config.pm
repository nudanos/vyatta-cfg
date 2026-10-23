# Test stub for Vyatta::Config: serves the "interfaces" tree described by
# the STUB_TREE environment variable, one "<path>=<values>" entry per line
# with space-separated values. Paths ending in "#deleted" list deleted
# children; "<path> address#deleted" lists deleted addresses.
package Vyatta::Config;
use strict;
use warnings;

sub new { my ( $class, $level ) = @_; return bless { level => $level }, $class; }

sub lookup {
    my ($path) = @_;
    foreach my $entry ( split /\n/x, $ENV{STUB_TREE} // q{} ) {
        my ( $key, $values ) = split /=/x, $entry, 2;
        return split /[ ]/x, $values if $key eq $path;
    }
    return;
}

sub listNodes   { my ( undef, $path ) = @_; return lookup( $path // q{} ); }
sub listDeleted { my ( undef, $path ) = @_; return lookup( ( $path // q{} ) . '#deleted' ); }
sub returnDeletedValues { my ( undef, $path ) = @_; return lookup("$path#deleted"); }

1;
