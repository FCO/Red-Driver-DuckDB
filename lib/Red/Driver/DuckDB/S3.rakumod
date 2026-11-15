unit role Red::Driver::DuckDB::S3;

# Secrets are connection-local; never write credentials to DuckDB's persistent
# secrets directory. Keep exceptions deliberately free of SQL and native causes.
method configure-s3(Str :$provider = 'credential_chain',
    Str :$name = 'red_s3', Str :$profile, Str :$region, Str :$endpoint,
    Str :$scope, Str :$url-style, Bool :$use-ssl,
    Str :$key-id, Str :$secret, Str :$session-token) {
    die 'S3 provider must be credential_chain or config'
        unless $provider eq any(<credential_chain config>);
    die 'S3 secret name must be an identifier'
        unless $name ~~ /^ <[A..Za..z_]> <[A..Za..z_0..9]>* $/;
    die 'S3 url-style must be path or vhost'
        if $url-style.defined && $url-style ne any(<path vhost>);
    die 'S3 config provider requires key-id and secret'
        if $provider eq 'config' && (!$key-id.defined || !$secret.defined);
    die 'S3 profile requires credential_chain provider'
        if $profile.defined && $provider ne 'credential_chain';
    die 'S3 explicit credentials require config provider'
        if $provider eq 'credential_chain'
            && ($key-id.defined || $secret.defined || $session-token.defined);
    sub literal(Str:D $value) {
        die 'S3 settings cannot contain NUL' if $value.contains("\0");
        "'" ~ $value.subst("'", "''", :g) ~ "'"
    }
    my @settings = 'TYPE s3', "PROVIDER $provider";
    for (PROFILE => $profile, REGION => $region, ENDPOINT => $endpoint,
        SCOPE => $scope, URL_STYLE => $url-style, KEY_ID => $key-id,
        SECRET => $secret, SESSION_TOKEN => $session-token) -> $setting {
        @settings.push($setting.key ~ ' ' ~ literal($setting.value))
            if $setting.value.defined;
    }
    @settings.push('USE_SSL ' ~ ($use-ssl ?? 'true' !! 'false')) if $use-ssl.defined;
    # Override all Red logging switches while executing credential-bearing SQL.
    my $*RED-DEBUG = False;
    my $*RED-DEBUG-AST = False;
    my $*RED-DEBUG-RESPONSE = False;
    my $failed = False;
    {
        CATCH { default { $failed = True } }
        self.execute('INSTALL httpfs');
        self.execute('LOAD httpfs');
        if $provider eq 'credential_chain' {
            self.execute('INSTALL aws');
            self.execute('LOAD aws');
        }
        self.execute('CREATE OR REPLACE SECRET "' ~ $name ~ '" ('
            ~ @settings.join(', ') ~ ')');
    }
    die 'DuckDB S3 configuration failed; check extensions, credentials and endpoint'
        if $failed;
    self
}
