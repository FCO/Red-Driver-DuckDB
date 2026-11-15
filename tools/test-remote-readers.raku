#!/usr/bin/env raku
# Real S3/HTTPS fixtures using Raku and native command-line tools.
use JSON::Fast;
use UUID;

sub checked(*@command, :%environment = %*ENV, :$capture = False) {
    my $proc = run |@command, :env(%environment), :out($capture ?? True !! $*OUT);
    my $output = $capture ?? $proc.out.slurp(:close) !! '';
    die "Command failed ({$proc.exitcode}): {@command[0]}" if $proc.exitcode;
    $output
}
sub remove-tree(IO::Path $path) {
    if $path.d && !$path.l {
        remove-tree($_) for $path.dir;
        $path.rmdir;
    } else { $path.unlink }
}
sub free-port {
    my $socket = IO::Socket::INET.new(:localhost<127.0.0.1>, :localport(0), :listen)
        // die 'Cannot allocate fixture server port';
    my $port = $socket.localport;
    $socket.close;
    $port
}
sub s3-put(Str $endpoint, Str $path, IO::Path :$file) {
    my @body = $file.defined ?? ('--data-binary', '@' ~ $file.Str) !! ('--data-binary', '');
    checked('curl', '--silent', '--show-error', '--fail-with-body', '--max-time', '20',
        '--retry', '5', '--retry-delay', '1',
        '--aws-sigv4', 'aws:amz:us-east-1:s3',
        '--user', 'red-integration:red-integration-password',
        '--request', 'PUT', |@body, "http://$endpoint$path");
}
sub MAIN() {
    my $project = $?FILE.IO.absolute.IO.parent.parent;
    chdir $project;
    my $name = 'red-readers-' ~ UUID.new.Str.subst('-', '', :g);
    my $root = $*TMPDIR.add($name);
    $root.mkdir;
    my $started = False;
    my $server;
    my $server-finished;
    LEAVE {
        if $server.defined {
            try $server.kill(SIGTERM);
            # Do not sink the terminated Proc: its sink method throws for the
            # intentional SIGTERM even though awaiting the process succeeded.
            try {
                my $finished = await $server-finished;
                $finished.exitcode;
                Nil
            } if $server-finished.defined;
        }
        try {
            my $stopped = run('docker', 'stop', $name, :out(False));
            $stopped.exitcode;
            Nil
        } if $started;
        remove-tree($root) if $root.e;
    }
    my $fixtures = $root.add('data');
    $fixtures.mkdir;
    $fixtures.add('people.csv').spurt("id;name;age\n1;Ana;30\n2;Bruno;17\n");
    my $cert = $root.add('cert.pem');
    my $key = $root.add('key.pem');
    checked('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
        '-keyout', $key.Str, '-out', $cert.Str, '-days', '1', '-subj', '/CN=localhost',
        '-addext', 'subjectAltName=IP:127.0.0.1,DNS:localhost');
    checked($*EXECUTABLE.Str, '-Ilib', 'tools/integration/make-fixtures.raku', $fixtures.Str);
    my $tls-port = free-port;
    # OpenSSL handles TLS; Raku answers HTTP HEAD/GET. OpenSSL's -WWW helper
    # does not implement HEAD, which the DuckDB HTTP filesystem requires.
    $server = Proc::Async.new('openssl', 's_server', '-quiet',
        '-accept', "127.0.0.1:$tls-port", '-cert', $cert.Str, '-key', $key.Str, :w);
    my $request = '';
    my $content = $fixtures.add('people.csv').slurp;
    $server.stdout.tap(-> $text {
        $request ~= $text;
        $request = $request.subst("\r\n", "\n", :g);
        while $request.index("\n\n").defined {
            my $end = $request.index("\n\n");
            my $head = $request.substr(0, $end);
            $request = $request.substr($end + 2);
            my ($method, $path) = $head.lines.head.words;
            note "HTTPS fixture: $method $path";
            my $found = $path eq '/people.csv' && $method eq any(<HEAD GET>);
            my $body = $found ?? $content !! '';
            my $status = $found ?? '200 OK' !! '404 Not Found';
            my $response = "HTTP/1.1 $status\r\nContent-Type: text/csv\r\nContent-Length: {$body.encode.elems}\r\nConnection: close\r\n\r\n";
            $response ~= $body unless $method eq 'HEAD';
            await $server.print($response);
        }
    }, quit => -> $ { });
    $server.stderr.tap(-> $text { $*ERR.print($text) }, quit => -> $ { });
    $server-finished = $server.start(:cwd($fixtures));
    my $image = %*ENV<RED_MINIO_IMAGE>;
    unless $image.defined {
        $image = 'red-duckdb-minio-integration:2025-04-22';
        checked('docker', 'build', '-t', $image, '-f',
            'tools/integration/Dockerfile.minio', 'tools/integration');
    }
    checked('docker', 'run', '--detach', '--rm', '--name', $name,
        '-p', '127.0.0.1::9000', '-e', 'MINIO_ROOT_USER=red-integration',
        '-e', 'MINIO_ROOT_PASSWORD=red-integration-password',
        $image, 'server', '/data');
    $started = True;
    my $info = from-json(checked('docker', 'inspect', $name, :capture));
    my $port = $info[0]<NetworkSettings><Ports>{'9000/tcp'}[0]<HostPort>;
    my $endpoint = "127.0.0.1:$port";
    my $ready = False;
    for ^100 {
        my $probe = run 'curl', '--silent', '--fail', '--max-time', '1',
            "http://$endpoint/minio/health/ready", :out(False), :err(False);
        if $probe.exitcode == 0 { $ready = True; last }
        sleep 0.2;
    }
    die 'MinIO did not become ready' unless $ready;
    s3-put($endpoint, '/red-readers');
    s3-put($endpoint, '/red-readers/sales.parquet', :file($fixtures.add('sales.parquet')));
    my %environment = %*ENV;
    %environment<RED_DUCKDB_S3_ENDPOINT> = $endpoint;
    %environment<RED_DUCKDB_HTTPS_URL> = "https://127.0.0.1:$tls-port";
    %environment<RED_DUCKDB_HTTPS_CERT> = $cert.Str;
    %environment<RED_DUCKDB_REMOTE_FIXTURES> = $fixtures.Str;
    checked('prove6', '-Ilib', 'tools/integration/remote-readers.rakutest', :%environment);
}
