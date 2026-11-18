#!/usr/bin/perl
# Tests for scripts/vyatta-save-config.pl. The script runs from a copy
# whose /opt/vyatta paths and curl check point into a temporary tree, with
# stub cli-shell-api, vyatta_current_conf_ver.pl and vyatta-transfer-url.
#
# SPDX-License-Identifier: GPL-2.0-only

use strict;
use warnings;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use Test::More tests => 46;
use Fcntl qw(:flock);
use Time::HiRes qw(sleep);

my $port    = "$FindBin::Bin/..";
my $tmp     = tempdir( CLEANUP => 1 );
my $etc     = "$tmp/etc";
my $config  = "$etc/config";
my $sbin    = "$tmp/sbin";
my $bin     = "$tmp/bin";
my $log     = "$tmp/calls.log";
my $version = "// === vyatta-config-version: \"system\@1\" ===\n";

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

make_path( $config, $sbin, $bin );
write_file(
    "$bin/cli-shell-api",
    "#!/bin/sh\necho \"cli-shell-api \$*\" >> '$log'\n"
      . "printf 'system {\\n    host-name vr\\n}\\n'\n",
    oct 755
);
write_file( "$sbin/vyatta_current_conf_ver.pl", "#!/bin/sh\nprintf '%s' '$version'\n", oct 755 );
write_file(
    "$sbin/vyatta-transfer-url",
    "#!/bin/sh\necho \"transfer \$*\" >> '$log'\n"
      . "for a; do case \$a in --infile=*) cp \"\${a#--infile=}\" '$tmp/sent';; esac; done\n"
      . "exit \${TRANSFER_RC:-0}\n",
    oct 755
);
write_file( "$bin/curl", "#!/bin/sh\n", oct 755 );

my $script = read_file("$port/scripts/vyatta-save-config.pl")
  // BAIL_OUT('cannot read vyatta-save-config.pl');
$script =~ s{"/opt/vyatta/etc"}{"$etc"}x    or BAIL_OUT('no etcdir');
$script =~ s{"/opt/vyatta/sbin"}{"$sbin"}x  or BAIL_OUT('no sbindir');
$script =~ s{'/usr/bin/curl'}{'$bin/curl'}x or BAIL_OUT('no curl check');
$script =~ s{/run/nudanos-startup}{$tmp/startup-lock}g;
write_file( "$tmp/save.pl", $script );

sub save {
    my (@args) = @_;
    unlink $log, "$tmp/sent";
    local $ENV{PATH} = "$bin:$ENV{PATH}";
    my $pid = open my $out, '-|';
    defined $pid or BAIL_OUT("fork: $!");
    if ( !$pid ) {
        open STDERR, '>&', \*STDOUT or exit 126;
        exec $^X, "-I$port/lib", "-I$port/test/lib", "$tmp/save.pl", @args
          or exit 127;
    }
    my $text = do { local $/ = undef; <$out> }
      // q{};
    close $out;
    return ( $? >> 8, $text, read_file($log) // q{} );
}

my $saved = "system {\n    host-name vr\n}\n$version";

{
    my ( $rc, $out, $calls ) = save('saved.boot');
    is( $rc, 0, 'relative name: exit 0' );
    is( read_file("$config/saved.boot"), $saved,
        'relative name: saved under the config directory' );
    is(
        $out,
        "Saving configuration to '$config/saved.boot'...\nDone\n",
        'relative name: progress messages'
    );
    is(
        $calls,
        "cli-shell-api showConfig --show-active-only --show-ignore-edit"
          . " --show-show-defaults\n",
        'defaults are shown by default'
    );
    is( ( stat "$config/saved.boot" )[2] & oct 777, oct 600, 'saved file is private' );
    is_deeply( [ glob "$config/tmp_config*" ], [], 'no temporary file left' );
}

{
    my ( $rc, undef, $calls ) = save( '--no-defaults', "$tmp/abs.boot" );
    is( $rc,                        0,      '--no-defaults: exit 0' );
    is( read_file("$tmp/abs.boot"), $saved, 'absolute name: saved there' );
    unlike( $calls, qr{--show-show-defaults}x, '--no-defaults drops defaults' );
}

{
    write_file( "$config/notes.txt", "not a config\n" );
    my ( $rc, $out, $calls ) = save('notes.txt');
    is( $rc, 1, 'non-config file: exit 1' );
    like( $out, qr{is[ ]not[ ]a[ ]Vyatta[ ]configuration[ ]file}x, 'non-config file: refused' );
    is( read_file("$config/notes.txt"), "not a config\n", 'non-config file: untouched' );
    is( $calls,                         q{}, 'non-config file: configuration not read' );
}

{
    write_file( "$config/my config.boot", "old\n$version" );
    my ( $rc, $out ) = save('my config.boot');
    is( $rc, 0, 'existing config with a space in its name: exit 0' )
      or diag $out;
    is( read_file("$config/my config.boot"),
        $saved, 'existing config with a space in its name: overwritten' );
}

{
    my ( $rc, $out, $calls ) = save('scp://host/backup.boot');
    is( $rc, 0, 'url: exit 0' );
    my ($transfer) = grep { m{^transfer[ ]}x } split /\n/x, $calls;
    my ( $verb, $infile, $url ) = split q{ }, $transfer // q{};
    is_deeply(
        [ $verb,      $url ],
        [ 'transfer', 'scp://host/backup.boot' ],
        'url: handed to vyatta-transfer-url'
    );
    like(
        $infile,
        qr{^--infile=\Q$config\E/config[.]boot[.]\d+$}x,
        'url: sent from a temporary file in the config directory'
    );
    is( read_file("$tmp/sent"), $saved, 'url: transferred content' );
    is_deeply( [ glob "$config/config.boot.*" ], [], 'url: temporary file removed' );
}

{
    my ( $rc, undef, $calls ) = save( 'routing-instance', 'blue', 'tftp://host/b.boot' );
    is( $rc, 0, 'routing-instance url: exit 0' );
    like(
        $calls,
        qr{^transfer[ ]--ri=blue[ ]--infile=\S+[ ]tftp://host/b[.]boot$}mx,
        'routing-instance url: --ri passed'
    );
}

{
    local $ENV{TRANSFER_RC} = 1;
    my ( $rc, $out ) = save('ftp://host/b.boot');
    is( $rc, 1, 'failed transfer: exit 1' );
    like( $out, qr{^Error[ ]saving[ ]ftp://host/b[.]boot$}mx, 'failed transfer: reported' );
}

{
    my ( $rc, $out ) = save('gopher://host/b.boot');
    is( $rc, 1, 'unknown protocol: exit 1' );
    like( $out, qr{Invalid[ ]url[ ]protocol[ ]\[gopher\]}x, 'unknown protocol: reported' );
}

{
    my ($rc) = save( 'a', 'b' );
    is( $rc, 1, 'two arguments: usage error' );
}

{
    mkdir "$tmp/startup-lock", 0700 or BAIL_OUT("mkdir lock: $!");
    open my $lock, '>', "$tmp/startup-lock/startup.lock" or BAIL_OUT("open lock: $!");
    chmod 0600, "$tmp/startup-lock/startup.lock";
    flock($lock, LOCK_EX) or BAIL_OUT("flock: $!");
    unlink $log;
    my $pid = fork(); defined $pid or BAIL_OUT("fork: $!");
    if (!$pid) { close $lock; my ($rc) = save(); write_file("$tmp/writer-status", "$rc"); exit 0 }
    sleep 0.5;
    ok(!-e "$tmp/writer-status", 'startup save waits while lock held');
    ok(!-e $log, 'startup save does not snapshot while lock held');
    close $lock;
    waitpid($pid, 0);
    is(read_file("$tmp/writer-status"), '0', 'startup save completes after lock release');
}
{
    symlink $config, "$tmp/config-alias" or BAIL_OUT("symlink config alias: $!");
    chmod 0644, "$tmp/startup-lock/startup.lock" or BAIL_OUT("chmod lock: $!");
    my ( $rc, $out, $calls ) = save("$tmp/config-alias/config.boot");
    isnt($rc, 0, 'startup directory alias checks lock safety');
    like($out, qr/Unsafe startup lock metadata/, 'unsafe lock metadata reported');
    is($calls, q{}, 'unsafe lock refuses before reading configuration');
    my ($backup_rc) = save('ordinary-backup.boot');
    is($backup_rc, 0, 'unrelated backup does not require startup lock');
    chmod 0600, "$tmp/startup-lock/startup.lock" or BAIL_OUT("restore lock mode: $!");
    unlink "$tmp/startup-lock/startup.lock" or BAIL_OUT("remove test lock: $!");
    symlink '/dev/null', "$tmp/startup-lock/startup.lock" or BAIL_OUT("symlink lock: $!");
    my ( $symlink_rc, undef, $symlink_calls ) = save();
    isnt($symlink_rc, 0, 'startup lock symlink refused');
    is($symlink_calls, q{}, 'symlink refused before configuration read');
    unlink "$tmp/startup-lock/startup.lock" or BAIL_OUT("remove test symlink: $!");
    chmod 0755, "$tmp/startup-lock" or BAIL_OUT("chmod lock directory: $!");
    my ( $dir_rc, undef, $dir_calls ) = save();
    isnt($dir_rc, 0, 'unsafe lock directory refused');
    is($dir_calls, q{}, 'unsafe directory refused before configuration read');
}
{
    chmod 0700, "$tmp/startup-lock" or BAIL_OUT("restore lock directory: $!");
    write_file("$tmp/startup-lock/startup.lock", q{}, 0600);
    link "$tmp/startup-lock/startup.lock", "$tmp/startup-lock/other" or BAIL_OUT("hardlink: $!");
    my ( $rc, undef, $calls ) = save();
    isnt($rc, 0, 'multi-link lock refused');
    is($calls, q{}, 'multi-link lock refused before configuration read');
    unlink "$tmp/startup-lock/other" or BAIL_OUT("remove hardlink: $!");
    open my $lock, '>', "$tmp/startup-lock/startup.lock" or BAIL_OUT("open lock: $!");
    flock($lock, LOCK_EX) or BAIL_OUT("flock: $!");
    my $start = Time::HiRes::time();
    my ( $timeout_rc, $out ) = save();
    my $elapsed = Time::HiRes::time() - $start;
    close $lock;
    isnt($timeout_rc, 0, 'contended startup lock times out');
    like($out, qr/Timed out waiting for startup lock/, 'timeout reported');
    ok($elapsed >= 9 && $elapsed < 15, 'lock timeout bounded near ten seconds');
}
{
    my $alias = "$tmp/racing-alias";
    my $other = "$tmp/other-directory";
    mkdir $other, 0700 or BAIL_OUT("mkdir other directory: $!");
    symlink $config, $alias or BAIL_OUT("symlink racing alias: $!");
    write_file("$config/config.boot", "startup-before\n$version");
    write_file("$other/config.boot", "backup-before\n$version");
    open my $lock, '>', "$tmp/startup-lock/startup.lock" or BAIL_OUT("open lock: $!");
    flock($lock, LOCK_EX) or BAIL_OUT("flock: $!");
    my $pid = fork(); defined $pid or BAIL_OUT("fork: $!");
    if (!$pid) { close $lock; my ($rc) = save("$alias/config.boot"); write_file("$tmp/race-status", "$rc"); exit 0 }
    sleep 0.5;
    unlink $alias or BAIL_OUT("unlink alias: $!");
    symlink $other, $alias or BAIL_OUT("retarget alias: $!");
    close $lock;
    waitpid($pid, 0);
    is(read_file("$tmp/race-status"), '0', 'save succeeds when parent alias is retargeted');
    is(read_file("$config/config.boot"), $saved, 'save stays bound to original startup directory');
    is(read_file("$other/config.boot"), "backup-before\n$version", 'retargeted directory is not modified');
}