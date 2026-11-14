use Red::SchemaReader;
use JSON::Fast;
use Red::Cli::Table;
use Red::Cli::Column;
unit class Red::Driver::DuckDB::SchemaReader does Red::SchemaReader;
has $.driver is required;
method rows(Str $sql, *@bind) {
    my $statement = $!driver.execute($sql, |@bind);
    gather loop {
        my $row := $statement.row;
        last if $row =:= IterationEnd || !$row.defined || !$row;
        take $row;
    }
}
method tables-names {
    self.rows('SELECT table_name FROM information_schema.tables WHERE table_schema = current_schema() ORDER BY table_name').map({ $_<table_name> })
}
method indexes-of($table) {
    self.rows('SELECT *, to_json(constraint_column_names) AS column_names_json, to_json(referenced_column_names) AS referenced_names_json FROM duckdb_constraints() WHERE schema_name = current_schema() AND table_name = ?', $table)
}
method table-definition(Str $table) {
    my @columns = self.rows('SELECT column_name, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = ? ORDER BY ordinal_position', $table);
    return Red::Cli::Table.new(:!exists) unless @columns;
    my @keys = self.indexes-of($table);
    my %pk;
    my %refs;
    my @unique;
    for @keys -> $key {
        my @names = from-json($key<column_names_json>).list;
        given $key<constraint_type> {
            when 'PRIMARY KEY' { %pk{$_} = True for @names }
            when 'UNIQUE' { @unique.push(@names.Array) }
            when 'FOREIGN KEY' {
                for @names.kv -> $i, $name {
                    %refs{$name} = { table => $key<referenced_table>, column => from-json($key<referenced_names_json>)[$i] };
                }
            }
        }
    }
    Red::Cli::Table.new(:name($table), :constraints(@unique), :columns(@columns.map(-> $c {
        Red::Cli::Column.new(:name($c<column_name>), :type($c<data_type>.lc),
            :raku-type((try $!driver.type-for-sql($c<data_type>.lc)) // 'Mu'),
            :nullable($c<is_nullable> eq 'YES'), :pk(so %pk{$c<column_name>}),
            :auto-increment(so ($c<column_default> // '').contains('nextval(')),
            :references(%refs{$c<column_name>} // {}))
    }).Array))
}
method table-definition-from-create-table($sql) {
    $!driver.unsupported('DuckDB schema introspection requires catalog metadata')
}
