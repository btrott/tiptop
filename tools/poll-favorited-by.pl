#!/usr/bin/perl -w
use strict;

use Find::Lib '../lib';

use Tiptop::Util qw( debug );
use Try::Tiny;
use WWW::TypePad;

my $tp = WWW::TypePad->new;
my $dbh = Tiptop::Util->get_dbh;

my $sth = $dbh->prepare( 'SELECT asset_id, api_id FROM asset ORDER BY asset_id DESC' );
$sth->execute;

while ( my $row = $sth->fetchrow_hashref ) {
    my $faved;
    try {
        $faved = $tp->assets->favorites( $row->{api_id } );
    } catch {
        warn "Error fetching favorites for $row->{api_id}: $_";
    };
    next unless $faved;

    for my $entry ( @{ $faved->{entries} } ) {
        next unless defined $entry->{urlId};

        my $person =
            Tiptop::Util->find_or_create_person_from_api( $entry->{author} );

        my $rv = $dbh->do( <<SQL, undef, $row->{asset_id}, $person->{person_id}, $entry->{urlId} );
INSERT IGNORE INTO favorited_by (asset_id, person_id, api_id) VALUES (?, ?, ?)
SQL
        debug "$row->{asset_id} $person->{person_id} $entry->{urlId}: $rv";
    }
    
    $dbh->do( <<SQL, undef, $faved->{totalResults}, $row->{asset_id} );
UPDATE asset SET favorite_count = ? WHERE asset_id = ?
SQL
}

$sth->finish;
