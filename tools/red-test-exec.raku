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
    note 'Usage: red-test-exec.raku [Raku options] TEST';
    exit 2;
}
my $timeout = try +(%*ENV<RED_TEST_TIMEOUT> // '180');
unless $timeout.defined && 0 < $timeout < Inf {
    note 'RED_TEST_TIMEOUT must be a finite positive number of seconds';
    exit 2;
}
my $project = $?FILE.IO.absolute.IO.parent.parent;
my $red = (%*ENV<RED_CHECKOUT> // $project.parent.add('Red')).IO.absolute.IO;
my $results = (%*ENV<RED_TEST_RESULTS> // $project.add('test-results/latest')).IO;
$results.mkdir(:parents);
my $test = @*ARGS[*-1].IO.absolute.IO;
my @command = $*EXECUTABLE.Str, "-I{$red.add('lib')}", "-I{$project.add('lib')}",
    '-MRed::Driver::DuckDB', |@*ARGS[0..^@*ARGS.end], $test.Str;
my $cwd = $test.Str.starts-with($red.add('t').Str ~ $*SPEC.dir-sep) ?? $red !! $project;
my @spawn = $*DISTRO.is-win ?? @command !!
    ($*EXECUTABLE.Str, $?FILE.IO.absolute, '--child', |@command);
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
my $combined = Buf.new;
$combined.append($stdout);
$combined.append("\n[stderr]\n".encode) if $stderr.elems;
$combined.append($stderr);
spurt "$prefix.log", $combined;
spurt "$prefix.json", to-json({
    file => $test.Str, driver => %*ENV<RED_DATABASE>, exit_code => $code,
    child_exit_code => $child-code, timeout_seconds => $timeout,
    timed_out => $timed-out, :$bailout, seconds => (now - $started).round(.01),
    command => @command.Array,
}) ~ "\n";
$*OUT.write($tap.subst(/<bailout>/, { $<bailout>[0] ~ '# Original Bail out!' }, :g).encode('utf8-c8'));
$*ERR.write($stderr);
exit $code;
