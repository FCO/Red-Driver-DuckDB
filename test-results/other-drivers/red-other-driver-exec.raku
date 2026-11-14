#!/usr/bin/env raku
# Preload DuckDB, keep raw TAP/diagnostics, and bound each process tree's lifetime.
use JSON::Fast;
use NativeCall;

sub setsid(--> int32) is native { * }
sub kill(int32, int32 --> int32) is native { * }

# The wrapper owns a POSIX session so a timeout also kills grandchildren.
if @*ARGS && @*ARGS[0] eq '--child' {
    @*ARGS.shift;
    die 'Cannot create test session' if setsid() < 0;
    exit run(|@*ARGS).exitcode;
}

unless @*ARGS {
    note 'Usage: red-other-driver-exec.raku [Raku options] TEST';
    exit 2;
}
my $timeout = try +(%*ENV<RED_TEST_TIMEOUT> // '600');
unless $timeout.defined && 0 < $timeout < Inf {
    note 'RED_TEST_TIMEOUT must be a finite positive number of seconds';
    exit 2;
}
my $root = (%*ENV<RED_VALIDATION_ROOT> // "/run/check").IO;
my $results = (%*ENV<RED_TEST_RESULTS> // "/results").IO;
$results.mkdir(:parents);
my $test = @*ARGS[*-1].IO.absolute.IO;
my $kind = %*ENV<BASE_DRIVER> // die "BASE_DRIVER is required";
%*ENV<RED_SOURCE> = $root.add("red").Str;
my @command;
given $kind {
    when "Pg" { @command = "bash", $root.add("pg/tools/pg-test-exec.sh").Str, $test.Str }
    when "MySQL" { @command = $*EXECUTABLE.Str, $root.add("mysql/tools/red-test-exec.raku").Str, $test.Str }
    default {
        %*ENV<RED_DATABASE> = "SQLite";
        @command = $*EXECUTABLE.Str, "-I{$root.add("red/lib")}", $test.Str;
    }
}
my $cwd = $root.add("red");
my @spawn = $*DISTRO.is-win ?? @command !!
    ($*EXECUTABLE.Str, $?FILE.IO.absolute, "--child", |@command);
my $started = now;
my $stdout = Buf.new;
my $stderr = Buf.new;
my $code = 127;
my $child-code;
my $timed-out = False;
try {
    my $process = Proc::Async.new(|@spawn);
    $process.stdout(:bin).tap(-> $bytes { $stdout.append($bytes.list) });
    $process.stderr(:bin).tap(-> $bytes { $stderr.append($bytes.list) });
    my $running = $process.start(:$cwd);
    await Promise.anyof($running, Promise.in($timeout));
    if $running.status ~~ Planned {
        $timed-out = True;
        my $pid = await $process.pid;
        if $*DISTRO.is-win {
            run 'taskkill', '/PID', $pid.Str, '/T', '/F', :!out, :!err;
        } else {
            kill(-$pid, 9);
        }
        try $process.kill(9);
    }
    my $finished = await $running;
    $child-code = $finished.exitcode;
    $code = $timed-out ?? 124 !! $child-code;
    $stdout.append("\nBail out! Per-file timeout\n".encode.list) if $timed-out;
    CATCH { default { $stderr.append((.message ~ "\n").encode.list) } }
}
my $tap = $stdout.decode('utf8-c8');
my regex bailout { ^^ (\h*) 'Bail out!' }
my $bailout = so $tap ~~ /<bailout>/;
$code = 1 if $bailout && $code == 0;
my $prefix = $results.add($test.basename).Str;
spurt "$prefix.tap", $stdout;
spurt "$prefix.stderr.log", $stderr;
spurt "$prefix.log", Buf.new(|$stdout.list,
    |($stderr.elems ?? "\n[stderr]\n".encode.list !! ()), |$stderr.list);
spurt "$prefix.json", to-json({
    file => $test.Str, driver => $kind, exit_code => $code,
    child_exit_code => $child-code, timeout_seconds => $timeout,
    timed_out => $timed-out, :$bailout, seconds => (now - $started).round(.01),
    command => @command.Array,
}) ~ "\n";
$*OUT.write($tap.subst(/<bailout>/, { $<bailout>[0] ~ '# Original Bail out!' }, :g).encode('utf8-c8'));
$*ERR.write($stderr);
exit $code;
