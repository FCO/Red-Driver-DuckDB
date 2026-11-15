use MetamodelX::Red::Model;
unit module Red::Driver::DuckDB::SourceModel;
class BoundIterator does Iterator {
    has $.inner;
    has $.driver;
    method pull-one { my $*RED-DB = $!driver; my $result := $!inner.pull-one; $result }
}
role BoundResult {
    has $.bound-driver is rw;
    has Bool $.source-writable is rw;
    has Bool $.source-complex is rw;
    method iterator { BoundIterator.new(:inner(callsame), :driver($!bound-driver)) }

    method save(|c) {
        die 'Source views are read-only; use :materialize' unless $!source-writable;
        die 'Bulk updates of sources with compound columns are not supported' if $!source-complex;
        my $*RED-DB = $!bound-driver;
        my @result = callsame.List;
        @result.Seq
    }
    method delete(|c) {
        die 'Source views are read-only; use :materialize' unless $!source-writable;
        my $*RED-DB = $!bound-driver;
        my @result = callsame.List;
        @result.Seq
    }
    method create(|c) {
        die 'Source views are read-only; use :materialize' unless $!source-writable;
        my $*RED-DB = $!bound-driver;
        my $result = callsame; $result
    }
}
class SourceHOW is MetamodelX::Red::Model {
    has $.source-driver is rw;
    has Bool $.materialized is rw;
    has %.source-mapping is rw;
    has %.complex-columns is rw;
    method new_type(|c) {
        my $model := callsame;
        with try $*RED-SOURCE-STATE {
            $model.HOW.source-driver = .<driver>;
            $model.HOW.materialized = .<materialized>;
        }
        $model
    }
    method specialise($model, |c) {
        my %state = self.state-for($model);
        { my $*RED-DB = %state<driver>;
          my $*RED-SOURCE-STATE = %state;
          my $result := callsame; $result }
    }
    method source-columns(|) { %!source-mapping.Hash }
    method source-driver(|) is rw { $!source-driver }
    method writable { die 'Source views are read-only; use :materialize' unless $!materialized }
    method state-for($model) {
        my $how = $model.^orig.HOW;
        { :driver($how.source-driver // $*RED-DB), :materialized($how.materialized), :complex(so $how.complex-columns) }
    }
    method rs($model, |c) {
        my %source = self.state-for($model);
        my $rs = callsame;
        $rs = $rs.with(%source<driver>);
        $rs does BoundResult;
        $rs.bound-driver = %source<driver>;
        $rs.source-writable = so %source<materialized>;
        $rs.source-complex = so %source<complex>;
        $rs
    }
    method new-from-data($model, |c) {
        return callsame unless $!source-driver.defined;
        { my $*RED-DB = $!source-driver; my $result = callsame; $result }
    }
    method create(|c) {
        self.writable;
        die 'Writing compound source columns is not supported' if c.hash.keys.grep({ %!complex-columns{$_} });
        my $*RED-DB = $!source-driver;
        my $result = callsame; $result
    }
    method save($obj, |c) {
        self.writable;
        $obj.^sync-collection-dirty;
        die 'Writing compound source columns is not supported'
            if $obj.^dirty-columns.grep({ %!complex-columns{.key.column.attr-name} });
        my $*RED-DB = $!source-driver;
        my $result = callsame; $result
    }
    method delete(|c) { self.writable; my $*RED-DB = $!source-driver; my $result = callsame; $result }
}
