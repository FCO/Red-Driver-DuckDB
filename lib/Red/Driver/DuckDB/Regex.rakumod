use Red::Driver::SQLite::Regex;
use X::Red::Exceptions;
use Red::Driver::DuckDB::Regex::Automaton;
use Red::Driver::DuckDB::Regex::Unicode;

# Reuse the data-only SQL automaton for lookarounds and set operations. Simple
# trees use RE2 directly, avoiding a large recursive relation for long repeats.
unit class Red::Driver::DuckDB::Regex is Red::Driver::SQLite::Regex;

method native-pattern($tree --> Str:D) {
    given $tree[0] {
        when 'empty' | 'match-boundary' { '' }
        when 'never' { '\b\B' }
        when 'literal' { $.regex.escape($tree[1]) }
        when 'any' { '(?s:.)' }
        when 'sequence' { $tree.skip(1).map({ self.native-pattern($_) }).join }
        when 'alternative' {
            '(?:' ~ $tree.skip(1).map({ self.native-pattern($_) }).join('|') ~ ')'
        }
        when 'group' | 'scope' { '(?:' ~ self.native-pattern($tree[1]) ~ ')' }
        when 'capture' { '(?:' ~ self.native-pattern($tree[2]) ~ ')' }
        when 'mode' {
            '(?' ~ ($tree[1] ?? 'i' !! '-i') ~ ':' ~ self.native-pattern($tree[2]) ~ ')'
        }
        when 'repeat' {
            my ($child, $minimum, $maximum, $frugal) = $tree[1..4];
            $.regex.unsupported('DuckDB regex repetition exceeds the SQL pattern resource limit')
                if $minimum > 1000000 || $maximum > 1000000;
            my $atom = '(?:' ~ self.native-pattern($child) ~ ')';
            my $preference = $frugal ?? '?' !! '';
            my @chunks;
            my $remaining = $minimum;
            while $remaining {
                my $chunk = $remaining min 255;
                @chunks.push: $atom ~ '{' ~ $chunk ~ '}' ~ $preference;
                $remaining -= $chunk;
            }
            if $maximum == -1 {
                @chunks.push: $atom ~ '*' ~ $preference;
            } else {
                $remaining = $maximum - $minimum;
                while $remaining {
                    my $chunk = $remaining min 255;
                    @chunks.push: $atom ~ '{0,' ~ $chunk ~ '}' ~ $preference;
                    $remaining -= $chunk;
                }
            }
            my $pattern = @chunks.join;
            $.regex.unsupported('DuckDB regex exceeds the SQL pattern resource limit')
                if $pattern.chars > 1000000;
            $pattern
        }
        when 'ranges' {
            return $tree[2] ?? '(?s:.)' !! '\b\B' unless $tree[1].elems;
            my &escape = -> $point { '\x{' ~ $point.base(16) ~ '}' };
            '[' ~ ($tree[2] ?? '^' !! '') ~ $tree[1].map({
                escape(.[0]) ~ (.[0] == .[1] ?? '' !! '-' ~ escape(.[1]))
            }).join ~ ']'
        }
        when 'characters' {
            '[' ~ ($tree[2] ?? '^' !! '')
                ~ $tree[1].ords.map({ '\x{' ~ .base(16) ~ '}' }).join ~ ']'
        }
        when 'class' {
            self.native-pattern(['ranges', class-ranges($tree[1]), $tree[2]])
        }
        when 'anchor' {
            given $tree[1] {
                when 'begin' { '\A' }
                when 'end' { '\z' }
                when 'line-begin' { '(?m:^)' }
                when 'line-end' { '(?m:$)' }
                default { $.regex.unsupported('This anchor requires the SQL automaton') }
            }
        }
        default { $.regex.unsupported('This operation requires the SQL automaton') }
    }
}

method reference-text($tree --> Str:D) {
    my @starts = $tree[1].list.map({ "CASE WHEN r.ends[{$_ + 1}] IS NOT NULL THEN r.starts[{$_ + 1}] END" });
    my @ends = $tree[1].list.map({ "r.ends[{$_ + 1}]" });
    my $start = @starts.elems == 1 ?? @starts[0] !! 'COALESCE(' ~ @starts.join(', ') ~ ')';
    my $end = @ends.elems == 1 ?? @ends[0] !! 'COALESCE(' ~ @ends.join(', ') ~ ')';
    "repeat(substr(i.value, $start, ($end) - ($start)), {$tree[2]})"
}

method test($tree, Bool:D $ignore, &bind, &assertion --> Str:D) {
    if $tree[0] eq 'class' {
        return self.test(['ranges', class-ranges($tree[1]), $tree[2]], $ignore, &bind, &assertion);
    }
    if $tree[0] eq 'anchor' && $tree[1] eq any(<word-left word-right word not-word not-within-word within-word>) {
        my $pattern = self.native-pattern(['class', 'word', False]);
        my &word = -> $text { "regexp_full_match($text, {bind($pattern)})" };
        my $previous = 'substr(i.value, r.pos - 1, 1)';
        my $current = 'substr(i.value, r.pos, 1)';
        return do given $tree[1] {
            when 'word-left' { "(NOT ({word($previous)}) AND {word($current)})" }
            when 'word-right' { "({word($previous)} AND NOT ({word($current)}))" }
            when 'word' { "(({word($previous)}) <> ({word($current)}))" }
            when 'not-word' { "(({word($previous)}) = ({word($current)}))" }
            when 'not-within-word' { "NOT ({word($previous)} AND {word($current)})" }
            when 'within-word' { "({word($previous)} AND {word($current)})" }
        };
    }

    return 'TRUE' if $tree[0] eq any(<capture-open capture-close capture-clear>);
    if $tree[0] eq 'backreference' {
        my $reference = self.reference-text($tree);
        return "substr(i.value, r.pos, length($reference)) = $reference";
    }
    if $tree[0] eq 'literal-block' {
        my $left = 'substr(i.value, r.pos, ' ~ $tree[1].ords.elems ~ ')';
        my $right = bind($tree[1]);
        return $ignore ?? "lower($left) = lower($right)" !! "$left = $right";
    }
    callsame.subst(' COLLATE BINARY', '', :g).subst('char(10)', 'chr(10)', :g)
}

method clauses(Str:D $prefix, &bind, &name, Bool :$origin = False --> List:D) {
    my $automaton = Red::Driver::DuckDB::Regex::Automaton.new(
        :tree($.regex.tree), :ignore($.ignore));
    my $graph = $automaton.graph;
    my ($start, $end) = $graph<start accept>;
    my @edges = $graph<edges>.list;
    my @clauses;
    my %assertion-sql;
    my &assertion = -> $tree, Bool $ignore {
        my $key = $tree.WHICH.Str ~ '|' ~ $ignore;
        unless %assertion-sql{$key}:exists {
            my $child-prefix = name();
            my $child = self.WHAT.new(:regex(Red::Regex.new(:tree($tree[3].List))), :$ignore);
            my ($clauses, $accept) = $child.clauses($child-prefix, &bind, &name, :origin);
            @clauses.append: $clauses.list;
            my $position = $tree[1] eq 'before' ?? 'origin' !! 'pos';
            %assertion-sql{$key} = 'r.pos ' ~ ($tree[2] ?? 'NOT IN' !! 'IN')
                ~ " (SELECT $position FROM {$child-prefix}_states WHERE pc = $accept)";
        }
        %assertion-sql{$key}
    };
    for @edges -> $edge {
        assertion($edge[3], $edge[4]) if $edge[3][0] eq 'look'
            && !$.regex.literal-text($edge[3][3]).defined;
    }
    my @rows;
    my @tests;
    my @steps;
    my @starts;
    my @ends;
    for @edges.kv -> $id, $edge {
        my ($from, $to, $step, $test, $ignore) = $edge.list;
        @rows.push: "($id, $from, $to, $step)";
        @tests.push: "(e.id = $id AND {self.test($test, $ignore, &bind, &assertion)})";
        given $test[0] {
            when 'capture-open' | 'capture-close' {
                my $slot = $test[1] + 1;
                @starts.push: "WHEN e.id = $id THEN list_transform(r.starts, lambda v, n: CASE WHEN n = $slot THEN r.pos ELSE v END)"
                    if $test[0] eq 'capture-open';
                my $position = $test[0] eq 'capture-close' ?? 'r.pos' !! 'NULL';
                @ends.push: "WHEN e.id = $id THEN list_transform(r.ends, lambda v, n: CASE WHEN n = $slot THEN $position ELSE v END)";
            }
            when 'capture-clear' {
                my $slots = $test[1].list.map(* + 1).join(', ');
                @starts.push: "WHEN e.id = $id THEN list_transform(r.starts, lambda v, n: CASE WHEN n IN ($slots) THEN NULL ELSE v END)";
                @ends.push: "WHEN e.id = $id THEN list_transform(r.ends, lambda v, n: CASE WHEN n IN ($slots) THEN NULL ELSE v END)";
            }
            when 'backreference' {
                @steps.push: "WHEN e.id = $id THEN length({self.reference-text($test)})";
            }
        }
    }
    @clauses.push: "{$prefix}_edges(id, src, dst, step) AS (VALUES {@rows.join(', ')})";
    my $step = @steps ?? 'CASE ' ~ @steps.join(' ') ~ ' ELSE e.step END' !! 'e.step';
    my $starts = @starts ?? 'CASE ' ~ @starts.join(' ') ~ ' ELSE r.starts END' !! 'r.starts';
    my $ends = @ends ?? 'CASE ' ~ @ends.join(' ') ~ ' ELSE r.ends END' !! 'r.ends';
    my $slots = $automaton.referenced.elems ?? $automaton.referenced.keys.map(*.Int).max + 1 !! 0;
    my $empty = "list_resize([]::BIGINT[], $slots, NULL)";
    my $origin-column = $origin ?? ', origin' !! '';
    my $origin-seed = $origin ?? ', pos' !! '';
    my $origin-step = $origin ?? ', r.origin' !! '';
    @clauses.push: qq:to/SQL/.trim;
        {$prefix}_states(pc, pos, starts, ends$origin-column) AS (
            SELECT $start, pos, $empty, $empty$origin-seed FROM _red_rx_positions
            UNION
            SELECT e.dst, r.pos + ($step), $starts, $ends$origin-step
            FROM {$prefix}_states r
            JOIN {$prefix}_edges e ON e.src = r.pc
            CROSS JOIN _red_rx_input i
            WHERE r.pos + ($step) <= length(i.value) + 1
                AND {self.disjunction(@tests)}
        )
        SQL
    (@clauses.List, $end)
}

method translate(Pair:D $subject --> Pair:D) {
    my Str $pattern;
    try {
        # RE2 cannot consume references. Do not erase the referenced captures.
        my Bool $references = False;
        $.regex.walk(-> $part { $references = True if $part[0] eq 'backreference' });
        $.regex.unsupported('Capture references require the SQL automaton') if $references;
        $pattern = self.native-pattern($.regex.tree);
        CATCH { when X::Red::Compiler::Unsupported { } }
    }
    return "regexp_matches({$subject.key}, ?)" => [|$subject.value, $pattern]
        if $pattern.defined;
    callsame
}

# Width is used only for whole-text extraction through the SQL automaton. A
# fixed span needs no approximation of greedy/frugal backtracking priorities.
method fixed-width($tree, $widths) {
    given $tree[0] {
        when 'empty' | 'never' | 'match-boundary' | 'anchor' | 'look' | 'same' { 0 }
        when 'literal' { $tree[1].ords.elems }
        when 'any' | 'class' | 'ranges' | 'characters' | 'set' { 1 }
        when 'group' | 'scope' { self.fixed-width($tree[1], $widths) }
        when 'mode' { self.fixed-width($tree[2], $widths) }
        when 'capture' { $widths{$tree[1]} = self.fixed-width($tree[2], $widths) }
        when 'backreference' {
            my @sizes = $tree[1].list.map({ $widths{$_} // Int });
            @sizes && !@sizes.grep({ !.defined }).elems && @sizes.unique.elems == 1 ?? @sizes[0] !! Int
        }
        when 'sequence' {
            my @sizes = $tree.skip(1).map({ self.fixed-width($_, $widths) });
            !@sizes.grep({ !.defined }).elems ?? [+] @sizes !! Int
        }
        when 'alternative' {
            my @sizes = $tree.skip(1).map({ self.fixed-width($_, $widths) });
            !@sizes.grep({ !.defined }).elems && @sizes.unique.elems == 1 ?? @sizes[0] !! Int
        }
        when 'repeat' {
            my $size = self.fixed-width($tree[1], $widths);
            $tree[2] == $tree[3] && $size.defined ?? $size * $tree[2] !! Int
        }
        default { Int }
    }
}

method translate-text(Pair:D $subject --> Pair:D) {
    my Bool $boundary = False;
    $.regex.walk(-> $part { $boundary = True if $part[0] eq 'match-boundary' });
    $.regex.unsupported('Whole match reads with Match boundary markers are not implemented')
        if $boundary;
    my Str $pattern;
    try {
        $pattern = self.native-pattern($.regex.tree);
        CATCH { when X::Red::Compiler::Unsupported { } }
    }
    if $pattern.defined {
        return '(SELECT CASE WHEN regexp_matches(i.value, i.pattern) THEN '
            ~ 'regexp_extract(i.value, i.pattern, 0) END FROM '
            ~ "(SELECT {$subject.key} AS value, ? AS pattern) i)"
            => [|$subject.value, $pattern];
    }
    $.regex.unsupported('Variable-width whole regex text requires unsupported capture priorities')
        unless self.fixed-width($.regex.tree, {}).defined;
    my @bind = |$subject.value;
    my &bind = -> Str:D $value { @bind.push: $value; '?' };
    my Int $next-name = 0;
    my &name = -> { '_red_rx_' ~ $next-name++ };
    my $prefix = name();
    my ($clauses, $accept) = self.clauses($prefix, &bind, &name, :origin);
    '(WITH RECURSIVE _red_rx_input(value) AS (SELECT ' ~ $subject.key ~ '), '
        ~ '_red_rx_positions(pos) AS (SELECT 1 UNION ALL SELECT pos + 1 FROM '
        ~ '_red_rx_positions CROSS JOIN _red_rx_input i WHERE pos <= length(i.value)), '
        ~ $clauses.join(', ') ~ ' SELECT substr(i.value, r.origin, r.pos - r.origin) FROM '
        ~ "{$prefix}_states r CROSS JOIN _red_rx_input i WHERE r.pc = $accept "
        ~ 'ORDER BY r.origin, r.pos DESC LIMIT 1)' => @bind
}
