#!/usr/bin/perl
# Tests for scripts/vyatta-transfer-url with a stub vyatta-curl-wrapper and
# a copy whose chvrf path points at a stub.
#
# SPDX-License-Identifier: GPL-2.0-only

use strict;
use warnings;
use File::Temp qw(tempdir);
use FindBin;
use Test::More tests => 13;

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

sub read_file {
    my ($file) = @_;
    open my $fh, '<', $file or return q{};
    local $/ = undef;
    my $content = <$fh>;
    close $fh or BAIL_OUT("cannot close $file: $!");
    return $content;
}

mkdir "$tmp/bin" or BAIL_OUT("mkdir: $!");
my $logger = "printf '%s' \"\$(basename \$0)\" >> '$log'; "
  . "for a; do printf '|%s' \"\$a\" >> '$log'; done; echo >> '$log'\n";
write_file(
    "$tmp/bin/vyatta-curl-wrapper",
    "#!/bin/sh\n$logger"
      . "case \$1 in -q) printf 'HTTP/1.1 %s\\r\\nServer: x\\r\\n' \"\${HTTP_STATUS:-200 OK}\";; esac\n",
    oct 755
);
write_file( "$tmp/chvrf", "#!/bin/sh\n$logger", oct 755 );

my $script = read_file("$port/scripts/vyatta-transfer-url");
$script =~ s{/usr/sbin/chvrf}{$tmp/chvrf}gx or BAIL_OUT('no chvrf path');
write_file( "$tmp/vyatta-transfer-url", $script, oct 755 );

sub transfer {
    my (@args) = @_;
    unlink $log;
    local $ENV{PATH} = "$tmp/bin:$ENV{PATH}";
    my $pid = open my $out, '-|';
    defined $pid or BAIL_OUT("fork: $!");
    if ( !$pid ) {
        open STDERR, '>&', \*STDOUT or exit 126;
        exec $^X, "$tmp/vyatta-transfer-url", @args or exit 127;
    }
    my $text = do { local $/ = undef; <$out> }
      // q{};
    close $out;
    return ( $? >> 8, $text, read_file($log) );
}

my ( $rc, $out, $calls );

( $rc, undef, $calls ) = transfer( '--outfile=/tmp/f', 'scp://h/f' );
is( $calls, "vyatta-curl-wrapper|-#|-o|/tmp/f|scp://h/f\n", 'outfile: download' );

( $rc, undef, $calls ) = transfer( '--infile=/tmp/f', 'ftp://h/f' );
is( $calls, "vyatta-curl-wrapper|-#|-T|/tmp/f|ftp://h/f\n", 'infile: upload' );

( $rc, undef, $calls ) = transfer('tftp://h/f');
is( $calls, "vyatta-curl-wrapper|-#|tftp://h/f\n", 'no file: to stdout' );

( $rc, undef, $calls ) = transfer( '--outfile=/tmp/f', 'http://h/f' );
is( $rc, 0, 'http 200: exit 0' );
is(
    $calls,
    "vyatta-curl-wrapper|-q|-s|-I|http://h/f\n" . "vyatta-curl-wrapper|-#|-o|/tmp/f|http://h/f\n",
    'http 200: header checked, then downloaded'
);

{
    local $ENV{HTTP_STATUS} = '404 Not Found';
    ( $rc, $out, $calls ) = transfer( '--outfile=/tmp/f', 'http://h/f' );
}
isnt( $rc, 0, 'http 404: fails' );
like( $out, qr{^http[ ]error:[ ]\[404\][ ]Not[ ]Found}x, 'http 404: reported' );
is( $calls, "vyatta-curl-wrapper|-q|-s|-I|http://h/f\n", 'http 404: not downloaded' );

( $rc, undef, $calls ) = transfer('http://h/f;touch${IFS}pwned');
is(
    $calls,
    "vyatta-curl-wrapper|-q|-s|-I|http://h/f;touch\${IFS}pwned\n"
      . "vyatta-curl-wrapper|-#|http://h/f;touch\${IFS}pwned\n",
    'http: the URL is one argument, not shell'
);
ok( !-e 'pwned', 'http: the URL is not run by a shell' );
unlink 'pwned';

( $rc, undef, $calls ) = transfer( '--ri=blue', '--infile=/tmp/f', 'scp://h/f' );
is(
    $calls,
    "chvrf|blue|$tmp/vyatta-transfer-url|--infile=/tmp/f|scp://h/f\n",
    'ri: re-run in the routing instance'
);

( $rc, $out ) = transfer('/no/scheme');
isnt( $rc, 0, 'unparseable url: fails' );

( $rc, $out ) = transfer();
like( $out, qr{^Usage:}x, 'no url: usage' );
