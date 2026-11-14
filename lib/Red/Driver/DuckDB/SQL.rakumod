use X::Red::Exceptions;
unit module Red::Driver::DuckDB::SQL;

# These helpers classify control SQL without inspecting quoted data values.
sub sql-head(Str $query --> Str) is export {
    my $text = $query.trim-leading;
    while $text.starts-with('--') || $text.starts-with('/*') {
        if $text.starts-with('--') {
            my $newline = $text.index("\n");
            return '' unless $newline.defined;
            $text = $text.substr($newline + 1).trim-leading;
        } elsif $text.starts-with('/*') {
            my Int $depth = 1;
            my Int $pos = 2;
            while $pos < $text.chars && $depth {
                my $pair = $text.substr($pos, 2);
                if $pair eq '/*' { $depth++; $pos += 2 }
                elsif $pair eq '*/' { $depth--; $pos += 2 }
                else { $pos++ }
            }
            return '' if $depth;
            $text = $text.substr($pos).trim-leading;
        }
    }
    ($text.match(/^ (<[A..Za..z]>+) /)[0] // '').Str.uc
}

sub timestamp-value(Str $value --> DateTime) is export {
    my $text = $value.subst(' ', 'T');
    $text ~= ':00' if $text ~~ / <[+\-]> \d ** 2 $/;
    $text ~= 'Z' unless $text ~~ / [ 'Z' | <[+\-]> \d ** 2 ':' \d ** 2 ] $/;
    DateTime.new($text)
}

# Preserve full catalog definitions (including COLLATE), splitting only commas
# at the outer table level. The unquoted mask distinguishes generated syntax
# from an ordinary default string containing the same words.
sub table-definitions(Str $sql --> Array) is export {
    my @definitions;
    my Str $quote = '';
    my Int $depth = 0;
    my Str $text = '';
    my Str $visible = '';
    loop (my Int $pos = 0; $pos < $sql.chars; $pos++) {
        my $char = $sql.substr($pos, 1);
        if $quote {
            $text ~= $char if $depth;
            $visible ~= ' ' if $depth;
            if $char eq $quote {
                if $sql.substr($pos + 1, 1) eq $quote {
                    $text ~= $quote if $depth;
                    $visible ~= ' ' if $depth;
                    $pos++;
                } else { $quote = '' }
            }
        } elsif $char eq any("'", '"', '`') {
            $quote = $char;
            $text ~= $char if $depth;
            $visible ~= ' ' if $depth;
        } elsif $char eq '(' {
            $depth++;
            if $depth > 1 { $text ~= $char; $visible ~= $char }
        } elsif $char eq ')' {
            $depth--;
            if $depth == 0 {
                @definitions.push: $text.trim => $visible.trim;
                return @definitions.Array;
            }
            $text ~= $char;
            $visible ~= $char;
        } elsif $char eq ',' && $depth == 1 {
            @definitions.push: $text.trim => $visible.trim;
            $text = '';
            $visible = '';
        } elsif $depth {
            $text ~= $char;
            $visible ~= $char;
        }
    }
    X::Red::Compiler::Unsupported.new(:fatal,
        :reason('Cannot reconstruct DuckDB catalog table definition')).throw
}

sub definition-name(Str $definition --> Str) is export {
    return $definition.words.head unless $definition.starts-with('"');
    my $name = '';
    loop (my Int $pos = 1; $pos < $definition.chars; $pos++) {
        my $char = $definition.substr($pos, 1);
        if $char eq '"' {
            if $definition.substr($pos + 1, 1) eq '"' { $name ~= '"'; $pos++ }
            else { return $name }
        } else { $name ~= $char }
    }
    X::Red::Compiler::Unsupported.new(:fatal, :reason('Invalid catalog identifier')).throw
}

