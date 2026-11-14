use JSON::Fast;
use Red::AST::JsonItem;
use Red::AST::JsonSetItem;
use Red::AST::JsonRemoveItem;
use Red::AST::JsonOperation;
use Red::AST::Infixes;
use Red::AST::Value;
use Red::Projection;
use Red::Type::Json;

unit role Red::Driver::DuckDB::JSON;

# JSON Pointer supports every object key, including an empty key. Negative array
# positions are resolved against the current parent before adding the segment.
method duck-json-path(Red::AST $path, Pair $source) {
    my $prefix = "''" => [];
    for self.json-path-items($path) -> $item {
        my $part;
        if $item ~~ Red::AST::Value && !($item.value ~~ Int && $item.value < 0) {
            $part = '?' => ['/' ~ $item.value.Str.subst('~', '~0', :g).subst('/', '~1', :g)];
        } else {
            my $key = self.translate($item, 'json-path');
            if $item.returns ~~ Int {
                my $parent = "json_extract({$source.key}, {$prefix.key})";
                $part = "('/' || CAST(CASE WHEN ({$key.key}) < 0 THEN "
                    ~ "json_array_length($parent) + ({$key.key}) ELSE ({$key.key}) END AS VARCHAR))"
                    => [|$key.value, |$source.value, |$prefix.value, |$key.value, |$key.value];
            } else {
                $part = "('/' || replace(replace(CAST({$key.key} AS VARCHAR), '~', '~0'), '/', '~1'))"
                    => $key.value;
            }
        }
        $prefix = "({$prefix.key} || {$part.key})" => [|$prefix.value, |$part.value];
    }
    $prefix
}

multi method translate(Red::AST::JsonItem $_, $context?) {
    my $left = self.translate(.left, 'json-source');
    my $path = self.duck-json-path(.right, $left);
    "json_extract({$left.key}, {$path.key})" => [|$left.value, |$path.value]
}

multi method translate(Red::AST::JsonRemoveItem $_, $context?) {
    my $left = self.translate(.left, $context);
    my $path = self.duck-json-path(.right, $left);
    "json_remove({$left.key}, {$path.key})" => [|$left.value, |$path.value]
}

multi method translate(Red::AST::Value $_ where {
    .type ~~ Pair && .value.key ~~ Red::AST::JsonItem
}, 'update') {
    my $item = .value.key;
    self.translate(ast-value($item.left => Red::AST::JsonSetItem.new(
        :left($item.left), :right($item.right), :value(.value.value))), 'update')
}

multi method translate(Red::AST::JsonSetItem $_, $context?) {
    my $left = self.translate(.left, $context);
    my $path = self.duck-json-path(.right, $left);
    my $value = self.translate(.value, 'json-value');
    my $json = .value.returns ~~ Json
        ?? "COALESCE(CAST({$value.key} AS JSON), CAST('null' AS JSON))"
        !! "COALESCE(to_json({$value.key}), CAST('null' AS JSON))";
    "json_set({$left.key}, {$path.key}, $json)"
        => [|$left.value, |$path.value, |$value.value]
}

multi method translate(Red::AST::Value $_ where .type ~~ Json, 'json-value') {
    'CAST(? AS JSON)' => [self.wildcard-value($_)]
}
multi method translate(Red::AST::Value $_ where .type ~~ Json, 'update-rval') {
    return 'NULL' => [] if .value === Json;
    'CAST(? AS JSON)' => [self.wildcard-value($_)]
}
multi method translate(Red::AST::Value $_ where .type !~~ Json, 'json-value') {
    return 'NULL' => [] unless .value.defined;
    my $type = .type ~~ Bool ?? 'BOOLEAN' !! .type ~~ Numeric ?? 'DECIMAL(38,18)' !! 'VARCHAR';
    "CAST(? AS $type)" => [self.wildcard-value($_)]
}

multi method translate(Red::AST::JsonOperation $operation, $context?) {
    my $value = self.translate($operation.value, 'json-value');
    given $operation.operation {
        when 'exists' { "({$value.key} IS NOT NULL)" => $value.value }
        when 'contains' {
            my $argument = self.translate($operation.argument, 'json-value');
            self.duck-json-contains($value.key, "CAST({$argument.key} AS JSON)")
                => [|$value.value, |$argument.value]
        }
        when 'elems' {
            my $presence = $operation.presence.DEFINITE ?? $operation.presence
                !! Red::Projection.json-presence($operation.value);
            my $present = self.translate($presence, $context);
            '(SELECT CASE WHEN NOT j.present THEN 0 ELSE CASE json_type(j.value) '
                ~ "WHEN 'ARRAY' THEN json_array_length(j.value) "
                ~ "WHEN 'OBJECT' THEN len(json_keys(j.value)) ELSE 1 END END "
                ~ "FROM (SELECT {$value.key} AS value, {$present.key} AS present) j)"
                => [|$value.value, |$present.value]
        }
    }
}

multi method translate(Red::AST::Infix $_ where {
    .op eq any('+', '-', '*', '/', '%', '=', '!=', '<', '>', '<=', '>=')
        && (.left.returns ~~ Json || .right.returns ~~ Json)
}, $context?) {
    self.duck-json-infix($_, $context)
}
multi method translate(Red::AST::Mod $_ where {
    .left.returns ~~ Json || .right.returns ~~ Json
}, $context?) {
    self.duck-json-infix($_, $context)
}
method duck-json-infix(Red::AST::Infix $infix, $context?) {
    my $arithmetic = $infix.op eq any(<+ - * / %>);
    my $both-json = $infix.left.returns ~~ Json && $infix.right.returns ~~ Json;
    my @sql;
    my @bind;
    for ($infix.left, $infix.right), ($infix.right, $infix.left) -> ($operand, $other) {
        my $bind = $operand =:= $infix.left ?? $infix.bind-left !! $infix.bind-right;
        my $translated = self.translate($operand, $bind ?? 'bind' !! $context);
        my $sql = $translated.key;
        @bind.append: $translated.value;
        if $operand.returns ~~ Json && ($arithmetic || !$both-json) {
            my $type = $arithmetic || $other.returns ~~ Numeric ?? 'DECIMAL(38,18)'
                !! $other.returns ~~ Bool ?? 'BOOLEAN' !! 'VARCHAR';
            $sql = "CAST(json_extract_string($sql, '\$') AS $type)";
        }
        @sql.push: $sql;
    }
    "({@sql[0]} {$infix.op} {@sql[1]})" => @bind
}

# Match child containers bottom-up. Array members are unordered and may satisfy
# multiple requested members, while numbers compare by value rather than JSON tag.
method duck-json-contains(Str $value, Str $argument --> Str) {
    qq:to/SQL/.trim;
    (WITH RECURSIVE
        actual AS (SELECT * FROM json_tree($value)),
        wanted AS (
            SELECT *, row_number() OVER (ORDER BY id DESC) AS step
            FROM json_tree($argument)
        ),
        matched(step, matches) AS (
            SELECT 0::BIGINT, json_object()
            UNION ALL
            SELECT wanted.step,
                json_set(matched.matches, '/' || CAST(wanted.id AS VARCHAR),
                    COALESCE(to_json((SELECT list(a.id) FROM actual a
                    WHERE (a.type = wanted.type
                        OR (a.type IN ('BIGINT', 'UBIGINT', 'DOUBLE')
                            AND wanted.type IN ('BIGINT', 'UBIGINT', 'DOUBLE')))
                    AND CASE WHEN wanted.type IN ('OBJECT', 'ARRAY') THEN
                        NOT EXISTS (
                            SELECT 1 FROM wanted child
                            WHERE child.parent = wanted.id AND NOT EXISTS (
                                SELECT 1 FROM actual member
                                JOIN json_each(json_extract(matched.matches,
                                    '/' || CAST(child.id AS VARCHAR))) found
                                    ON TRY_CAST(found.value AS UBIGINT) = member.id
                                WHERE member.parent = a.id
                                AND (wanted.type = 'ARRAY' OR member.key = child.key)
                            )
                        )
                    WHEN wanted.type IN ('BIGINT', 'UBIGINT', 'DOUBLE') THEN
                        CASE
                        WHEN a.type IN ('BIGINT', 'UBIGINT') AND wanted.type IN ('BIGINT', 'UBIGINT')
                            THEN CAST(a.atom AS HUGEINT) = CAST(wanted.atom AS HUGEINT)
                        WHEN a.type = 'DOUBLE' AND wanted.type = 'DOUBLE'
                            THEN CAST(a.atom AS DOUBLE) = CAST(wanted.atom AS DOUBLE)
                        WHEN a.type = 'DOUBLE' THEN
                            CAST(a.atom AS DOUBLE) = trunc(CAST(a.atom AS DOUBLE))
                            AND TRY_CAST(CAST(a.atom AS DOUBLE) AS HUGEINT) = CAST(wanted.atom AS HUGEINT)
                        ELSE CAST(wanted.atom AS DOUBLE) = trunc(CAST(wanted.atom AS DOUBLE))
                            AND CAST(a.atom AS HUGEINT) = TRY_CAST(CAST(wanted.atom AS DOUBLE) AS HUGEINT)
                        END
                    ELSE a.atom IS NOT DISTINCT FROM wanted.atom END)), CAST('[]' AS JSON)))
            FROM matched JOIN wanted ON wanted.step = matched.step + 1
        )
        SELECT EXISTS (
            SELECT 1 FROM actual a
            JOIN json_each(json_extract(matches, '/' || CAST(root.id AS VARCHAR))) found
                ON TRY_CAST(found.value AS UBIGINT) = a.id
            WHERE a.parent IS NULL OR (root.type NOT IN ('OBJECT', 'ARRAY')
                AND a.parent = (SELECT id FROM actual WHERE parent IS NULL)
                AND (SELECT type FROM actual WHERE parent IS NULL) = 'ARRAY')
        ) FROM matched, wanted root
        WHERE root.parent IS NULL AND matched.step = (SELECT count(*) FROM wanted))
    SQL
}
