#!/usr/bin/env raku
# Install pinned releases using the native curl/tar utilities provided by CI.

sub checked(*@command, IO::Path :$cwd = $*CWD) {
    die "Command failed: {@command.join(' ')}" if run(|@command, :$cwd).exitcode;
}

sub remove-tree(IO::Path $path) {
    if $path.d && !$path.l {
        remove-tree($_) for $path.dir;
        $path.rmdir;
    } else { $path.unlink }
}

sub MAIN(Str $platform = $*DISTRO.is-win ?? 'windows' !! 'macos',
         Str :$archive, Bool :$extract-only = False) {
    die 'Expected windows or macos' unless $platform eq any(<windows macos>);
    my $root = $*TMPDIR.add("red-duckdb-install-{$*PID}-{now.Int}");
    $root.mkdir;
    LEAVE remove-tree($root) if $root.e;
    my $source = $root.add('source');
    $source.mkdir;
    # Keep the archive beside the extraction directory. Git's MSYS tar does not
    # accept native Windows paths in -C; relative paths avoid drive/UNC parsing.
    my $package = $root.add('release.tar.gz');
    if $archive.defined {
        $archive.IO.copy($package);
    } else {
        my $url = $platform eq 'windows'
            ?? 'https://360.zef.pm/D/B_/DB_DUCKDB/68edb89be44b796392325687a17aa4545afa6d98.tar.gz'
            !! 'https://360.zef.pm/A/LI/ALIEN_LIBDUCKDB/616cec8e8469ca04c087236ec2cc9fc0ae42c825.tar.gz';
        checked('curl', '--fail', '--location', '--output', $package.Str, $url);
    }
    # Select by host, including macOS archive fixtures exercised on Windows.
    # Windows bsdtar cannot reliably read the release's Unicode filenames.
    my $tar = $*DISTRO.is-win
        ?? (%*ENV<ProgramFiles> // 'C:\Program Files').IO.add('Git/usr/bin/tar.exe').Str
        !! 'tar';
    die "GNU tar not found: $tar" if $*DISTRO.is-win && !$tar.IO.f;
    if $platform eq 'windows' {
        # Extract only installation inputs. The release's Unicode documentation
        # filenames fail with zef's Windows tar extraction on the hosted runner.
        checked($tar, '-xzf', '../release.tar.gz',
            'META6.json', 'lib', 'resources', :cwd($source));
    } else {
        checked($tar, '-xzf', '../release.tar.gz', :cwd($source));
    }
    sub find-file(IO::Path $path, Str $name) {
        return $path if $path.f && $path.basename eq $name;
        if $path.d {
            for $path.dir -> $child {
                my $found = find-file($child, $name);
                return $found if $found.defined;
            }
        }
        Nil
    }
    my $meta = find-file($source, 'META6.json') // die 'Archive has no META6.json';
    if $platform eq 'macos' {
        my $spec = find-file($source, 'Spec.rakumod') // die 'Alien archive has no Spec.rakumod';
        my $text = $spec.slurp;
        for (
            q[spec-is-win() ?? 'duckdb.dll' !! 'libduckdb.so'] =>
                q[spec-is-win() ?? 'duckdb.dll' !! (spec-is-mac() ?? 'libduckdb.dylib' !! 'libduckdb.so')],
            q[!! ('libduckdb.so', 'libduckdb.so.1')] =>
                q[!! (spec-is-mac() ?? ('libduckdb.dylib',) !! ('libduckdb.so', 'libduckdb.so.1'))]
        ) -> $replacement {
            die 'Alien source changed; review macOS workaround' unless $text.contains($replacement.key);
            $text = $text.subst($replacement.key, $replacement.value, :g);
        }
        $spec.spurt($text);
    }
    my $name = $platform eq 'windows' ?? 'DB::DuckDB' !! 'Alien::Libduckdb';
    my $version = $platform eq 'windows' ?? '1.0.1' !! '1.1.0';
    my $metadata = $meta.slurp;
    die 'Unexpected release' unless $metadata ~~ / '"name"' \s* ':' \s* '"' $name '"' /
        && $metadata ~~ / '"version"' \s* ':' \s* '"' $version '"' /;
    # Useful for checking the exact release extraction without installing it.
    if $extract-only { say "Prepared $name $version" }
    else { checked('zef', 'install', '--/test', $meta.parent.Str) }
}
