#!/usr/bin/perl -w
use strict;

use Find::Lib '../lib';

use Dash::Util qw( debug );
use WWW::TypePad;

my $tp = WWW::TypePad->new;
my $dbh = Dash::Util->get_dbh;

my $sth = $dbh->prepare( 'SELECT asset_id, api_id FROM asset' );
$sth->execute;

while ( my $row = $sth->fetchrow_hashref ) {
    my $faved = $tp->assets->favorites( $row->{api_id } );

    for my $entry ( @{ $faved->{entries} } ) {
        next unless defined $entry->{urlId};

        my $person =
            Dash::Util->find_or_create_person_from_api( $entry->{author} );

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
