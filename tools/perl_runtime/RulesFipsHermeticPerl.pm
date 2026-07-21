package RulesFipsHermeticPerl;

use strict;
use warnings;

BEGIN {
    my $launcher = $ENV{"RULES_FIPS_HERMETIC_PERL"};
    die "RULES_FIPS_HERMETIC_PERL is required\n" if !defined($launcher) || $launcher eq "";
    $^X = $launcher;
}

1;
