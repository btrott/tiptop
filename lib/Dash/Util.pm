package Dash::Util;
use strict;

use CGI::Deurl::XS ();
use Config::Tiny;
use DBI;
use Encode;
use Exporter::Lite;
use File::Basename qw( dirname );
use Getopt::Long qw( :config pass_through );
use HTML::Entities ();
use HTML::Sanitizer;
use HTML::TokeParser;
use JSON;
use List::Util qw( first min reduce );

our @EXPORT_OK = qw( debug );
our $Config = dirname( __FILE__ ) . "/../../dash.cfg";

GetOptions(
    'config' => \$Config,
);

sub debug ($) {
    print STDERR "@_\n";
}

sub config_file {
    my $class = shift;
    return $Config;
}

sub config {
    my $class = shift;
    return our $ConfigObj ||= Config::Tiny->read( $class->config_file );
}

sub get_dbh {
    my $class = shift;
    our $DBH;
    unless ( defined $DBH ) {
        my $cfg = $class->config->{database};
        $DBH = DBI->connect( $cfg->{dsn}, $cfg->{user}, $cfg->{password}, {
            RaiseError => 1
        } );
    }
    return $DBH;
}

sub find_or_create_person_from_api {
    my $class = shift;
    my( $obj ) = @_;

    my $api_id = $obj->{urlId};

    my $dbh = $class->get_dbh;
    my $row = $dbh->selectrow_hashref( <<SQL, undef, $api_id );
SELECT person_id, api_id, display_name, avatar_uri FROM person WHERE api_id = ?
SQL
    unless ( defined $row ) {
        my $avatar_uri = $class->get_best_avatar_uri( $obj->{links} );
        my $display_name = $obj->{displayName};

        $dbh->do( <<SQL, undef, $api_id, $display_name, $avatar_uri );
INSERT INTO person (api_id, display_name, avatar_uri) VALUES (?, ?, ?)
SQL
        $row = {
            person_id       => $dbh->{mysql_insertid},
            api_id          => $api_id,
            display_name    => $display_name,
            avatar_uri      => $avatar_uri,
        };
    }
    return $row;
}

sub get_best_avatar_uri {
    my $class = shift;
    my( $links ) = @_;
    return unless $links && @$links;
    
    # Look first for a 50px width avatar...
    my $link = first { $_->{rel} eq 'avatar' && $_->{width} == 50 } @$links;

    # ... and if we can't find one, grab the largest available avatar,
    # which will by definition be less than 50px width, I think?
    unless ( $link ) {
        $link = reduce { $a->{width} > $b->{width} ? $a : $b }
                grep { $_->{rel} eq 'avatar' } @$links;
    }

    return $link ? $link->{href} : undef;
}

sub find_or_create_asset_from_api {
    my $class = shift;
    my( $obj ) = @_;

    my $api_id = $obj->{urlId};

    my $dbh = $class->get_dbh;
    my $row = $dbh->selectrow_hashref( <<SQL, undef, $api_id );
SELECT asset_id, api_id, person_id, title, content, permalink, created, favorite_count, links_json, object_type FROM asset WHERE api_id = ?
SQL

    unless ( defined $row ) {
        my $person = $class->find_or_create_person_from_api( $obj->{author} );

        my $link = first { $_->{rel} eq 'alternate' } @{ $obj->{links} };
        my( $type ) = $obj->{objectTypes}[0] =~ /(\w+)$/;
        
        $row = {
            api_id          => $api_id,
            person_id       => $person->{person_id},
            title           => $obj->{title},
            content         => $obj->{content},
            permalink       => $link->{href},
            created         => $obj->{published},
            favorite_count  => 0,
            links_json      => encode_json( $obj->{links} ),
            object_type     => $type,
        };

        $dbh->do( <<SQL, undef, $row->{api_id}, $row->{person_id}, $row->{title}, $row->{content}, $row->{permalink}, $row->{created}, $row->{favorite_count}, $row->{links_json}, $row->{object_type} );
INSERT INTO asset (api_id, person_id, title, content, permalink, created, favorite_count, links_json, object_type) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
SQL
        $row->{asset_id} = $dbh->{mysql_insertid};
    }
    return $row;
}

sub strip_html {
    my( $html ) = @_;

    my $safe = HTML::Sanitizer->new(
        script  => undef,
        style   => undef,
        small   => undef,       # remove "via" lines (hack!)
        '*'    => 0,
    );
    $safe->set_encoder( sub {
        my( $str ) = @_;
        $str =~ tr/\x{00a0}/\x{0020}/;
        return $str;
    } );

    Encode::_utf8_on( $html );
    $html = $safe->sanitize( \$html );
    utf8::encode( $html );
    
    return $html;
}

sub generate_excerpt {
    my( $html, $words ) = @_;

    my $text = strip_html( $html );
    return '' if !defined $text || !defined $words || $words == 0;

    my $char = Encode::is_utf8( $text ) ?
        $text :
        Encode::decode( 'utf-8', $text );

    $text =~ s/^\s+//; $text =~ s/\s+$//;

    if ( $char =~ m/[\p{Han}\p{Hiragana}\p{Katakana}]/ ) {
        $text =~ s/\s+/ /g;
        Encode::_utf8_on( $text );
        no warnings 'substr';
        $text = substr $text, 0, $words;
    } else {
        my @words = split /\s+/, $text, $words + 1;
        $text = join ' ', @words[ 0 .. min( $words, scalar @words ) - 1 ];
        if ( @words > $words ) {
            $text .= '...';
        }
    }

    Encode::_utf8_off( $text );
    return $text;
}

sub explode_asset_uri {
    my( $uri ) = @_;
    my( $server, $xid ) = $uri =~ /
        http:\/\/(.*?)\/(6a[0-9a-f]{32})
    /x or return;
    return( $server, $xid );
}

sub get_content_data {
    my $class = shift;
    my( $type, $content, $links ) = @_;

    my %data = (
        excerpt     => generate_excerpt( $content, 50 ),
        media       => [],
        rendered    => $content,
    );

    if ( $type eq 'Photo' ) {
        my $link = reduce { $a->{width} > $b->{width} ? $a : $b }
                   grep { $_->{rel} eq 'enclosure' } @$links;
        if ( $link ) {
            $data{rendered} = <<HTML;
<p><img src="$link->{href}" width="$link->{width}" height="$link->{height}" /></p>

<p>$content</p>
HTML
            my( $server, $xid ) = explode_asset_uri( $link->{href} );
            $data{media} = [ {
                type        => 'photo',
                uri         => $link->{href},
                server      => $server,
                id          => $xid,
                width       => $link->{width},
                height      => $link->{height},
            } ];
        }
    } elsif ( $type eq 'Post' ) {
        my $parser = HTML::TokeParser->new( \$content );
        while ( my $t = $parser->get_token ) {
            if ( $t->[0] eq 'S' && $t->[1] eq 'img' ) {
                my( $server, $xid ) = explode_asset_uri( $t->[2]{src} );
                push @{ $data{media} }, {
                    type    => 'photo',
                    uri     => $t->[2]{src},
                    server  => $server,
                    id      => $xid,
                    width   => $t->[2]{width},
                    height  => $t->[2]{height},
                };
            }
        }
    }

    return \%data;
}

1;
__END__

DROP TABLE IF EXISTS asset;
CREATE TABLE asset (
    asset_id INTEGER UNSIGNED auto_increment NOT NULL,
    api_id VARCHAR(75) NOT NULL,
    person_id INTEGER UNSIGNED NOT NULL,
    title VARCHAR(255),
    content MEDIUMBLOB,
    permalink VARCHAR(255),
    created DATETIME,
    favorite_count INTEGER UNSIGNED,
    links_json MEDIUMBLOB,
    object_type VARCHAR(15),
    PRIMARY KEY (asset_id),
    INDEX (api_id),
    INDEX (person_id, created),
    INDEX (created),
    INDEX (favorite_count)
);

DROP TABLE IF EXISTS person;
CREATE TABLE person (
    person_id INTEGER UNSIGNED auto_increment NOT NULL,
    api_id VARCHAR(18) NOT NULL,
    display_name VARCHAR(100),
    avatar_uri VARCHAR(255),
    PRIMARY KEY (person_id),
    INDEX (api_id)
);

DROP TABLE IF EXISTS favorited_by;
CREATE TABLE favorited_by (
    asset_id INTEGER UNSIGNED NOT NULL,
    person_id INTEGER UNSIGNED NOT NULL,
    api_id VARCHAR(53) NOT NULL,
    INDEX (asset_id),
    UNIQUE (api_id)
);

DROP TABLE IF EXISTS last_event_id;
CREATE TABLE last_event_id (
    api_id varchar(34) NOT NULL
);

DROP TABLE IF EXISTS stream;
CREATE TABLE stream (
    person_id INTEGER UNSIGNED NOT NULL,
    asset_id INTEGER UNSIGNED NOT NULL,
    PRIMARY KEY (person_id, asset_id)
);