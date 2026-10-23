# Test stub for the Cstore XS module: the scripts and modules under test
# need Vyatta::Config to load, not a configuration store.
package Cstore;
use strict;
use warnings;

sub new { return bless {}, shift; }

# vyatta-load-config.pl asks whether the load changed the session.
sub sessionChanged { return $ENV{STUB_SESSION_CHANGED} ? 1 : 0; }

1;
