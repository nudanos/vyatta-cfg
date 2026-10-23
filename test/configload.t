#!/usr/bin/perl
# SPDX-License-Identifier: LGPL-2.1-only
#
# Vyatta::ConfigLoad's command quoting.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../lib", "$FindBin::Bin/../scripts";
use Test::More;
use Vyatta::ConfigLoad;

my @path   = ( "interfaces", "description", "it's", "'quoted'", '"double"' );
my @quoted = Vyatta::ConfigLoad::applySingleQuote(@path);
is_deeply(
    \@quoted,
    [ "'interfaces'", "'description'", "'it'\\''s'", "'quoted'", "'double'" ],
    'each component single-quoted, embedded quotes escaped'
);

# findDeletedNodes and findSetNodes quote the same path for each child: the
# caller's components must come back as they went in
is_deeply(
    \@path,
    [ "interfaces", "description", "it's", "'quoted'", '"double"' ],
    "the caller's list is left alone"
);
my @again = Vyatta::ConfigLoad::applySingleQuote(@path);
is_deeply( \@again, \@quoted, 'quoting the same path twice gives the same result' );

done_testing();
