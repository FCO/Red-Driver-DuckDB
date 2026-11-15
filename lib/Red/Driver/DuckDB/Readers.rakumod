use Red::Driver::DuckDB::SourceModel;
use Red::Traits;
use Red::Attr::Column;
use JSON::Fast;
use UUID;

unit role Red::Driver::DuckDB::Readers;

sub literal($value --> Str) {
    return 'NULL' unless $value.defined;
    given $value {
        when Bool { $_ ?? 'true' !! 'false' }
        when Int | Rat | Num { die 'Non-finite reader option' unless .Str ~~ /^ <[\d.eE+\-\/]>+ $/; .Str }
        when Str { die 'NUL in reader option' if .contains("\0"); "'" ~ .subst("'", "''", :g) ~ "'" }
        when Positional { '[' ~ .map({ literal($_) }).join(', ') ~ ']' }
        when Associative { '{' ~ .pairs.sort(*.key).map({ literal(.key.Str) ~ ': ' ~ literal(.value) }).join(', ') ~ '}' }
        default { die "Unsupported reader option type: {$value.^name}" }
    }
}
sub ident(Str $name) { '"' ~ $name.subst('"', '""', :g) ~ '"' }


method read-csv($source, |opts) { self.read-source('read_csv', $source, |opts) }
method read-json($source, |opts) { self.read-source('read_json', $source, |opts) }
method read-parquet($source, |opts) { self.read-source('read_parquet', $source, |opts) }
method read-text($source, |opts) { self.read-source('read_text', $source, |opts) }
method read-blob($source, |opts) { self.read-source('read_blob', $source, |opts) }
method read-xlsx($source, |opts) { self.read-source('read_xlsx', $source, |opts) }


method read-source(Str $reader, $source, Str :$name, Bool :$materialize = False, *%options) {
    die 'Source model name must not be empty' if $name.defined && !$name.chars;
    die 'Unknown source reader' unless $reader eq any(<read_csv read_json read_parquet read_text read_blob read_xlsx>);
    die 'Expected a path or list of paths' unless $source ~~ Str || ($source ~~ Positional && $source.elems && $source.all ~~ Str);
    for %options.keys { die "Invalid reader option: $_" unless /^ <[a..zA..Z_]> <[a..zA..Z_0..9]>* $/ }
    my $call = $reader ~ '(' ~ (literal($source), |%options.keys.sort.map({ $_ ~ ' = ' ~ literal(%options{$_}) })).join(', ') ~ ')';
    if $reader eq 'read_xlsx' { self.execute('INSTALL excel'); self.execute('LOAD excel') }
    my @columns = self.schema-reader.rows('DESCRIBE SELECT * FROM ' ~ $call).Array;
    my $table = 'red_source_' ~ UUID.new.Str.subst('-', '', :g);
    my Str $sequence;
    my Bool $sequence-created = False;
    my Bool $object-created = False;
    CATCH {
        default {
            try self.execute('DROP ' ~ ($materialize ?? 'TABLE ' !! 'VIEW ')
                ~ ident($table)) if $object-created;
            try self.execute('DROP SEQUENCE ' ~ ident($sequence)) if $sequence-created;
            .rethrow;
        }
    }
    my %used;
    my %mapping;
    my %complex;
    my @projection;
    my @attributes;
    for @columns -> $column {
        my $original = $column<column_name>.Str;
        my $base = $original.subst(/ <-[a..zA..Z0..9_]> /, '_', :g);
        $base = 'column_' ~ $base unless $base ~~ /^ <[a..zA..Z_]> /;
        $base = 'column_' ~ $base if $base eq any(<new save delete create HOW WHAT WHICH gist Str sql>);
        my $name = $base;
        my $suffix = 2;
        $name = $base ~ '_' ~ $suffix++ while %used{$name}:exists;
        %used{$name} = True;
        %mapping{$name} = $original;
        my $sql-type = $column<column_type>.Str;
        # Ignore quoted STRUCT field names while checking nested MAP key types.
        my $type-shape = $sql-type.subst(/ '"' [ '""' | <-["]> ]* '"' /, '', :g);
        for $type-shape.match(/ 'MAP' \s* '(' \s* (\w+) /, :g) -> $map {
            die "Unsupported MAP key type in source column $original ($sql-type)"
                unless $map[0].Str eq 'VARCHAR';
        }
        my $nested = $sql-type.contains('[') || $sql-type.starts-with('STRUCT(') || $sql-type.starts-with('MAP(') || $sql-type eq 'JSON';
        my $type = $nested ?? Any !! do given $sql-type.uc {
            when 'TINYINT' | 'SMALLINT' | 'INTEGER' | 'BIGINT' | 'HUGEINT' | 'UTINYINT' | 'USMALLINT' | 'UINTEGER' | 'UBIGINT' | 'UHUGEINT' { Int }
            when /^ 'DECIMAL' / { Rat }
            when 'FLOAT' | 'DOUBLE' | 'REAL' { Num }
            when 'BOOLEAN' { Bool }
            when 'DATE' { Date }
            when /^ 'TIMESTAMP' / { DateTime }
            when 'BLOB' { Blob }
            when 'VARCHAR' | 'UUID' | /^ 'ENUM' / { Str }
            default { die "Unsupported source column $original ($sql-type)" }
        };
        %complex{$name} = True if $nested;
        @projection.push(($nested ?? 'to_json(' ~ ident($original) ~ ')' !! ident($original)) ~ ' AS ' ~ ident($name));
        @attributes.push({ :$name, :$type, :$nested, :sql-type($nested ?? 'JSON' !! $sql-type) });
    }
    my $key = 'red_row_id';
    if $materialize {
        my $suffix = 2;
        $key = 'red_row_id_' ~ $suffix++ while %used{$key}:exists;
        $sequence = 'red_seq_' ~ $table ~ '_' ~ $key;
        self.execute('CREATE TEMP SEQUENCE ' ~ ident($sequence));
        $sequence-created = True;
        @projection.unshift('nextval(' ~ literal('red_seq_' ~ $table ~ '_' ~ $key) ~ ') AS ' ~ ident($key));
    }
    self.execute('CREATE TEMP ' ~ ($materialize ?? 'TABLE ' !! 'VIEW ') ~ ident($table) ~ ' AS SELECT ' ~ @projection.join(', ') ~ ' FROM ' ~ $call);
    $object-created = True;
    if $materialize {
        self.execute('ALTER TABLE ' ~ ident($table) ~ ' ALTER COLUMN ' ~ ident($key) ~ ' SET DEFAULT nextval(' ~ literal('red_seq_' ~ $table ~ '_' ~ $key) ~ ')');
        self.execute('ALTER TABLE ' ~ ident($table) ~ ' ADD PRIMARY KEY (' ~ ident($key) ~ ')');
        @attributes.unshift({ :name($key), :type(Int), :sql-type<BIGINT>, :serial });
    }
    my $model := Red::Driver::DuckDB::SourceModel::SourceHOW.new_type(:name($name // 'DuckDBSource_' ~ $table));
    $model.HOW.source-driver = self;
    $model.HOW.materialized = $materialize;
    $model.HOW.source-mapping = %mapping;
    $model.HOW.complex-columns = %complex;
    $model.^table = $table;
    for @attributes -> %definition {
        my $attr = Attribute.new(:name('$!' ~ %definition<name>), :type(%definition<type>), :package($model), :has_accessor, :rw);
        my %args = :name(%definition<name>), :type(%definition<sql-type>), :nullable;
        %args<id> = True if %definition<serial>;
        %args<auto-increment> = True if %definition<serial>;
        %args<inflate> = -> $v { $v.defined ?? from-json($v.Str) !! Any } if %definition<nested>;
        trait_mod:<is>($attr, :rw);
        trait_mod:<is>($attr, :column(%args));
        $model.^add_attribute($attr);
    }
    $model.^compose;
    $model
}
