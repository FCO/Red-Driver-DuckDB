use Red::Driver::DuckDB;

sub MAIN(Str $directory) {
    my $db = Red::Driver::DuckDB.new;
    my $path = $directory.IO.add('sales.parquet').Str.subst("'", "''", :g);
    $db.execute("COPY (SELECT * FROM (VALUES (1, 'Ana', 30), (2, 'Bruno', 17)) AS sales(id, name, age)) TO '$path' (FORMAT PARQUET)");
    $db.execute('INSTALL excel');
    $db.execute('LOAD excel');
    my $xlsx = $directory.IO.add('people.xlsx').Str.subst("'", "''", :g);
    $db.execute("COPY (SELECT * FROM (VALUES (1, 'Ana', 30), (2, 'Bruno', 17)) AS people(id, name, age)) TO '$xlsx' (FORMAT XLSX, SHEET 'People', HEADER true)");
    $db.close;
}
