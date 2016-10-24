#!/usr/bin/perl

use utf8;
use v5.10;
use strict;
use warnings;

use Date::Parse;
use Data::Dumper;
use File::Copy;
use HTML::Escape   qw( escape_html );
use HTTP::Request;
use IO::Uncompress::Unzip qw( unzip $UnzipError );
use JSON::XS;
use List::AllUtils qw( first uniq any none );
use LWP;
use Scalar::Util   qw( weaken );
use YAML::XS       qw( LoadFile );

$| = 1;

binmode(STDOUT, ":utf8");
binmode(STDERR, ":utf8");

##################################################################################################

my $BASE_DIR = '/var/www/mtglands.com';

say "Loading land types data...";
my %LAND_TYPES      = %{ LoadFile('conf/land_types.yml')  };
my @LAND_CATEGORIES = (
    'Main', 'Color Identity', 'Mana Pool', 'Supertypes', 'Subtypes', 'Other'  # in order
);

say "Loading color types data...";
my %COLOR_TYPES = %{ LoadFile('conf/color_types.yml') };
my %COLOR_NAMES = ();
foreach my $id (sort keys %COLOR_TYPES) {
    my $color_type = $COLOR_TYPES{$id};
    $COLOR_NAMES{ $color_type->{name} } = $color_type;
    $color_type->{id} = $id;
}

my $ua = LWP::UserAgent->new;
$ua->agent('MTGLands.com/1.0 '.$ua->_agent);

# Others to categorize:
#   Future Sight Duals
#   Other basic fetches like Terminal Moraine and Thawing Glaciers
#   ETB Mono Lands

##################################################################################################

# NOTE: We are using the AllSets.json data because it has more fields about the sets that might be
# useful.  It's larger, but is especially nice for being able to use the latest card printed.

### Load up the MTG JSON data ###

say "Loading JSON data...";

# Download it if we have to
unless (-s 'AllSets.json' && -M 'AllSets.json' < 1) {
    my $url = 'https://mtgjson.com/json/AllSets.json.zip';
    print "    $url";

    my $req = HTTP::Request->new(GET => $url);
    my $res = $ua->request($req);

    if ($res->is_success) {
        my $filename = 'AllSets.json';
        my $zip_data = $res->content;

        print " => $filename";

        open my $json_fh, '>', $filename or die "Can't open $filename: $!";
        unzip \$zip_data, $json_fh       or die "Can't unzip $filename: $UnzipError";
        close $json_fh;

        print "\n";
    }
    else {
        die "Can't download MTG JSON file: ".$res->status_line."\n";
    }
}

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
    # sort by release date
    sort { $MTG_DATA{$b}{releaseDateEpoch} <=> $MTG_DATA{$a}{releaseDateEpoch} }
    # in cases of ties, favor promos over standard sets
    sort { ($MTG_DATA{$a}{type} =~ /core|expansion|reprint/) <=> ($MTG_DATA{$b}{type} =~ /core|expansion|reprint/) }
    keys %MTG_DATA
) {
    my $set_data = $MTG_DATA{$set};

    # almost all of these had paper analogues
    next if $set_data->{onlineOnly} && $set_data->{onlineOnly} eq 'true';

    # none of the Un-sets (Unhinged, Unglued)
    next if $set_data->{border} eq 'silver';

    foreach my $card_data (@{ $set_data->{cards} }) {
        next unless first { $_ eq 'Land' } @{$card_data->{types}};  # only interested in lands
        next if $card_data->{rarity} eq 'Special';                  # only interested in legal cards

        my $name = $card_data->{name};
        next if $LAND_DATA{$name};  # only add in the most recent entry

        $LAND_DATA{$name} = $card_data;

        #if ($name eq 'Forest') {
        #    warn Dumper $card_data;
        #    local $Data::Dumper::Maxdepth = 1;
        #    warn Dumper $set_data;
        #}

        # Unfortunate manual additions/corrections
        $card_data->{mciNumber} = 315 if $name eq "Teferi's Isle";
        $card_data->{mciNumber} =~ s!.+/(\d\w*)$!$1! if $card_data->{mciNumber} && $card_data->{mciNumber} =~ m!/!;

        # Extra data to add
        $card_data->{setData} = $set_data;
        weaken $card_data->{setData};
        $card_data->{setName} = $set_data->{name};

        # Color identity in a easier WUBRG string
        my $color_id = '';
        foreach my $L (split //, 'WUBRG') {
            $color_id .= $L if first { $_ eq $L } @{ $card_data->{colorIdentity} };
        }
        $card_data->{colorIdStr} = $color_id;

        # MagicCards.info is our base source for large images and URLs
        my $mci_num = $card_data->{mciNumber} || $card_data->{number};
        my $mci_set = $set_data->{magicCardsInfoCode} || $set;

        if ($mci_num && $mci_set) {
            $card_data->{infoURL}       = sprintf 'http://magiccards.info/%s/en/%s.html',      lc $mci_set, lc $mci_num;
            $card_data->{lgImageURL}    = sprintf 'http://magiccards.info/scans/en/%s/%s.jpg', lc $mci_set, lc $mci_num;
            $card_data->{localLgImgURL} = sprintf 'img/large/%s-%s.jpg',                       lc $mci_set, lc $mci_num;
        }
        else {
            warn "Could not find MCI number for '$name'!\n" unless $mci_num;
            warn "Could not find MCI set for '$name'!\n"    unless $mci_set;
        }

        # We use Gatherer for small images
        if ($card_data->{multiverseid}) {
            $card_data->{smImageURL} = sprintf 'http://gatherer.wizards.com/Handlers/Image.ashx?multiverseid=%u&type=card', $card_data->{multiverseid};

            # still use the MCI code for the filename, if possible
            $card_data->{localSmImgURL} = ($mci_num && $mci_set) ?
                sprintf('img/small/%s-%s.jpg', lc $mci_set, lc $mci_num) :
                sprintf('img/small/multi-%u.jpg', $card_data->{multiverseid})
            ;
        }
        else {
            warn "Could not find MultiverseID for '$name'!\n";
        }
    }
}

### Fill in the rest of %LAND_TYPES data ###

say "Filling in land type data...";
foreach my $category (@LAND_CATEGORIES) {
    my $category_data = $LAND_TYPES{$category};
    next unless $category_data;

    foreach my $type (sort keys %$category_data) {
        my $type_data = $category_data->{$type};

        # Create a new RegExp based on the example card
        if ($type_data->{example} && !$type_data->{text_re}) {
            my $name      = $type_data->{example};
            my $land_data = $LAND_DATA{$name} || die "Can't find example land card '$name' in MTG JSON for '$type'!";
            next unless exists $land_data->{text};

            my $base_re   = $land_data->{text};
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

            $type_data->{text_re} = "\\A$base_re\\z";
        }
    }
}

### Categorize each land card ###

say "Categorizing lands...";

foreach my $name (sort keys %LAND_DATA) {
    my $land_data = $LAND_DATA{$name};

    $land_data->{landTags} //= {};

    # Match the various land categories, each with its own specific type
    foreach my $category (@LAND_CATEGORIES) {
        my $category_data = $LAND_TYPES{$category};
        next unless $category_data;

        foreach my $type (sort keys %$category_data) {
            my $type_data = $category_data->{$type};

            my @matching_data = $type_data;
            push @matching_data, @{ $type_data->{matching} } if $type_data->{matching};

            my $does_match = 0;
            MATCH_LOOP: foreach my $matching_data (@matching_data) {
                foreach my $match_type ('', '_neg') {
                    foreach my $key (sort keys %$land_data) {
                        my $re = $matching_data->{$key.'_re'.$match_type};
                        next unless $re;
                        $re =~ s/⦀$_⦀/$land_data->{$_}/ge for keys %$land_data;

                        #if ($type eq 'Manland Duals' && $name eq 'Creeping Tar Pit') {
                        #    warn "Currently matching: $category / $type / $does_match\n";
                        #    warn "RE$match_type: $re\n";
                        #    warn "$key: $land_data->{$key}\n";
                        #}

                        # each *_re* line must match
                        $does_match = $match_type eq '_neg' ?
                            $land_data->{$key} !~ /$re/i :
                            $land_data->{$key} =~ /$re/i
                        ;

                        next MATCH_LOOP unless $does_match;
                    }
                }

                last MATCH_LOOP if $does_match;  # any matching block will work
            }
            next unless $does_match;

            # If we got this far, it must have passed
            $land_data->{langTags}{$category} //= [];
            push @{ $land_data->{langTags}{$category} }, $type;

            # Remove dupes
            $land_data->{langTags}{$category} = [ uniq @{ $land_data->{langTags}{$category} } ];

            # Add to the card list within the type
            $type_data->{cards} //= {};
            $type_data->{cards}{$name} = $land_data;
            weaken $type_data->{cards}{$name};

            # The Main category usually has add-ons to clarify the other categories
            if ($type_data->{tags}) {
                foreach my $tag_cat (sort keys %{ $type_data->{tags} }) {
                    $land_data->{langTags}{$tag_cat} //= [];
                    push @{ $land_data->{langTags}{$tag_cat} }, $type_data->{tags}{$tag_cat};
                }
            }
        }
    }

    # Color identity
    my $color_type = $land_data->{colorIdType} = $COLOR_TYPES{ $land_data->{colorIdStr} };
    $land_data->{langTags}{'Color Identity'} = [
        uniq grep { defined } map { $color_type->{$_} } qw/ type subtype name /
    ];

    # Supertypes / Subtypes
    $land_data->{langTags}{Supertypes} = $land_data->{supertypes};
    $land_data->{langTags}{Subtypes}   = $land_data->{subtypes};

    # Make sure each land matches correctly
    foreach my $category ('Main', 'Mana Pool', 'Color Identity') {
        ### XXX: Too many of these right now...
        next if $category eq 'Main';

        warn "Didn't match $category for land card '$name'!\n" unless $land_data->{langTags}{$category};
    }

    # If it didn't match a main category, put it in an unsorted one
    unless ($land_data->{langTags}{Main}) {
        $land_data->{langTags}{Main} = [ 'Other Lands' ];
    }

    # Add the other auto-generated tags into %LAND_TYPES, too
    foreach my $category (@LAND_CATEGORIES) {
        next unless $land_data->{langTags}{$category};

        foreach my $type (@{ $land_data->{langTags}{$category} }) {
            $LAND_TYPES{$category}{$type}        //= {};
            $LAND_TYPES{$category}{$type}{cards} //= {};
            $LAND_TYPES{$category}{$type}{cards}{$name} = $land_data;
        }
    }
}

### Download images

say "Downloading images...";

foreach my $name (sort keys %LAND_DATA) {
    my $land_data = $LAND_DATA{$name};

    my $tried_to_download = 0;
    foreach my $prefix (qw/ lg sm /) {
        my $local_url  = $land_data->{'local'.ucfirst($prefix).'ImgURL'};
        my $remote_url = $land_data->{"${prefix}ImageURL"};
        next unless $local_url && $remote_url;

        my $filename = "$BASE_DIR/$local_url";
        next if -s $filename;

        $tried_to_download = 1;
        printf "    %-50s", $remote_url;
        my $req = HTTP::Request->new(GET => $remote_url);
        my $res = $ua->request($req);

        if ($res->is_success) {
            print " => $filename";

            open my $jpeg_fh, '>', $filename or die "Can't open $filename: $!";
            print $jpeg_fh $res->content;
            close $jpeg_fh;

            print "\n";
        }
        else {
            print "\n";
            warn "Can't download $remote_url: ".$res->status_line."\n";

            # Try to use the other as an alternate
            if    ($prefix eq 'lg' && -s "$BASE_DIR/".$land_data->{'localSmImgURL'}) {
                $land_data->{'localLgImgURL'} = $land_data->{'localSmImgURL'};
            }
            elsif ($prefix eq 'sm' && -s "$BASE_DIR/".$land_data->{'localLgImgURL'}) {
                $land_data->{'localSmImgURL'} = $land_data->{'localLgImgURL'};
            }
        }
    }

    sleep 1 if $tried_to_download;  # try to be a friendly spider
}

### Build HTML pages based on the lesser categories, with the Main categories looped on each page

say "Copying image/style files...";
foreach my $filename (glob "style/* img/*") {
    copy($filename, "$BASE_DIR/$filename");
}

say "Creating HTML...";
foreach my $category (@LAND_CATEGORIES) {
    my $category_data = $LAND_TYPES{$category};
    next unless $category_data;

    foreach my $first_type (sort keys %$category_data) {
        my $first_type_data = $category_data->{$first_type};
        my $html_filename   = simplify_name($category).'-'.simplify_name($first_type).'.html';

        my $html_fh = start_html(
            $html_filename => 'Lands filtered by '.land_type_label($category, $first_type)
        );

        foreach my $main_type (sort keys %{ $LAND_TYPES{Main} }) {
            # For the main category, just display the one type
            if ($category eq 'Main') {
                next unless $first_type eq $main_type;
            }

            my $main_type_data = $LAND_TYPES{Main}{$main_type};

            # Build a "fake" types hash with the filtered results
            my $filter_type_data = {
                cards     => {
                    map   { $_ => $main_type_data->{cards}{$_} }
                    grep  { $first_type_data->{cards}{$_} }
                    keys %{ $main_type_data->{cards} }
                },
                alt_names => $main_type_data->{alt_names},
            };

            next unless %{ $filter_type_data->{cards} };

            say $html_fh build_type_html_body($main_type, $filter_type_data);
        }

        end_html($html_fh);
    }
}

# Also create an 'all.html' file with everything

my $html_fh = start_html('all.html' => 'All lands, unfiltered');

foreach my $type (sort keys %{ $LAND_TYPES{Main} }) {
    say $html_fh build_type_html_body($type, $LAND_TYPES{Main}{$type});
}

end_html($html_fh);

# Finally, create an 'index.html' page

$html_fh = start_html(
    'index.html' => 'All of the lands, all up-to-date, all categorized, all dynamically generated'
);

say $html_fh build_index_html_body();

end_html($html_fh);

### Fin

exit;

##################################################################################################

sub sort_color_id {
    my ($ci) = @_;
    return 0 if $ci eq '';

    # Goofy, but it works
    my $num = $ci;
    $num =~ tr/WUBRG/12345/;

    # Append a final color subtype to the number
    my $len     = length $ci;
    my $subtype = $COLOR_TYPES{$ci}{subtype} || '';

    my %subtype_scores = (
        Allied => 1,
        Enemy  => 2,
        Shard  => 3,
        Wedge  => 4,
    );

    if    ($len >= 4) {
        $num += 900_000;  # supercedes all else
    }
    elsif ($len >= 2 && $subtype) {
        $num += $subtype_scores{$subtype} * 100_000;
    }

    return $num;
}

sub simplify_name {
    my ($txt) = @_;
    $txt = lc $txt;
    $txt =~ s/\W+//g;
    return $txt;
}

sub land_type_label {
    my ($category, $type) = @_;

    # Special category prefixes
    my $label =
        $category eq 'Mana Pool'      ? 'MP: ' :
        $category eq 'Color Identity' ? 'CI: ' :
        ''
    ;

    # compose a label with mana icons
    my $color_type = $COLOR_NAMES{$type};
    if ($category eq 'Color Identity' && $color_type) {
        my $id = $color_type->{id} || 'C';
        $label .= "<span class=\"mana s".lc($_)."\"></span>" for split //, $id;
        $label .= ' ';
    }
    $label .= escape_html($type);

    return $label;
}

sub land_type_link {
    my ($category, $type) = @_;

    my $label = land_type_label($category, $type);

    # figure out the right link for this label
    my $link = simplify_name($category).'-'.simplify_name($type).'.html';

    return "<a href=\"$link\" class=\"label tag-".simplify_name($category)."\">$label</a> ";
}

sub start_html {
    my ($filename, $subheader) = @_;

    print "    $filename";
    open my $fh, '>:encoding(UTF-8)', "$BASE_DIR/$filename" or die "Can't open $filename: $!";

    say $fh build_html_header($subheader);

    return $fh;
}

sub build_html_header {
    my ($subheader) = @_;
    my $html = <<'END_HTML';
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta http-equiv="X-UA-Compatible" content="IE=edge,chrome=1">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <meta name="description" content="MTGLands.com: All of the lands, all up-to-date, all categorized, all dynamically generated">
    <meta name="keywords" content="mtg,lands,dual lands,shock lands,pain lands,manlands">
    <link rel="stylesheet" href="https://maxcdn.bootstrapcdn.com/bootstrap/3.3.7/css/bootstrap.min.css" integrity="sha384-BVYiiSIFeK1dGmJRAkycuHAHRg32OmUcww7on3RYdg4Va+PmSTsz/K68vbdEjh4u" crossorigin="anonymous">
    <link rel="stylesheet" href="style/main.css">
    <link rel="stylesheet" href="style/mana.css">
    <title>MTG Lands</title>
</head>
<body>

<h1><a href="/">MTG Lands</a></h1>

END_HTML

    $html .= "\n<h4>$subheader</h4>\n\n" if $subheader;
    $html .= "<hr/>";

    return $html;
}

sub build_type_html_body {
    my ($header, $type_data) = @_;
    return '' unless $type_data->{cards} && %{ $type_data->{cards} };

    my $html = "\n<h2><a name=\"".simplify_name($header)."\"></a>$header</h2>\n\n";

    if ($type_data->{alt_names}) {
        $html .= "\n<h4>Also known as: ".join(', ', @{$type_data->{alt_names}})."</h4>\n\n";
    }

    $html .= "<div class=\"container\">\n";

    my $card_counter = 0;
    foreach my $name (
        sort { sort_color_id($LAND_DATA{$a}{colorIdStr}) <=> sort_color_id($LAND_DATA{$b}{colorIdStr}) }
        sort { $LAND_DATA{$b}{setData}{releaseDateEpoch} <=> $LAND_DATA{$a}{setData}{releaseDateEpoch} }
        sort { $a cmp $b }
        keys %{ $type_data->{cards} }
    ) {
        my $land_data = $LAND_DATA{$name};
        $card_counter++;

        if ($card_counter == 1) {
            $html .= "<div class=\"row\">\n";
        }

        # Figure out the card info tags first
        my $card_info_html = '<div class="cardname">'.escape_html($name)."</div>\n";

        $card_info_html .= '<div class="cardtags">'."\n";
        foreach my $category (@LAND_CATEGORIES) {
            my $category_tags = $land_data->{langTags}{$category};
            next unless $category_tags;

            foreach my $tag (@$category_tags) {
                $card_info_html .= land_type_link($category, $tag);
            }
            $card_info_html .= "\n";
        }
        $card_info_html .= "</div>\n";

        # Use two different types of images, depending if it's on a large screen or not
        $html .= "<div class=\"card\">\n";
        $html .=
            '<div class="card-sm">'.
            '<a href="'.$land_data->{infoURL}.'">'.
            '<img width="223" height="311" border="0" alt="'.escape_html($name).'" src="'.$land_data->{localSmImgURL}.'"/>'.
            '</a>'.
            $card_info_html.
            "</div>\n"
        ;
        $html .=
            '<div class="card-lg">'.
            '<a href="'.$land_data->{infoURL}.'">'.
            '<img width="312" height="445" border="0" alt="'.escape_html($name).'" src="'.$land_data->{localLgImgURL}.'"/>'.
            '</a>'.
            $card_info_html.
            "</div>\n"
        ;
        $html .= "</div>\n";

        if ($card_counter >= 5) {
            $html .= "</div>\n";
            $card_counter = 0;
        }
    }

    if ($card_counter) {
        $html .= "</div>\n";
    }

    $html .= "</div>\n";
    $html .= "<hr/>\n";

    return $html;
}

sub build_index_html_body {
    my $html = '';
my @LAND_CATEGORIES = (
    'Main', 'Color Identity', 'Mana Pool', 'Supertypes', 'Subtypes', 'Other'  # in order
);


    $html .= <<'END_HTML';
<h2>Main Land Types</h2>

<div class="container">
<div class="row indextags">
END_HTML

    foreach my $type (sort keys %{ $LAND_TYPES{Main} }) {
        $html .= land_type_link('Main', $type)."\n";
    }

    $html .= <<'END_HTML';
</div>
</div>

<h2>Color Identity</h2>

<div class="container">
END_HTML

    my (@color_types, @color_subtypes, @color_names);
    foreach my $type (
        sort { sort_color_id($a) <=> sort_color_id($b) }
        keys %COLOR_TYPES
    ) {
        my $color_type = $COLOR_TYPES{$type};
        next if $color_type->{type} eq 'Four Color';  # none exist yet...

        push @color_types,    $color_type->{type}    unless $color_type->{type} eq $color_type->{name};
        push @color_subtypes, $color_type->{subtype} if $color_type->{subtype};
        push @color_names,    $color_type->{name};
    }
    @color_types    = uniq @color_types;
    @color_subtypes = uniq @color_subtypes;

    my ($type_html, $subtype_html, $name_html) = ('', '', '');
    $type_html    .= land_type_link('Color Identity', $_)."\n" for @color_types;
    $subtype_html .= land_type_link('Color Identity', $_)."\n" for @color_subtypes;
    $name_html    .= land_type_link('Color Identity', $_)."\n" for @color_names;

    $html .= "<div class=\"row indextags\">\n$_</div>" for ($type_html, $subtype_html, $name_html);

    $html .= <<'END_HTML';
</div>

<h2>Mana Pool Generators</h2>

<div class="container">
<div class="row indextags">
END_HTML

    # Just sort this one manually...
    foreach my $type (
        'Colorless', 'Monocolor', 'Dual Colors', 'Tri-Colors', 'Any Color',
        'Commander Colors', 'Conditional Colors'
    ) {
        $html .= land_type_link('Mana Pool', $type)."\n";
    }

    $html .= <<'END_HTML';
</div>
</div>

<h2>Supertypes / Subtypes</h2>

<div class="container">
<div class="row indextags">
END_HTML

    foreach my $type (sort keys %{ $LAND_TYPES{Supertypes} }) {
        $html .= land_type_link('Supertypes', $type)."\n";
    }

    $html .= "</div>\n<div class=\"row indextags\">\n";

    foreach my $type (sort keys %{ $LAND_TYPES{Subtypes} }) {
        $html .= land_type_link('Subtypes', $type)."\n";
    }

    $html .= <<'END_HTML';
</div>
</div>

<h2>Other Types</h2>

<div class="container">
<div class="row indextags">
END_HTML
    foreach my $type (sort keys %{ $LAND_TYPES{Other} }) {
        $html .= land_type_link('Other', $type)."\n";
    }

    $html .= <<'END_HTML';
</div>
</div>

<h2><a href="all.html">All Lands</a></h2>

<hr/>

<h2>Awesome MTG/EDH Resources</h2>

<ul>
    <li>Tolarian Community College's Excellent Commander Mana Base videos:</li>
    <ul>
        <li><a href="https://www.youtube.com/watch?v=UleH4wxzONA">5 Color Decks</a></li>
        <li><a href="https://www.youtube.com/watch?v=ifig4xSp0kA">3 Color Decks</a></li>
        <li><a href="https://www.youtube.com/watch?v=MDc4v7sDaQY">2 Color Decks</a></li>
    </ul>
    <li><a href="http://www.edhrec.com/">EDHREC</a></li>
    <li><a href="http://www.edhgenerals.com/">EDH Generals</a></li>
    <li><a href="http://manabasecrafter.com/">Manabase Crafter</a>, a similar but different kind of
    land/manabase lookup reference</li>
    <li><a href="https://mtgjson.com/">MTG JSON</a>, used to acquire all of the information on this site</li>
</ul>
<hr/>
END_HTML

    return $html;
}

sub build_html_footer {
return <<'END_HTML';
<div class="footer-links">
    <a href="/">Main Index</a> |
    <a href="all.html">All Lands</a> |
    <a href="https://github.com/SineSwiper/mtglands.com">Source</a> |
    <a href="https://github.com/SineSwiper/mtglands.com/issues">Report Issues</a>
</div>

<small class="disclaimer">This website is not produced, endorsed, supported, or affiliated with
Wizards of the Coast, nor any of the sites linked.</small>

</body>
</html>
END_HTML
}

sub end_html {
    my ($fh) = @_;

    say $fh build_html_footer();
    close $fh;
    print "\n";
}
