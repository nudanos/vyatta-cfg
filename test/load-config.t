#!/usr/bin/perl
# Tests for scripts/vyatta-load-config.pl, run from a copy whose curl check
# points into a temporary tree, with stub cli-shell-api and
# vyatta-transfer-url.
#
# SPDX-License-Identifier: GPL-2.0-only

use strict;
use warnings;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use Test::More tests => 20;

my $port   = "$FindBin::Bin/..";
my $tmp    = tempdir( CLEANUP => 1 );
my $etc    = "$tmp/etc";
my $config = "$etc/config";
my $sbin   = "$tmp/sbin";
my $bin    = "$tmp/bin";
my $log    = "$tmp/calls.log";

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
    open my $fh, '<', $file or return;
    local $/ = undef;
    my $content = <$fh>;
    close $fh or BAIL_OUT("cannot close $file: $!");
    return $content;
}

# Each stub logs its name and its arguments separated by '|', so a split
# argument shows up as an extra field.
my $logger = "printf '%s' \"\$(basename \$0)\" >> '$log'; "
  . "for a; do printf '|%s' \"\$a\" >> '$log'; done; echo >> '$log'\n";
make_path( $config, $sbin, $bin );
write_file( "$bin/cli-shell-api", "#!/bin/sh\n$logger", oct 755 );
write_file(
    "$sbin/vyatta-transfer-url",
    "#!/bin/sh\n$logger"
      . "for a; do case \$a in --outfile=*) echo fetched > \"\${a#--outfile=}\";; esac; done\n"
      . "exit \${TRANSFER_RC:-0}\n",
    oct 755
);
write_file( "$bin/curl", "#!/bin/sh\n", oct 755 );

my $script = read_file("$port/scripts/vyatta-load-config.pl")
  // BAIL_OUT('cannot read vyatta-load-config.pl');
$script =~ s{'/usr/bin/curl'}{'$bin/curl'}x or BAIL_OUT('no curl check');
write_file( "$tmp/load.pl", $script );

sub load {
    my (@args) = @_;
    unlink $log;
    local $ENV{PATH}              = "$bin:$ENV{PATH}";
    local $ENV{vyatta_sysconfdir} = $etc;
    local $ENV{vyatta_sbindir}    = $sbin;
    my $pid = open my $out, '-|';
    defined $pid or BAIL_OUT("fork: $!");
    if ( !$pid ) {
        open STDERR, '>&', \*STDOUT or exit 126;
        exec $^X, "-I$port/lib", "-I$port/test/lib", "$tmp/load.pl", @args
          or exit 127;
    }
    my $text = do { local $/ = undef; <$out> }
      // q{};
    close $out;
    return ( $? >> 8, $text, read_file($log) // q{} );
}

# The logged calls of one stub, each as a list of its arguments.
sub calls_of {
    my ( $calls, $name ) = @_;
    my @found;
    foreach my $line ( split /\n/x, $calls ) {
        my ( $stub, @args ) = split /[|]/x, $line, -1;
        push @found, [@args] if $stub eq $name;
    }
    return @found;
}

{
    my ( $rc, $out, $calls ) = load('saved.boot');
    is( $rc, 0, 'relative name: exit 0' );
    is(
        $calls,
        "cli-shell-api|migrateFile|$config/saved.boot\n"
          . "cli-shell-api|loadFileReportWarnings|$config/saved.boot\n",
        'relative name: migrated and loaded from the config directory'
    );
    is(
        $out,
        "Loading configuration from '$config/saved.boot'...\n"
          . "No configuration changes to commit\n",
        'unchanged session: reported'
    );
}

{
    local $ENV{STUB_SESSION_CHANGED} = 1;
    my ( $rc, $out ) = load("$tmp/abs.boot");
    is( $rc, 0, 'changed session: exit 0' );
    my $done = "\nLoad complete.  Use 'commit' to make changes active.\n";
    is( substr( $out, -length $done ), $done, 'changed session: reported' );
}

{
    my ( $rc, undef, $calls ) = load();
    is( $rc, 0, 'no argument: exit 0' );
    is_deeply(
        [ calls_of( $calls, 'cli-shell-api' ) ]->[1],
        [ 'loadFileReportWarnings', "$config/config.boot" ],
        'no argument: loads config.boot'
    );
}

{
    my ( $rc, undef, $calls ) = load('my config.boot');
    is( $rc, 0, 'name with a space: exit 0' );
    is(
        $calls,
        "cli-shell-api|migrateFile|$config/my config.boot\n"
          . "cli-shell-api|loadFileReportWarnings|$config/my config.boot\n",
        'name with a space: passed as one argument'
    );
}

{
    my ( $rc, $out, $calls ) = load('scp://host/backup.boot');
    is( $rc, 0, 'url: exit 0' );
    my ($transfer) = calls_of( $calls, 'vyatta-transfer-url' );
    my ( $outfile, $url ) = @{ $transfer // [] };
    is( $url, 'scp://host/backup.boot', 'url: fetched with vyatta-transfer-url' );
    my ($tmpfile) = ( $outfile // q{} ) =~ m{^--outfile=(.*)}x;
    like(
        $tmpfile // q{},
        qr{^\Q$config\E/config[.]boot[.]\d+$}x,
        'url: fetched into the config directory'
    );
    is_deeply(
        [ calls_of( $calls, 'cli-shell-api' ) ]->[1],
        [ 'loadFileReportWarnings', $tmpfile ],
        'url: the fetched file is loaded'
    );
    ok( !-e $tmpfile, 'url: the fetched file is removed afterwards' );
}

{
    my ( $rc, undef, $calls ) = load( 'routing-instance', 'blue', 'tftp://host/b.boot' );
    is( $rc, 0, 'routing-instance url: exit 0' );
    my ($transfer) = calls_of( $calls, 'vyatta-transfer-url' );
    is_deeply(
        [ @{ $transfer // [] }[ 0, 2 ] ],
        [ '--ri=blue', 'tftp://host/b.boot' ],
        'routing-instance url: --ri passed'
    );
}

{
    local $ENV{TRANSFER_RC} = 1;
    my ( $rc, $out, $calls ) = load('ftp://host/b.boot');
    is( $rc, 1, 'failed transfer: exit 1' );
    is(
        $out,
        "Can not open remote configuration file ftp://host/b.boot\n",
        'failed transfer: reported'
    );
}

{
    my ( $rc, $out ) = load('gopher://host/b.boot');
    isnt( $rc, 0, 'unknown protocol: fails' );
    like( $out, qr{Invalid[ ]url[ ]protocol[ ]\[gopher\]}x, 'unknown protocol: reported' );
}
