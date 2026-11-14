use Red::Driver::DuckDB::Migrations;
use Red::Driver::CommonSQL;
use Red::Statement;
use X::Red::Exceptions;
use DB::DuckDB;
use DB::DuckDB::Native;
use DB::DuckDB::Result;
use NativeCall;
use Red::Driver::DuckDB::SQL;
use Red::Driver::DuckDB::SchemaReader;
use Red::AST::Insert;
use Red::Index;
use Red::LockType;
use Red::Type::Json;
use UUID;
use JSON::Fast;
use Red::Driver::DuckDB::JSON;
use Red::Driver::DuckDB::Regex;

unit class Red::Driver::DuckDB does Red::Driver::DuckDB::Migrations does Red::Driver::DuckDB::JSON;

has Str $.database = ':memory:';
has $.dbh;
has $!connection;
has $!migration-lease;
class SessionState {
    has Bool $.transaction is rw = False;
    has Bool $.closed is rw = False;
}
has SessionState $!session-state .= new;
has Lock $.connection-lock .= new;
# A separate transaction owns the lock row while migration transactions commit
# on the primary connection. A conflicting UPDATE fails immediately in DuckDB.
method acquire-migration-lock {
    self.unsupported('This connection already holds a migration lock') if $!migration-lease.defined;
    self.execute('CREATE TABLE IF NOT EXISTS red_migration_lock (id BIGINT PRIMARY KEY, token BIGINT)');
    self.execute('INSERT INTO red_migration_lock VALUES (1, 0) ON CONFLICT DO NOTHING');
    my $lease = $!dbh.connect;
    CATCH {
        default {
            try $lease.rollback;
            $lease.clear-cache;
            $lease.free;
            .rethrow;
        }
    }
    $lease.begin;
    my $result = $lease.query('UPDATE red_migration_lock SET token=token+1 WHERE id=1');
    $result.free;
    $!migration-lease = $lease;
    self
}
method release-migration-lock {
    if $!migration-lease.defined {
        my $lease = $!migration-lease;
        $!migration-lease = Nil;
        LEAVE { $lease.clear-cache; $lease.free }
        $lease.rollback;
    }
    self
}

# Used only for the generated tightening step of a migration. DuckDB cannot
# SET NOT NULL on a table updated earlier in the transaction. Rebuilding within
# that transaction preserves atomicity and lets the new table validate every row.
method migration-set-not-null(Str $table, Str $column) {
    self.unsupported('DuckDB table reconstruction requires an explicit transaction')
        unless $!session-state.transaction;
    my @columns = self.schema-reader.rows(
        'SELECT column_name, data_type, column_default, is_nullable FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = ? ORDER BY ordinal_position', $table).Array;
    self.unsupported("Unknown migration column $table.$column")
        unless @columns.first(*.<column_name> eq $column).defined;
    my @indexes = self.schema-reader.rows(
        'SELECT sql FROM duckdb_indexes() WHERE schema_name = current_schema() AND table_name = ?', $table).Array;
    my @comments = self.schema-reader.rows(
        'SELECT column_name, comment FROM duckdb_columns() WHERE schema_name = current_schema() AND table_name = ?', $table).Array;
    my $metadata = self.schema-reader.rows(
        'SELECT sql, comment FROM duckdb_tables() WHERE schema_name = current_schema() AND table_name = ?', $table).head;
    my @catalog-definitions = table-definitions($metadata<sql>);
    self.unsupported('Generated columns require an explicit DuckDB reconstruction')
        if @catalog-definitions.grep({ .value.uc.contains('GENERATED ALWAYS') });
    my $temporary = self.table-name-wrapper('red_rebuild_' ~ UUID.new.Str.subst('-', '', :g));
    my $quoted = self.table-name-wrapper($table);
    my Bool $found = False;
    my @definitions = @catalog-definitions.map: -> $definition {
        my $text = $definition.key;
        if definition-name($text).lc eq $column.lc {
            $found = True;
            $text ~= ' NOT NULL' if @columns.first(*.<column_name> eq $column)<is_nullable> eq 'YES';
        }
        $text
    };
    self.unsupported("Missing catalog definition for $table.$column") unless $found;
    self.execute('CREATE TABLE ' ~ $temporary ~ ' (' ~ @definitions.join(', ') ~ ')');
    my $names = @columns.map({ self.table-name-wrapper(.<column_name>) }).join(', ');
    self.execute("INSERT INTO $temporary ($names) SELECT $names FROM $quoted");
    self.execute("DROP TABLE $quoted");
    self.execute("ALTER TABLE $temporary RENAME TO $quoted");
    self.execute(.<sql>) for @indexes;
    sub literal(Str $value) { "'" ~ $value.subst("'", "''", :g) ~ "'" }
    self.execute("COMMENT ON TABLE $quoted IS " ~ literal($metadata<comment>))
        if $metadata<comment>.defined;
    for @comments.grep(*.<comment>.defined) -> $c {
        self.execute("COMMENT ON COLUMN $quoted." ~ self.table-name-wrapper($c<column_name>)
            ~ ' IS ' ~ literal($c<comment>));
    }
    self
}

method schema-reader { Red::Driver::DuckDB::SchemaReader.new(:driver(self)) }

submethod TWEAK() {
    $!dbh //= DB::DuckDB.new(:path($!database));
    $!connection //= $!dbh.connect;
}

class Statement does Red::Statement {
    has Str $.query;
    has SessionState $.session-state is required;
    has $!result;
    has $!rows;
    method stt-exec($connection, *@bind) {
        $!result.free if $!result ~~ DB::DuckDB::Result;
        my @parameters = (@bind.elems ?? @bind !! @!binds).map({ $.driver.deflate($_) });
        $!result = $.driver.connection-lock.protect: {
            DB::DuckDB::Error.new(:message('DuckDB connection is closed')).throw
                if $!session-state.closed;
            my $result;
            if @parameters {
                my $prepared = $connection.prepare($!query);
                my $handle = $prepared.stmt;
                duckdb-clear-bindings($handle);
                for @parameters.kv -> $index, $value {
                    my $position = $index + 1;
                    my $status;
                    if !$value.defined {
                        $status = duckdb-bind-null($handle, $position);
                    } elsif $value ~~ Bool {
                        $status = duckdb-bind-boolean($handle, $position, $value);
                    } elsif $value ~~ Int && -(2**63) <= $value < 2**63 {
                        $status = duckdb-bind-int64($handle, $position, $value);
                    } elsif $value ~~ Num {
                        $status = duckdb-bind-double($handle, $position, $value);
                    } elsif $value ~~ Blob {
                        my $buffer = CArray[uint8].allocate($value.elems max 1);
                        for ^$value.elems -> $byte { $buffer[$byte] = $value[$byte] }
                        $status = duckdb-bind-blob($handle, $position, $buffer, $value.elems);
                    } else {
                        my $text = $value.Str;
                        $status = duckdb-bind-varchar-length($handle, $position, $text,
                            $text.encode('utf8').elems);
                    }
                    DB::DuckDB::Error.new(:code($status), :message('DuckDB parameter binding failed')).throw
                        if $status != DuckDBSuccess;
                }
                $result = $prepared.execute;
            } else {
                my $raw = DuckDB-Raw-Result.new;
                my $status = duckdb-query($connection.handle, $!query, $raw);
                if $status != DuckDBSuccess {
                    my $message = take-cstr(duckdb-result-error($raw));
                    duckdb-destroy-result($raw);
                    DB::DuckDB::Error.new(:code($status), :$message).throw;
                }
                $result = DB::DuckDB::Result.new(:$raw, :!finish);
                $connection.sync-time-zone-offset if sql-head($!query) eq any('SET', 'RESET');
            }
            $.driver.note-transaction($!query);
            $result
        };
        $!rows = $!result ~~ DB::DuckDB::Result ?? $!result.hashes.iterator !! ().iterator;
        $connection
    }
    method stt-row($connection) {
        DB::DuckDB::Error.new(:message('DuckDB connection is closed')).throw
            if $!session-state.closed;
        my $row := $!rows.pull-one;
        return IterationEnd if $row =:= IterationEnd;
        for $!result.names.kv -> $i, $name {
            if $!result.column-types[$i] == any(12, 20, 21, 22, 31, 42) && $row{$name}.defined {
                $row{$name} = timestamp-value($row{$name});
            }
        }
        for $!result.names.kv -> $i, $name {
            if $!result.column-types[$i] == 18 && $row{$name}.defined {
                my $text = $row{$name};
                my @bytes;
                while $text.chars {
                    if $text.starts-with('\\x') {
                        @bytes.push: :16($text.substr(2, 2));
                        $text = $text.substr(4);
                    } else {
                        @bytes.push: $text.substr(0, 1).ord;
                        $text = $text.substr(1);
                    }
                }
                $row{$name} = Blob.new(@bytes);
            }
        }
        $row
    }
    method finish-transaction { $!result.free if $!result ~~ DB::DuckDB::Result }
}

multi method prepare(Str $query) {
    CATCH { when DB::DuckDB::Error { self.map-exception($_).throw } }
    DB::DuckDB::Error.new(:message('DuckDB connection is closed')).throw if $!session-state.closed;
    self.unsupported('SQL commands cannot contain NUL; bind text values instead') if $query.contains("\0");
    Statement.new(:driver(self), :statement($!connection), :session-state($!session-state), :$query)
}

# query() does not update DB::DuckDB::Connection's execute-only tracking.
method note-transaction(Str $query) {
    my $verb = sql-head($query);
    $!session-state.transaction = True if $verb eq any('BEGIN', 'START');
    $!session-state.transaction = False if $verb eq any('COMMIT', 'END', 'ROLLBACK');
}
method begin {
    self.unsupported('DuckDB does not support nested transactions')
        if $!session-state.transaction;
    self.execute('BEGIN');
    self
}
method commit { self.execute('COMMIT'); self }
method rollback { self.execute('ROLLBACK'); self }
method unsupported(Str $reason) {
    X::Red::Compiler::Unsupported.new(:fatal, :$reason).throw
}
method supports-savepoints(--> Bool) { False }
method savepoint(Str:D $name) { self.unsupported('DuckDB does not support savepoints') }
method rollback-to-savepoint(Str:D $name) { self.unsupported('DuckDB does not support savepoints') }
method release-savepoint(Str:D $name) { self.unsupported('DuckDB does not support savepoints') }

# Identifiers are always quoted; DuckDB permits spaces, dots and reserved words.
# Override CommonSQL's unquoted-name policy without multi candidate ordering.
proto method is-valid-table-name(Str:D $name --> Bool) {
    so $name.chars && !$name.contains("\0")
}

multi method default-type-for-type(Str --> Str:D) { 'VARCHAR' }
multi method default-type-for-type(Int --> Str:D) { 'BIGINT' }
multi method default-type-for-type(Rat --> Str:D) { 'DECIMAL(38,18)' }
multi method default-type-for-type(Num --> Str:D) { 'DOUBLE' }
multi method default-type-for-type(Date --> Str:D) { 'DATE' }
multi method default-type-for-type(DateTime --> Str:D) { 'TIMESTAMP' }
multi method default-type-for-type(Blob --> Str:D) { 'BLOB' }
multi method translate(Red::Column $_, 'column-auto-increment') {
    return '' => [] unless .auto-increment;
    my $name = 'red_seq_' ~ .class.^table ~ '_' ~ .name;
    my $sequence = self.table-name-wrapper($name).subst("'", "''", :g);
    "DEFAULT nextval('$sequence')" => []
}
multi method translate(Red::AST::Insert $_, $context?) {
    my @values = .values.grep({ .value.value.defined ||
        (.value.column.DEFINITE && .value.column.attr.type ~~ Json && !(.value.value === Json)) });
    my $table = self.table-name-wrapper(.into.^table);
    return "INSERT INTO $table DEFAULT VALUES RETURNING *" => [] unless @values;
    "INSERT INTO $table (" ~ @values.map({ self.table-name-wrapper(.key) }).join(', ')
        ~ ') VALUES (' ~ ('?' xx @values).join(', ') ~ ') RETURNING *'
        => @values.map({ self.wildcard-value(.value) }).Array
}
multi method translate($, 'delete-returning') { 'RETURNING *' => [] }
multi method translate($, 'update-returning') { 'RETURNING *' => [] }

method create-schema(%models) {
    my %pending = %models;
    my @ordered;
    while %pending {
        my @ready = %pending.keys.grep(-> $key {
            !%pending{$key}.^columns.grep(-> $attr {
                my $ref = $attr.column.ref;
                $ref.defined && $ref.class !=== %pending{$key}
                    && %pending.values.grep({ $_ === $ref.class }).elems
            }).elems
        });
        self.unsupported('Cyclic foreign keys cannot be created by DuckDB') unless @ready;
        for @ready -> $key {
            my $model = %pending{$key}:delete;
            @ordered.push: $model;
        }
    }
    for @ordered -> $model {
        self.translate($_) for $model.^indexes;
        self.translate($_) for $model.^schema-constraints;
    }
    .^create-table for @ordered;
    %models.keys.map({ $_ => True }).Array
}

multi method translate(Red::AST::CreateTable $table, $context?) {
    my @sql;
    for $table.columns.grep(*.auto-increment) -> $column {
        @sql.push: ('CREATE SEQUENCE IF NOT EXISTS ' ~ self.table-name-wrapper(
            'red_seq_' ~ $table.name ~ '_' ~ $column.name)) => [];
    }
    @sql.push: ('CREATE' ~ ($table.temp ?? ' TEMPORARY' !! '') ~ ' TABLE '
        ~ self.table-name-wrapper($table.name) ~ ' ('
        ~ (|$table.columns.map({ self.translate($_, 'create-table').key }),
           |$table.constraints.map({ self.translate($_, 'create-table').key })).join(', ')
        ~ ')') => [];
    @sql.List
}

multi method deflate(Rat:D $value) { $value.Str }
multi method inflate(Str $value, Rat :$to!) { $value.Rat }
multi method inflate(Blob $value, :$to!) { $to.new($value) }
multi method type-for-sql('bigint' --> 'Int') {}
multi method type-for-sql('double' --> 'Num') {}
multi method type-for-sql('float' --> 'Num') {}
multi method type-for-sql('date' --> 'Date') {}
multi method type-for-sql('timestamp' --> 'DateTime') {}
multi method type-for-sql('uuid' --> 'UUID') {}
multi method type-for-sql(Str $type where *.starts-with('decimal') --> Str) { 'Rat' }

multi method map-exception(DB::DuckDB::Error $error where {
    .message.contains('Duplicate key') || .message.contains('UNIQUE constraint')
        || .message.contains('Data contains duplicates')
}) {
    X::Red::Driver::Mapped::Unique.new(:driver<DuckDB>, :orig-exception($error), :fields([]))
}
multi method map-exception(DB::DuckDB::Error $error where .message ~~ /'Table with name ' (.*?) ' already exists'/) {
    $error.message ~~ /'Table with name ' (.*?) ' already exists'/;
    X::Red::Driver::Mapped::TableExists.new(:driver<DuckDB>, :orig-exception($error), :table(~$0))
}
multi method inflate(Str $value, DateTime :$to!) {
    timestamp-value($value)
}
multi method deflate(DateTime:D $value) { ~$value.utc }

method supports-index-method(Str $method --> Bool) { so $method eq any('', 'art', 'btree') }
method indexes-for-table(Str $table --> Array) {
    my @indexes;
    my $statement = self.execute('SELECT index_name, is_unique, sql FROM duckdb_indexes() WHERE schema_name = current_schema() AND table_name = ?', $table);
    loop {
        my $row := $statement.row;
        last if $row =:= IterationEnd || !$row;
        @indexes.push: { name => $row<index_name>, unique => so $row<is_unique>,
            partial => False, keys => sql-index-keys($row<sql>) };
    }
    for self.schema-reader.indexes-of($table) -> $constraint {
        next unless $constraint<constraint_type> eq any('UNIQUE', 'PRIMARY KEY');
        @indexes.push: { name => $constraint<constraint_name>, unique => True,
            partial => False, keys => from-json($constraint<column_names_json>)
                .map({ self.table-name-wrapper($_) }).Array };
    }
    @indexes.Array
}
multi method wildcard-value(Blob $value) { $value }
method stringify-json { True }
multi method translate(Red::AST::RegexMatch $_, $context?) {
    self.unsupported('DuckDB requires a structured regex, not a backend-specific pattern')
        unless .pattern ~~ Red::Regex;
    my $raw = self.translate(.value, .value ~~ Red::AST::Value ?? 'bind' !! $context);
    my $text = .value.returns ~~ Bool
        ?? "(SELECT CASE WHEN value IS NULL THEN NULL WHEN value THEN 'True' ELSE 'False' END "
            ~ "FROM (SELECT {$raw.key} AS value) _red_rx_boolean)"
        !! "CAST({$raw.key} AS VARCHAR)";
    Red::Driver::DuckDB::Regex.new(:regex(.pattern)).translate($text => $raw.value)
}
multi method translate(Red::AST::RegexCapture $_, $context?) {
    self.unsupported('Reading scalar regex capture text is only implemented for PostgreSQL')
        unless .selection ~~ Str && .selection eq '$/';
    self.unsupported('Reading whole matches requires a structured regex')
        unless .match.pattern ~~ Red::Regex;
    my $subject = self.translate(.match.value,
        .match.value ~~ Red::AST::Value ?? 'bind' !! $context);
    Red::Driver::DuckDB::Regex.new(:regex(.match.pattern))
        .translate-text("CAST({$subject.key} AS VARCHAR)" => $subject.value)
}

multi method default-type-for-type(UUID --> Str:D) { 'UUID' }
multi method type-for-sql('boolean' --> 'Bool') {}
multi method inflate(Str $value, UUID :$to!) {
    UUID.bless(:bytes(buf8.new($value.subst('-', '', :g).comb(2).map({ :16($_) }))),
        :version(:16($value.substr(14, 1))))
}

# Preserve the backend's typed error when Red has no corresponding exception.
multi method map-exception(DB::DuckDB::Error $error) { $error }

# Close this connection; the caller may still share the database handle.
# Reopen a file after explicitly handing ownership to another process.
method reopen {
    self.unsupported('Cannot reopen a DuckDB connection inside a transaction')
        if $!session-state.transaction;
    self.close;
    $!connection = $!dbh.connect;
    $!session-state = SessionState.new;
    self
}
method close {
    self.connection-lock.protect: {
        unless $!session-state.closed {
            self.release-migration-lock;
            $!session-state.closed = True;
            $!session-state.transaction = False;
            $!connection.clear-cache;
            $!connection.free;
        }
    }
    self
}

multi method translate(Red::AST::Sum $_, 'index') {
    '(' ~ self.index-key(.left) ~ ' + ' ~ self.index-key(.right) ~ ')' => []
}
method index-definition-matches($definition, $found --> Bool) {
    return False unless $found ~~ Associative && ($found<keys>:exists);
    my @keys = $definition.keys.map({ self.index-key-fingerprint(self.index-key($_)) });
    so $found<unique> == $definition.unique
        && ($found<keys>.map({ self.index-key-fingerprint($_) }).List eqv @keys.List)
        && !$definition.predicate.DEFINITE
        && !$definition.opclasses.grep(*.chars)
}
multi method translate(Red::AST::Function $_, 'index') {
    .func ~ '(' ~ .args.map({ self.index-key($_) }).join(', ') ~ ')' => []
}

multi method translate(Red::Column $_, 'column-type') {
    return 'BIGINT' => [] if .auto-increment;
    if .attr.type.?red-type-column-type -> $type {
        return self.type-by-name($type) => [];
    }
    (.type.defined ?? self.type-by-name(.type) !! self.default-type-for($_)) => []
}
multi method default-type-for-type(Instant --> Str:D) { 'DOUBLE' }
multi method deflate(Instant:D $value) { $value.to-posix[0].Num }
multi method type-by-name('jsonb' --> 'JSON') {}
multi method translate(Red::AST::DateTimePart $part, $context?) {
    my $base = self.translate($part.base, $context);
    "EXTRACT({$part.part.key.uc} FROM {$base.key})" => $base.value
}
method product-value(Red::AST::Value:D $value) {
    my $type = $value.returns;
    my $sql-type = $type ~~ Int ?? 'HUGEINT'
        !! $type ~~ Numeric ?? 'DECIMAL(38,18)' !! '';
    ($sql-type ?? "CAST(? AS $sql-type)" !! '?') => [self.wildcard-value($value)]
}

multi method default-type-for-type(Positional $ --> Str:D) { 'JSON' }
multi method wildcard-value(@values) { @values.Array }
multi method deflate(Positional:D $value) { to-json($value, :!pretty) }
multi method inflate(Str $value, Positional :$to!) {
    my $array-type = Array.^parameterize($to.of);
    $array-type.new(|from-json($value))
}
multi method deflate(Blob:D $value) { $value }

# DuckDB does not cascade foreign-key dependencies when dropping a table.
# Inspect the actual schema, since it can differ from the current model classes.
method drop-schema(%models) {
    my %pending;
    for %models.values.map(*.^table).unique -> $table {
        %pending{$table} = set self.schema-reader.indexes-of($table)
            .grep(*.<constraint_type> eq 'FOREIGN KEY')
            .map(*.<referenced_table>).grep(* ne $table);
    }
    my @order;
    while %pending {
        my @leaves = %pending.keys.grep(-> $table {
            !%pending.values.grep({ $_{$table} }).elems
        }).sort;
        self.unsupported('Cyclic foreign keys prevent dependency-ordered schema removal')
            unless @leaves;
        for @leaves -> $table {
            @order.push: $table;
            %pending{$table}:delete;
        }
    }
    self.execute('DROP TABLE IF EXISTS ' ~ self.table-name-wrapper($_)) for @order;
    self
}

multi method translate(Red::AST::Value $_ where .type ~~ Bool, $context?) {
    return 'NULL' => [] unless .value.defined;
    (.value ?? 'TRUE' !! 'FALSE') => []
}

# Reversing direction must reverse NULL placement as well. DuckDB's native
# NULLS LAST default in both directions would otherwise break reverse/tail.
multi method translate(Red::AST::Ordering $_, 'order') {
    my $value = self.translate(.value, 'order');
    ($value.key ~ (.descending ?? ' DESC NULLS FIRST' !! ' ASC NULLS LAST')) => $value.value
}
multi method translate(Red::AST::Mul $_ where {
    .left ~~ Red::AST::Value && .left.value ~~ Numeric && .left.value == -1
}, 'order') {
    my $value = self.translate(.right, 'order');
    ($value.key ~ ' DESC NULLS FIRST') => $value.value
}

multi method translate(Red::AST::BoundFilter::Parameter $parameter, $context?) {
    my $translated = self.translate-query-parameter($parameter, $context);
    my $type = $parameter.type ~~ Int ?? 'BIGINT'
        !! $parameter.type ~~ Rat ?? 'DECIMAL(38,18)'
        !! $parameter.type ~~ Num ?? 'DOUBLE' !! '';
    ($type ?? "CAST({$translated.key} AS $type)" !! $translated.key) => $translated.value
}

# DuckDB has no row-locking clause; never silently run an unlocked SELECT.
multi method translate(Red::LockType $lock --> Str) {
    self.unsupported('DuckDB does not support row-level locking')
}
