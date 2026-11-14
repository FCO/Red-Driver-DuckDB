use Red::Driver::CommonSQL;

unit role Red::Driver::DuckDB::Migrations does Red::Driver::CommonSQL;

method migration-transactional-ddl(--> Bool:D) { True }
method migration-auto-column($column, Str $table --> List:D) {
    self.migration-error('Automatic DuckDB IDs require a table name') unless $table.chars;
    my $sequence = self.table-name-wrapper('red_seq_' ~ $table ~ '_' ~ $column.name).subst("'", "''", :g);
    ('BIGINT', " PRIMARY KEY DEFAULT nextval('$sequence')")
}
method migration-create-table-prefix($table --> Array:D) {
    $table.columns.grep(*.auto-increment).map({
        'CREATE SEQUENCE ' ~ self.table-name-wrapper('red_seq_' ~ $table.name ~ '_' ~ .name)
    }).Array
}
method migration-drop-table-suffix($table --> Array:D) {
    $table.columns.grep(*.auto-increment).map({
        'DROP SEQUENCE ' ~ self.table-name-wrapper('red_seq_' ~ $table.name ~ '_' ~ .name)
    }).Array
}
method migration-lock(Bool :$read-only = False) {
    if $read-only { self.execute('BEGIN') }
    else {
        try {
            self.acquire-migration-lock;
            CATCH { default { self.migration-error("Cannot acquire DuckDB migration lock: {.message}") } }
        }
    }
}
method migration-unlock { self.release-migration-lock }

method migration-read-transaction(--> Bool:D) { True }
method migration-rebuild-nullability(--> Bool:D) { True }
method migration-release-for-child(--> Bool:D) { True }
method migration-close { self.close; self.dbh.close }
method migration-extra-drop-statements(@tables --> Array:D) {
    my @sql;
    for @tables -> $table {
        for self.schema-reader.table-definition($table).columns.grep(*.auto-increment) -> $column {
            @sql.push: 'DROP SEQUENCE IF EXISTS '
                ~ self.table-name-wrapper('red_seq_' ~ $table ~ '_' ~ $column.name);
        }
    }
    @sql.Array
}
method migration-provision(IO::Path $folder, Str $name, %server --> Hash:D) {
    %(parameters => %(database => $folder.add('test.duckdb').Str), created => False)
}

method migration-alter-column(Str $table, $before, $column, Str $definition --> Array:D) {
    my $prefix = 'ALTER TABLE ' ~ self.table-name-wrapper($table)
        ~ ' ALTER COLUMN ' ~ self.table-name-wrapper($column.name);
    my @sql;
    @sql.push("$prefix TYPE {$column.type}") if $before.type ne $column.type;
    @sql.push($prefix ~ ($column.nullable ?? ' DROP NOT NULL' !! ' SET NOT NULL'))
        if $before.nullable != $column.nullable;
    @sql.Array
}

method migration-string-literal(Str $value --> Str:D) {
    my $hex = $value.encode('utf8').map(*.fmt('%02x')).join;
    "CAST(X'$hex' AS TEXT)"
}
