#!/usr/bin/perl -w
use strict;

use Find::Lib '../lib';

use JSON;
use Tiptop::Util qw( debug );
use Try::Tiny;
use WWW::TypePad;

my $tp = WWW::TypePad->new;
my $dbh = Tiptop::Util->get_dbh;

my $sth = $dbh->prepare( 'SELECT asset_id, api_id FROM asset ORDER BY asset_id DESC' );
$sth->execute;

while ( my $row = $sth->fetchrow_hashref ) {
    my $obj;
    try {
        $obj = $tp->assets->get( $row->{api_id } );
    } catch {
        warn "Error fetching asset for $row->{api_id}: $_";
    };
    next unless $obj;

    my $link = Tiptop::Util->extract_image_link( $obj );
    next unless $link;

    debug "$row->{asset_id}";

    $dbh->do( <<SQL, undef, encode_json( $link ), $row->{asset_id} );
UPDATE asset SET image_link = ? WHERE asset_id = ?
SQL
}

$sth->finish;