#!/usr/bin/perl -w
use strict;

use lib '/Users/btrott/Documents/devel/WWW-TypePad/lib';
use lib '/Users/btrott/Documents/devel/faved-tp';

use Faved::Util qw( debug );
use List::Util qw( first );
use WWW::TypePad;

my $tp = WWW::TypePad->new;
my $dbh = Faved::Util->get_dbh;

my $total;
my $i = 1;
my $most_recent_event_id;

my( $last_event_id ) = $dbh->selectrow_array( <<SQL );
SELECT api_id FROM last_event_id
SQL

EVENTS: {
    do {
        my $res = $tp->users->notifications(
            '6p00d83455876069e2',
            { 'start-index' => $i }
        );
        $total ||= $res->{totalResults};
        $i += scalar @{ $res->{entries} };

        # The first time through the loop, set most_recent_event_id
        # to the api ID for the top event in the list (the most recent).
        # We'll set this in the DB after processing all events.
        $most_recent_event_id ||= $res->{entries}[0]{urlId};

        for my $event ( @{ $res->{entries} } ) {
            # Bail once we get to an event we've previously processed.
            last EVENTS if $last_event_id && $event->{urlId} eq $last_event_id;

            my $rv;

            # Process favorites...
            if ( is_favorite( $event ) ) {
                $rv = process_favorite( $event );
            }
            
            # ... and new assets ...
            elsif ( is_good_asset( $event ) ) {
                $rv = process_asset( $event );
            }

            # ... and skip everything else.
        }
    } while ( $i < $total );
}

if ( $most_recent_event_id ) {
    # TODO racy, but I don't care right now.
    if ( $last_event_id && $most_recent_event_id ne $last_event_id ) {
        $dbh->do( <<SQL, undef, $most_recent_event_id );
UPDATE last_event_id SET api_id = ?
SQL
    } elsif ( !$last_event_id ) {
        $dbh->do( <<SQL, undef, $most_recent_event_id );
INSERT INTO last_event_id (api_id) VALUES (?)
SQL
    }
}

exit;

sub is_good_asset {
    my( $event ) = @_;

    return unless is_verb( $event, 'tag:api.typepad.com,2009:NewAsset' );

    my $asset = $event->{object};

    # Skip comments.
    return if is_type( $asset, 'tag:api.typepad.com,2009:Comment' );

    # Skip non-Post assets unless they're in a Motion group.
    return unless
        is_type( $asset, 'tag:api.typepad.com,2009:Post' ) ||
        $asset->{groups} && @{ $asset->{groups} };

    return if $asset->{source} && $asset->{source}{provider};
    
    return 1;
}
            
sub is_favorite {
    my( $event ) = @_;
    return is_verb( $event, 'tag:api.typepad.com,2009:AddedFavorite' );
}

sub is_verb {
    my( $event, $verb ) = @_;
    my $found = first { $_ eq $verb } @{ $event->{verbs} };
    return $found ? 1 : 0;
}

sub is_type {
    my( $asset, $type ) = @_;
    my $found = first { $_ eq $type } @{ $asset->{objectTypes} };
    return $found ? 1 : 0;
}

sub process_asset {
    my( $event ) = @_;

    my $api_id = $event->{object}{urlId};
    my $row = $dbh->selectrow_arrayref( <<SQL, undef, $api_id );
SELECT 1 FROM asset WHERE api_id = ?
SQL
    if ( $row ) {
        debug "Already processed asset $api_id";
        return;
    }

    debug "Adding asset $api_id";

    # Convert the API objects into local objects, instantiating a local
    # record if we hadn't seen this asset before.
    my $asset = Faved::Util->find_or_create_asset_from_api( $event->{object} );

    # TODO get a real person_id by looking up our user in the API and putting
    # him/her in the DB.
    $dbh->do( <<SQL, undef, 1, $asset->{asset_id} );
INSERT INTO stream (person_id, asset_id) VALUES (?, ?)
SQL
    
    return 1;
}

sub process_favorite {
    my( $event ) = @_;

    my $fave_id = join ':', $event->{object}{urlId}, $event->{actor}{urlId};

    my $row = $dbh->selectrow_arrayref( <<SQL, undef, $fave_id );
SELECT 1 FROM favorited_by WHERE api_id = ?
SQL
    if ( $row ) {
        debug "Already processed favorite $fave_id";
        return;
    }

    debug "Adding favorite $fave_id";

    # Convert the API objects into local objects, instantiating a local
    # record if we hadn't seen this user/asset before.
    
    my $person = Faved::Util->find_or_create_person_from_api( $event->{actor} );
    my $asset = Faved::Util->find_or_create_asset_from_api( $event->{object} );

    $dbh->do( <<SQL, undef, $asset->{asset_id}, $person->{person_id}, $fave_id );
INSERT INTO favorited_by (asset_id, person_id, api_id) VALUES (?, ?, ?)
SQL

    $dbh->do( <<SQL, undef, $asset->{asset_id} );
UPDATE asset SET favorite_count = favorite_count + 1 WHERE asset_id = ?
SQL

    return 1;
}