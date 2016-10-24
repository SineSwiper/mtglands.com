#!/usr/bin/perl

use utf8;
use v5.10;
use strict;
use warnings;

use Date::Parse;
use Data::Dumper;
use JSON::XS;

$| = 1;

binmode(STDOUT, ":utf8");
binmode(STDERR, ":utf8");

my $CARD_NAME = shift;

##################################################################################################

### XXX: A lot of this is ripped data from mtglands-cache.pl, which really needs to go into
### some common modules.

say "Loading JSON data...";

my $json = JSON::XS->new->utf8;  # raw data needs to be undecoded UTF-8

open my $json_fh, '<', 'AllSets.json' or die "Can't open AllSets.json: $!";
$/ = undef;
my $raw_json = <$json_fh>;
close $json_fh;

say "Decoding JSON data...";
my %MTG_DATA = %{ $json->decode($raw_json) };
undef $raw_json;

### Find lands ###

# This just adds in epoch dates here for sorting
foreach my $set_data (values %MTG_DATA) {
    $set_data->{releaseDateEpoch} = str2time($set_data->{releaseDate});
}

my %LAND_DATA;

say "Searching for lands...";
foreach my $set (
    sort { $MTG_DATA{$b}{releaseDateEpoch} <=> $MTG_DATA{$a}{releaseDateEpoch} }
    keys %MTG_DATA
) {
    my $set_data = $MTG_DATA{$set};

    next if $set_data->{onlineOnly} && $set_data->{onlineOnly} eq 'true';
    next if $set_data->{border} eq 'silver';

    foreach my $card_data (@{ $set_data->{cards} }) {
        my $name = $card_data->{name};
        next unless $name eq $CARD_NAME;

        say Dumper $card_data;

        # Create a new RegExp based on the example card
        if (my $base_re = $card_data->{text}) {
            my $quotename = quotemeta $name;
            $base_re =~ s/
                # find its own card name
                (?:(?<=\W)|\A) $quotename (?=\W)
            /⦀name⦀/gx;  # use U+2980 as a "percent-code"

            $base_re = quotemeta $base_re;
            $base_re =~ s/\\⦀/⦀/g;     # revert backslashes of code char
            $base_re =~ s/\\ / /g;     # space escaping is excessive
            $base_re =~ s/\\\n/\\R/g;  # use '\R' for newline escaping

            ### XXX: This is a whole lot of backslashes, because of the quotemeta...
            $base_re =~ s/
                # mana color symbols
                (?<=\\\{) [WURGB] (?=\\\})
            /[WURGB]/gx;
            $base_re =~ s!
                # split mana color symbols
                (?<=\\\{) [WURGB0-9]\\/[WURGB0-9] (?=\\\})
            ![WURGB0-9]/[WURGB0-9]!gx;
            $base_re =~ s!
                # Phyrexian mana color symbols
                (?<=\\\{) [WURGB0-9]P (?=\\\})
            ![WURGB0-9]P!gx;
            $base_re =~ s/
                # find all basic land types, even with 'a' or 'an'
                (?<=\W) (?:an?\s)? (?:Plains|Island|Mountain|Forest|Swamp) (?=\W)
            /(?:an? )?(?:Plains|Island|Mountain|Forest|Swamp)/gx;

            $base_re = "\\A$base_re\\z";
            say "RE: $base_re";
        }

        exit 0;
    }
}

warn "Did not find card: $CARD_NAME\n";
exit 1;
