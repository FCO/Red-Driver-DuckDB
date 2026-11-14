use nqp;
use X::Red::Exceptions;
unit module Red::Driver::DuckDB::Regex::Unicode;

my %cache;
my Lock $lock .= new;

# Enumerate Rakudo's own scalar character classes once per process. SQL receives
# only static ranges, so matching never calls back into Raku for database rows.
sub class-ranges(Str:D $name --> List:D) is export {
    $lock.protect: {
        return %cache{$name} if %cache{$name}:exists;
        my %codes = alpha => nqp::const::CCLASS_ALPHABETIC,
            alnum => nqp::const::CCLASS_WORD, word => nqp::const::CCLASS_WORD,
            lower => nqp::const::CCLASS_LOWERCASE, upper => nqp::const::CCLASS_UPPERCASE,
            digit => nqp::const::CCLASS_NUMERIC, xdigit => nqp::const::CCLASS_HEXADECIMAL,
            space => nqp::const::CCLASS_WHITESPACE, blank => nqp::const::CCLASS_BLANK,
            print => nqp::const::CCLASS_PRINTING, cntrl => nqp::const::CCLASS_CONTROL,
            punct => nqp::const::CCLASS_PUNCTUATION, graph => nqp::const::CCLASS_ALPHANUMERIC;
        X::Red::Compiler::Unsupported.new(:fatal,
            :reason("Unknown DuckDB regex character class $name")).throw
            unless %codes{$name}:exists;
        my int $code = %codes{$name};
        my int $alpha = $name eq 'alpha';
        my int $graph = $name eq 'graph';
        my int $start = -1;
        my @ranges;
        loop (my int $point = 0; $point <= 0x110000; $point++) {
            my int $matches = 0;
            if $point < 0x110000 && !($point >= 0xD800 && $point <= 0xDFFF) {
                my str $character = nqp::chr($point);
                $matches = nqp::iscclass($code, $character, 0)
                    || ($alpha && $point == 95)
                    || ($graph && nqp::iscclass(nqp::const::CCLASS_PUNCTUATION, $character, 0));
            }
            if $matches {
                $start = $point if $start == -1;
            } elsif $start != -1 {
                @ranges.push: (nqp::box_i($start, Int), nqp::box_i($point - 1, Int)).List;
                $start = -1;
            }
        }
        %cache{$name} = @ranges.List
    }
}
