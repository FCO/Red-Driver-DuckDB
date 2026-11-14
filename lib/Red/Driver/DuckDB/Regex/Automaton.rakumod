use Red::Regex;
use Red::Regex::Automaton;

# Capture registers are source offsets, not interpolated SQL or Raku callbacks.
unit class Red::Driver::DuckDB::Regex::Automaton is Red::Regex::Automaton;
has Set $.referenced;

submethod TWEAK {
    my @ids;
    Red::Regex.new(:tree(self.tree)).walk(-> $node {
        @ids.append: $node[1].list if $node[0] eq 'backreference';
    });
    $!referenced = @ids.Set;
    Red::Regex.new(:tree(self.tree)).walk(-> $node {
        if $node[0] eq 'capture' && $!referenced{$node[1]} {
            my Bool $boundary = False;
            Red::Regex.new(:tree($node[2].List)).walk(-> $part {
                $boundary = True if $part[0] eq 'match-boundary';
            });
            self.unsupported('Capture references crossing Match boundaries are not supported')
                if $boundary;
        }
    });
}

method fragment($tree, Bool :$ignore = False --> List:D) {
    given $tree[0] {
        when 'capture' {
            return self.fragment($tree[2], :$ignore) unless $!referenced{$tree[1]};
            my $start = self.state;
            my $end = self.state;
            my ($from, $to) = self.fragment($tree[2], :$ignore);
            self.edge($start, $from, 0, ['capture-open', $tree[1]]);
            self.edge($to, $end, 0, ['capture-close', $tree[1]]);
            ($start, $end)
        }
        when 'scope' {
            my @ids;
            Red::Regex.new(:tree($tree[1].List)).walk(-> $node {
                @ids.push: $node[1] if $node[0] eq 'capture' && $!referenced{$node[1]};
            });
            return self.fragment($tree[1], :$ignore) unless @ids;
            my $start = self.state;
            my $end = self.state;
            my ($from, $to) = self.fragment($tree[1], :$ignore);
            self.edge($start, $from, 0, ['capture-clear', @ids.List]);
            self.edge($to, $end, 0);
            ($start, $end)
        }
        when 'backreference' {
            my $start = self.state;
            my $end = self.state;
            self.edge($start, $end, 0, ['backreference', $tree[1], 1]);
            ($start, $end)
        }
        when 'repeat' {
            my ($child, $minimum, $maximum) = $tree[1..3];
            if $minimum > 0 && $minimum == $maximum && $child[0] eq 'backreference' {
                my $start = self.state;
                my $end = self.state;
                self.edge($start, $end, 0, ['backreference', $child[1], $minimum]);
                return ($start, $end);
            }
            if $minimum > 0 && $minimum == $maximum && $child[0] eq 'literal' {
                self.unsupported('DuckDB regex literal repeat exceeds its resource limit')
                    if $child[1].chars * $minimum > 1000000;
                my $text = $child[1] x $minimum;
                my $start = self.state;
                my $end = self.state;
                self.edge($start, $end, $text.ords.elems, ['literal-block', $text], :$ignore);
                return ($start, $end);
            }
            callsame
        }
        default { callsame }
    }
}
